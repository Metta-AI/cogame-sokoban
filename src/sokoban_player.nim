## Sokoban container player owns native inference over the issued private view.
import std/[atomics, json, locks, math, monotimes, options, os, strutils, times]
import bitworld/[decision_trajectory, native_http, native_stop, native_websocket,
  spriteprotocol]
import sokoban/[baselines, directives, model_pacing, player_llm, policy_view,
  prompt_policy, sim_types]

type PlayerCall = object
  socket: ptr NativeWebSocket
  decisionId, observation, prompt, policy: string
  deadline: MonoTime
  slot, maxActions: int
  scripted: string

var
  worker: Thread[void]
  jobs: Channel[PlayerCall]
  busy, cancelPending: Atomic[bool]
  evidenceLock: Lock
  activeControl: ptr NativeRequestControl
  workerEvidence: string

initLock(evidenceLock)

proc cancelDecision() =
  cancelPending.store(true)
  withLock evidenceLock:
    if activeControl != nil: activeControl[].cancelNativeRequest()

proc runDecision(call: PlayerCall, pacer: var ModelPacer) {.gcsafe.} =
  var control: NativeRequestControl
  {.gcsafe.}:
    withLock evidenceLock:
      activeControl = control.addr
      if cancelPending.load(): control.cancelNativeRequest()
  defer:
    {.gcsafe.}:
      withLock evidenceLock: activeControl = nil
    busy.store(false)
  let view = parseJson(call.observation)
  let client = newLlmClient()
  var action: JsonNode
  var source = "scripted"
  var cause = ""
  let progress = proc(attempt: DecisionAttempt) {.gcsafe.} =
    let evidence = attempt.attemptEvidenceJson()
    {.gcsafe.}:
      withLock evidenceLock:
        var attempts = if workerEvidence.len > 0: parseJson(workerEvidence) else: newJArray()
        var replaced = false
        for index in 0 ..< attempts.len:
          if attempts[index]["attempt_id"] == evidence["attempt_id"]:
            attempts.elems[index] = evidence
            replaced = true
            break
        if not replaced: attempts.add(evidence)
        workerEvidence = $attempts
    let sent = call.socket[].sendNativeText($ %*{
      "type": "attempt_started", "decision_id": call.decisionId,
      "training_attempt": evidence}, call.deadline)
    if sent.kind != wsReady:
      raise newException(ValueError, "private attempt progress was not delivered")
  if call.scripted.len > 0:
    let directive = scriptedPlanForView(view, parseBaseline(call.scripted))
    action = %*{"actions": directive.actionsJson(), "say": directive.say,
      "notes": directive.notes}
  elif client.disabled:
    let directive = scriptedPlanForView(view, blPusher)
    action = %*{"actions": directive.actionsJson(), "say": directive.say,
      "notes": directive.notes}
    source = "fallback"
    cause = "no_endpoint"
  else:
    try:
      action = choosePromptPlan(client, pacer, view, call.prompt,
        call.maxActions, call.deadline, call.slot, call.decisionId, call.policy,
        control, progress)
      source = "llm"
    except RateGuardError:
      let directive = scriptedPlanForView(view, blPusher)
      action = %*{"actions": directive.actionsJson(), "say": directive.say,
        "notes": directive.notes}
      source = "fallback"
      cause = "rate_guard"
    except CatchableError:
      let directive = scriptedPlanForView(view, blPusher)
      action = %*{"actions": directive.actionsJson(), "say": directive.say,
        "notes": directive.notes}
      source = "fallback"
      cause = "native_or_directive_rejected"
  if interruptionRequested() or control.nativeRequestCanceled(): return
  let evidence = if client.attempts.len > 0:
    client.attempts[^1].attemptEvidenceJson() else: newJNull()
  discard call.socket[].sendNativeText($ %*{"type": "action",
    "decision_id": call.decisionId, "source": source, "cause": cause,
    "action": action, "training_attempt": evidence}, call.deadline)

proc runWorker() {.gcsafe.} =
  var pacer = newModelPacer()
  while not interruptionRequested():
    let received = jobs.tryRecv()
    if received.dataAvailable:
      runDecision(received.msg, pacer)
    else:
      sleep(5)

proc stopAndAcknowledge(socket: NativeWebSocket, decisionId, stopId: JsonNode,
    cleanupDeadline: MonoTime): bool =
  requestNativeStop()
  cancelDecision()
  joinThread(worker)
  var attempts = newJArray()
  withLock evidenceLock:
    if workerEvidence.len > 0: attempts = parseJson(workerEvidence)
  let sent = socket.sendCleanupText($ %*{"type": "stopped",
    "decision_id": decisionId, "stop_id": stopId,
    "worker_status": "joined", "attempts": attempts}, cleanupDeadline)
  if sent.kind != wsReady: return false
  while getMonoTime() < cleanupDeadline:
    let received = socket.receiveCleanupText(cleanupDeadline)
    if received.kind != wsMessage: return false
    let frame = parseJson(received.data)
    if frame["type"].getStr() == "evidence_received" and
        frame["decision_id"] == decisionId and frame["stop_id"] == stopId:
      return true
  false

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0: quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT").truncateRunes(MaxPromptRunes)
  var scripted = getEnv("PLAYER_SCRIPTED").strip()
  if prompt.strip().len == 0 and scripted.len == 0: scripted = "pusher"
  if scripted.len > 0: discard parseBaseline(scripted)
  let policy = getEnv("PLAYER_POLICY_LABEL", "sokoban").truncateRunes(MaxPolicyLabelRunes)
  let timeout = getEnv("COWORLD_TIMEOUT_SECONDS", "1200").parseFloat()
  if timeout <= 0 or classify(timeout) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "player timeout must be finite and positive")
  let started = getMonoTime()
  let deadline = started + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
  let connection = connectNativeWebSocket(url,
    min(deadline, started + initDuration(seconds = 30)), 16 * 1024 * 1024)
  case connection.kind
  of wsInterrupted, wsDeadline: quit(0)
  of wsReady: discard
  else: raise newException(ValueError, "player connection failed")
  var socket = connection.socket
  var decisionId = newJNull()
  var slot = -1
  var cleanupBudgetMs = 0
  var joined = false
  var registered = false
  jobs.open()
  createThread(worker, runWorker)
  try:
    while getMonoTime() < deadline:
      if interruptionRequested(): break
      let received = receiveNativeText(socket, min(deadline,
        getMonoTime() + initDuration(milliseconds = 50)))
      case received.kind
      of wsDeadline, wsInterrupted: continue
      of wsClosed: break
      of wsMessage: discard
      else: raise newException(ValueError, "player transport failed")
      let payload = parseJson(received.data)
      case payload["type"].getStr()
      of "welcome":
        if registered: raise newException(ValueError, "duplicate player welcome")
        slot = payload["slot"].getInt()
        if slot < 0: raise newException(ValueError, "invalid player slot")
        let registration = $ %*{"type": "register", "policy": policy,
          "prompt": prompt, "kind": (if scripted.len > 0: "scripted" else: "llm"),
          "scripted": (if scripted.len > 0: %scripted else: newJNull())}
        let sent = sendNativeBinary(socket, blobFromSpriteChat(registration), deadline)
        if sent.kind != wsReady: raise newException(ValueError, "player registration failed")
        registered = true
      of "decision":
        if not registered: raise newException(ValueError, "decision before registration")
        let receivedAt = getMonoTime()
        let issuedId = payload["decision_id"]
        if issuedId.kind != JString or issuedId.getStr().len == 0:
          raise newException(ValueError, "decision identity must be a nonempty string")
        let budgetMs = payload["transport"]["budget_ms"].getInt()
        cleanupBudgetMs = payload["transport"]["cleanup_budget_ms"].getInt()
        if budgetMs <= 0 or cleanupBudgetMs < 0:
          raise newException(ValueError, "invalid decision transport budget")
        let decisionDeadline = min(deadline, receivedAt + initDuration(milliseconds = budgetMs))
        if busy.load(): cancelDecision()
        while busy.load() and getMonoTime() < decisionDeadline and not interruptionRequested():
          sleep(5)
        if interruptionRequested(): break
        if busy.load(): raise newException(ValueError, "previous decision owner did not join")
        decisionId = issuedId
        withLock evidenceLock: workerEvidence.setLen(0)
        cancelPending.store(false)
        busy.store(true)
        jobs.send(PlayerCall(socket: socket.addr, decisionId: issuedId.getStr(),
          observation: $payload["observation"], prompt: prompt, policy: policy,
          maxActions: payload["max_actions"].getInt(), scripted: scripted,
          slot: slot, deadline: decisionDeadline))
      of "stop":
        joined = true
        discard stopAndAcknowledge(socket, payload["decision_id"], payload["stop_id"],
          getMonoTime() + initDuration(milliseconds = payload["cleanup_budget_ms"].getInt()))
        break
      of "final": break
      of "turn", "state", "evidence_received": discard
      else: raise newException(ValueError, "unknown player packet")
  finally:
    if not joined:
      discard stopAndAcknowledge(socket, decisionId, newJNull(),
        getMonoTime() + initDuration(milliseconds = cleanupBudgetMs))
    jobs.close()
    closeNativeWebSocket(socket)
