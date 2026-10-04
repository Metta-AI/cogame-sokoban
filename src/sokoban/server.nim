## The Sokoban game server: the Coworld game contract over mummy.
##
## Forked from `coworld-ctf`'s `src/ctf/server.nim` with the three named edits
## of the design note:
##
## 1. TURN BOUNDARY — unchanged in shape, with a VARIABLE turn length (the tick
##    loop breaks early when a level finishes) and one seat in the batch.
## 2. REGISTRATION INTERCEPTION — the seat's Sprite v1 chat message (`0x81`,
##    surfaced by `parseSpriteClientMessages`) whose text parses as a
##    registration object is consumed as REGISTRATION, not applied as a line and
##    not written to the replay chat stream; the server writes a REDACTED
##    `register` record instead (policy label and kind, never the prompt). The
##    server LOGS LOUDLY and refuses to start the game when a joined seat has no
##    register record (the grf-football 2026-08-27 silent-default scar).
## 3. WALL-CLOCK STOP — the starter's `wallClockBudgetSeconds` check at the top
##    of every loop iteration, kept, forcing `reason = deadline`,
##    `endRule = wallClock`, and written as a LOAD-BEARING stop record.
##
## Endpoints:
##   GET /healthz                 liveness
##   GET /client/player           the seat page (view-only)
##   GET /client/global           the spectator page
##   GET /client/replay           the broadcast replay page
##   GET /client/<asset>          chrome_common.js, broadcast_core.js, art
##   GET /replay-data             the recorded replay bytes (replay mode)
##   WS  /player?slot=N&token=T   the player protocol
##   WS  /global                  spectator sprite packets
##
## The certifier's browser probes are served for real and registered BEFORE any
## catch-all asset route, `/client/player` must NOT open the player socket, the
## player websocket CLOSES unless the token matches the seat (the certifier
## probes with a bad token), and `websocketHandler` keeps the
## `Ping -> socket.send(message.data, Pong)` branch with NO additional `kind`
## guard: a `kind != TextMessage` guard drops the player's BINARY registration
## frames (lux-ai 0.1.0, snake-royale 0.1.0).

import std/[base64, json, locks, math, monotimes, options, os, sets, strutils, sysrand, tables, times]
import bitworld/[artifact_runtime, decision_trajectory, native_http, native_stop, runtime]
import bitworld/spriteprotocol
import mummy
import mummy/routers
import sim_types, sim, sim_config, broadcast, records, events, global,
  replays, replay_runtime, wire_constants, prompt_render

const
  ShutdownGraceSeconds* = 20
    ## `/healthz` and `/global` keep answering for a bounded grace AFTER the
    ## artifacts are written, then the process exits: the runner pings `/global`
    ## with a 2 s deadline after the player pods start, and a short episode may
    ## already have exited (the lantern 0.1.3 scar).

type
  IssuedDecision = ref object
    id: string
    view: JsonNode
    issuedAt, deadline: MonoTime
    attempts: OrderedTable[string, JsonNode]
    completedAttempts: HashSet[string]
    action: JsonNode
    actionReceivedAt: MonoTime
    selected: Option[string]
    proposal, applied: JsonNode
    status: ActionStatus
    fallbackOrigin: Option[string]
    terminal: bool

  ServerState = object
    scripted: seq[Baseline]
    isLlm: seq[bool]
    policies: seq[string]
    names: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    prompts: seq[string]
    decisions: OrderedTable[string, IssuedDecision]
    latestDecision: string
    stopping, finalizationStarted: bool
    stopId: string
    stopIssuedAt, acknowledgementDeadline, episodeDeadline: MonoTime
    acknowledgedSlots: HashSet[int]
    trajectory: Option[DecisionTrajectory]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewerStates: Table[WebSocket, GlobalViewerState]
    seats: int
    started: bool
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: SimServer
  gameServer: Server
  replayPayload: string
  eventsSinkPath: string
  runtimeCfg: RuntimeConfig

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc declarePlayerFailure(slot: int, message: string, deadline: MonoTime) =
  let uri = getEnv("COGAME_PLAYER_FAILURE_URI")
  if uri.len > 0:
    writeCogameArtifact(uri, $(%*{"failed_policy_index": slot, "message": message}),
      "application/json", "COGAME_PLAYER_FAILURE_METHOD", deadline, ahPut)

proc requireFileUri(name: string): string =
  let uri = getEnv(name)
  if uri.len == 0:
    return ""
  if not uri.startsWith("file://"):
    return ""
  uri[7 .. ^1]

proc writeArtifact(uri, data, contentType, methodEnv: string, deadline: MonoTime) =
  if uri.len == 0: return
  let httpMethod = case getEnv(methodEnv, "PUT").toUpperAscii()
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(ValueError, "artifact method must be PUT or POST")
  writeCogameArtifact(uri, data, contentType, methodEnv, deadline, httpMethod)

proc retainAttempt(decision: IssuedDecision, evidence: JsonNode,
    receivedAt: MonoTime, completed: bool) =
  let attempt = readAttemptEvidence(evidence)
  if receivedAt < decision.issuedAt or
      attempt.attemptId notin [decision.id & "-0", decision.id & "-1"]:
    raise newException(ValueError, "attempt is not owned by this issued decision")
  if attempt.origin == aoModel:
    let expected = %*[{"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(shared.prompts[0], $decision.view)}]
    if attempt.prompt != expected or attempt.request.kind != JObject or
        attempt.request["system"] != expected[0]["content"] or
        attempt.request["messages"] != %*[expected[1]]:
      raise newException(ValueError, "native request differs from the issued private prompt")
    if not decision.attempts.hasKey(attempt.attemptId):
      if completed:
        raise newException(ValueError, "native completion lacks a pre-request start")
      if attempt.response.kind != JNull or attempt.rawResponse.kind != JNull or
          attempt.platformCallId.isSome or attempt.providerRequestId.isSome or
          attempt.responseHeaders.isSome or attempt.responseHeadersB64.isSome or
          attempt.responseBodyB64.isSome or attempt.responseComplete.isSome or
          attempt.responseReaderJoined.isSome or attempt.httpStatus.isSome or
          attempt.latencyMs.isSome or attempt.inputTokens.isSome or attempt.outputTokens.isSome or
          attempt.promptTokenIds.isSome or attempt.sampledTokenIds.isSome or
          attempt.behaviorLogprobs.isSome or attempt.stopReason.isSome or attempt.rejectionReason.isSome or
          attempt.modelIdentity.isSome or attempt.tokenizerIdentity.isSome or attempt.chatTemplateSha256.isSome:
        raise newException(ValueError, "first native start must precede observed response facts")
  if decision.attempts.hasKey(attempt.attemptId):
    let before = decision.attempts[attempt.attemptId]
    for key in ["attempt_id", "origin", "prompt", "request", "decoder", "policy"]:
      if before[key] != evidence[key]:
        raise newException(ValueError, "started native request is immutable")
    if (before["latency_ms"].kind != JNull or before["response_reader_joined"] == %true) and
        before != evidence:
      raise newException(ValueError, "finished native evidence is immutable")
    for key in ["response_body_b64", "response_headers_b64"]:
      if before[key].kind != JNull and (evidence[key].kind != JString or
          not decode(evidence[key].getStr()).startsWith(decode(before[key].getStr()))):
        raise newException(ValueError, "received native bytes cannot be rewritten")
    if before["response_complete"] == %true:
      for key in ["response_complete", "response_body_b64", "response_headers_b64"]:
        if evidence[key] != before[key]:
          raise newException(ValueError, "complete native bytes are immutable")
    for key in ["http_status", "response_headers", "platform_call_id", "provider_request_id",
        "model_identity", "tokenizer_identity", "chat_template_sha256"]:
      if before[key].kind != JNull and before[key] != evidence[key]:
        raise newException(ValueError, "received native identity is immutable")
  if attempt.attemptId in decision.completedAttempts and
      evidence != decision.attempts[attempt.attemptId]:
    raise newException(ValueError, "selected completion evidence is immutable")
  decision.attempts[attempt.attemptId] = copy(evidence)
  if completed: decision.completedAttempts.incl(attempt.attemptId)

proc broadcastPacketLocked(chrome: string) =
  ## Global broadcasts are FIRE AND FORGET so a slow viewer can never stall the
  ## episode.
  for socket in shared.globalSockets:
    var next: GlobalViewerState
    let state = shared.viewerStates.getOrDefault(
      socket, initGlobalViewerState())
    let packet = gameSim.buildViewerPacket(state, next, chrome)
    shared.viewerStates[socket] = next
    try:
      socket.send(blobFromBytes(packet), BinaryMessage)
    except CatchableError:
      discard

proc liveChrome(): string =
  gameSim.buildStateJson(
    gameSim.drainEvents(), playing = true, speed = 1,
    maxTick = max(1, gameSim.config.maxTicks), looping = false,
    transportEnabled = false, mismatchTick = -1)

proc pushFrames() =
  ## These are informational frames after the action has resolved.
  let chrome = liveChrome()
  broadcastPacketLocked(chrome)
  for slot, socket in shared.playerSockets:
    try:
      socket.send($(%*{
        "type": "turn", "turn": gameSim.turnsPlayed, "tick": gameSim.tick,
        "level": gameSim.levelIndex + 1, "of": gameSim.config.levelCount,
        "alias": seatAlias(slot)
      }))
    except CatchableError:
      discard

proc playerTurn(view: JsonNode, turn, budgetMs: int, playDeadline: MonoTime): tuple[directive: Directive,
    cause: string, issued: IssuedDecision] =
  result.directive = gameSim.scriptedDirective(blPusher)
  result.directive.source = dsFallback
  result.cause = "disconnected"
  let started = getMonoTime()
  let decision = IssuedDecision(id: "sokoban-" & $turn, view: copy(view),
    issuedAt: started, deadline: min(playDeadline,
      started + initDuration(milliseconds = budgetMs)), action: newJNull(),
    proposal: newJNull(), applied: newJNull(), status: asFallback, fallbackOrigin: some("game-pusher"))
  result.issued = decision
  var sent = false
  withLock stateLock:
    shared.decisions[decision.id] = decision
    shared.latestDecision = decision.id
    if shared.playerSockets.hasKey(0):
      try:
        shared.playerSockets[0].send($ %*{"type": "decision",
          "decision_id": decision.id, "observation": view,
          "max_actions": gameSim.config.maxActionsPerTurn,
          "transport": {"budget_ms": max(1, (decision.deadline - getMonoTime()).inMilliseconds),
            "cleanup_budget_ms": 5000}})
        sent = true
      except CatchableError:
        discard
  if not sent: return
  result.cause = "timeout"
  while getMonoTime() < decision.deadline and not interruptionRequested():
    var payload = newJNull()
    withLock stateLock:
      if decision.action.kind == JObject and decision.actionReceivedAt <= decision.deadline:
        payload = copy(decision.action)
    if payload.kind == JObject:
      try:
        let source = payload["source"].getStr()
        if source notin ["scripted", "llm", "fallback"]:
          raise newException(ValueError, "unknown player action source")
        let directive = parseDirective(payload["action"], gameSim.config.maxActionsPerTurn)
        let canonical = directive.directiveJson()
        decision.proposal = copy(canonical)
        if source == "llm":
          let evidence = readAttemptEvidence(payload["training_attempt"])
          if evidence.origin != aoModel or evidence.responseComplete != some(true) or
              evidence.responseReaderJoined != some(true) or evidence.httpStatus != some(200) or
              evidence.rejectionReason.isSome:
            raise newException(ValueError, "native action requires a complete joined model response")
          let body = parseJson(evidence.rawResponse.getStr())
          var text = ""
          for content in body["content"]:
            if content["type"].getStr() == "text": text.add(content["text"].getStr())
          if evidence.response != %text or evidence.model != some(body["model"].getStr()):
            raise newException(ValueError, "native body differs from selected response or model")
          let parsedReply = parseReplyObject(text)
          if parsedReply.kind == rokRejected:
            raise newException(DirectiveError, parsedReply.reason)
          let proposal = parseDirective(parsedReply.payload, gameSim.config.maxActionsPerTurn)
          if canonical != proposal.directiveJson():
            raise newException(ValueError, "native response differs from submitted action")
          if proposal.dropped > 0 or proposal.overCap > 0:
            decision.selected = none(string)
            decision.status = asFallback
            decision.fallbackOrigin = some("engine-dropped-invalid-actions")
          else:
            decision.selected = some(evidence.attemptId)
            decision.status = asAccepted
            decision.fallbackOrigin = none(string)
        elif source == "scripted":
          if payload["training_attempt"].kind != JNull:
            raise newException(ValueError, "scripted action must not assert native serving evidence")
          decision.status = asAccepted
          decision.fallbackOrigin = none(string)
        else:
          decision.fallbackOrigin = some("player-pusher")
        result.directive = directive
        result.directive.source = if source == "scripted": dsScripted
          elif source == "fallback": dsFallback else: dsLlm
        result.cause = if source == "fallback": "player_fallback" else: ""
        result.directive.latencyMs = (getMonoTime() - started).inMilliseconds.int
      except CatchableError:
        echo "sokoban: invalid player directive; using game fallback"
        result.cause = "parse_error"
      return
    sleep(10)
  if interruptionRequested():
    result.cause = "interrupted"
    decision.status = asMissing
    decision.terminal = true
  result.directive.latencyMs = (getMonoTime() - started).inMilliseconds.int

proc broadcastDone(results: JsonNode) =
  let payload = $(%*{"done": true, "result": results})
  for slot, socket in shared.playerSockets:
    try:
      socket.send(payload)
    except CatchableError as error:
      echo "sokoban: done frame to slot ", slot, " failed: ", error.msg

proc finishEpisode(writer: ReplayWriter, log: EventLog, status: EpisodeStatus) =
  let cleanupDeadline = min(shared.episodeDeadline,
    getMonoTime() + initDuration(seconds = ShutdownGraceSeconds))
  var targets: seq[int]
  withLock stateLock:
    if shared.finalizationStarted: return
    shared.finalizationStarted = true
    shared.stopping = true
    shared.stopId = ""
    for octet in urandom(16): shared.stopId.add(toHex(octet, 2).toLowerAscii())
    shared.stopIssuedAt = getMonoTime()
    shared.acknowledgementDeadline = min(cleanupDeadline - initDuration(seconds = 1),
      shared.stopIssuedAt + initDuration(seconds = 5))
    for slot in 0 ..< shared.seats:
      if not shared.everRegistered[slot]: continue
      targets.add(slot)
      if shared.playerSockets.hasKey(slot):
        let id = if shared.latestDecision.len > 0: %shared.latestDecision else: newJNull()
        shared.playerSockets[slot].send($ %*{"type": "stop", "decision_id": id,
          "stop_id": shared.stopId, "cleanup_budget_ms": max(0,
            (shared.acknowledgementDeadline - getMonoTime()).inMilliseconds)})
  while getMonoTime() < shared.acknowledgementDeadline:
    var allAcknowledged = true
    withLock stateLock:
      for slot in targets:
        if slot notin shared.acknowledgedSlots: allAcknowledged = false
    if allAcknowledged: break
    sleep(10)
  var results: JsonNode
  var replayData: string
  var finalStatus = status
  withLock stateLock:
    var cleanup = newJObject()
    for slot in targets:
      let joined = slot in shared.acknowledgedSlots
      cleanup[$slot] = %(if joined: "acknowledged" else: "unresolved")
      if not joined: finalStatus = esTruncated
    if interruptionRequested(): finalStatus = esTruncated
    if status == esFailed: finalStatus = esFailed
    shared.finished = true
    results = gameSim.ladderResultsJson()
    let privateOutcome = copy(results)
    privateOutcome["engine_rules_version"] = %GameVersion
    privateOutcome["player_cleanup"] = cleanup
    if shared.trajectory.isSome:
      for id, decision in shared.decisions:
        var attempts: seq[DecisionAttempt]
        for evidenceId, evidence in decision.attempts:
          var attempt = readAttemptEvidence(evidence)
          if attempt.origin in {aoTeacher, aoHuman}: attempt.origin = aoUnknown
          if attempt.origin == aoModel and attempt.response.kind == JString:
            let reply = parseReplyObject(attempt.response.getStr())
            if reply.kind == rokParsed:
              attempt.parsedAction = parseDirective(reply.payload,
                gameSim.config.maxActionsPerTurn).directiveJson()
          attempt.accepted = decision.selected == some(evidenceId)
          if attempt.accepted:
            attempt.parsedAction = copy(decision.proposal)
          elif attempt.rejectionReason.isNone:
            attempt.rejectionReason = some("not selected by the authoritative engine")
          attempts.add(attempt)
        if decision.status == asAccepted and decision.selected.isNone:
          var external = newDecisionAttempt(id & "-external", "external-sokoban", aoUnknown)
          external.prompt = %*[{"role": "system", "content": SystemPrompt},
            {"role": "user", "content": userMessage(shared.prompts[0], $decision.view)}]
          external.response = decision.action["action"]
          external.parsedAction = copy(decision.proposal)
          external.accepted = true
          attempts.add(external)
          decision.selected = some(external.attemptId)
        shared.trajectory.get().recordDecision(id, "0", decision.view,
          attempts, decision.selected, decision.applied, decision.status,
          terminal = decision.terminal, fallbackOrigin = decision.fallbackOrigin)
      shared.trajectory.get().finish(finalStatus, privateOutcome,
        if finalStatus == esCompleted: %*{"0": results["scores"][0]} else: newJNull())
    if finalStatus == esCompleted:
      writer.writeChat(gameSim.tick, resultRecord(gameSim))
      replayData = writer.bytes()
  if shared.trajectory.isSome:
    let httpMethod = case getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()
      of "PUT": ahPut
      of "POST": ahPost
      else: raise newException(ValueError, "trajectory method must be PUT or POST")
    shared.trajectory.get().writeTrajectoryArtifact(getEnv(CogameSaveTrajectoryUriEnv),
      cleanupDeadline, httpMethod)
  if finalStatus == esCompleted:
    withLock stateLock:
      broadcastDone(results)
      broadcastPacketLocked(liveChrome())
    writeArtifact(runtimeCfg.replayUri, replayData, "application/octet-stream",
      "COGAME_SAVE_REPLAY_METHOD", cleanupDeadline)
    writeArtifact(runtimeCfg.resultsUri, $results, "application/json",
      "COGAME_RESULTS_METHOD", cleanupDeadline)
    if eventsSinkPath.len > 0:
      writePrivate(eventsSinkPath, log.eventsJsonl(gameSim.tick))
    let grace = min(cleanupDeadline, getMonoTime() + initDuration(milliseconds = 500))
    while getMonoTime() < grace and not interruptionRequested(): sleep(10)

proc writeInitializationCheckpoint*(status: EpisodeStatus, phase, errorType, errorMessage: string,
    episodeDeadline: MonoTime, inputCaptures: JsonNode) =
  ## No game owner exists here, or its joined finalizer already sealed the archive.
  withLock stateLock:
    if shared.finalizationStarted: return
    shared.finalizationStarted = true
  requestNativeStop()
  let uri = getEnv(CogameSaveTrajectoryUriEnv)
  if uri.len == 0: return
  let cleanupDeadline = min(episodeDeadline, getMonoTime() + initDuration(seconds = ShutdownGraceSeconds))
  let episodeId = getEnv("COWORLD_EPISODE_ID")
  let trajectory = newDecisionTrajectory(episodeId,
    "sokoban-initialization-" & episodeId, "sokoban", getEnv("COWORLD_GAME_VERSION"),
    getEnv("COWORLD_SOURCE_REVISION"))
  doAssert status in {esFailed, esTruncated}
  trajectory.finish(status, %*{"reason": "runtime_initialization", "phase": phase,
    "error_type": errorType, "error": errorMessage, "seed_known": false,
    "engine_rules_version": GameVersion, "runtime_inputs": inputCaptures}, newJNull())
  let methodValue = case getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(ValueError, "trajectory method must be PUT or POST")
  trajectory.writeTrajectoryArtifact(uri, cleanupDeadline, methodValue)

proc runGame(unused: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    let writer = newReplayWriter(configJson(config))
    let log = newEventLog(true)
    var ownerStatus = esFailed
    defer: gameServer.close()
    defer:
      if ownerStatus == esFailed: gameSim.settle(endFault, erFault, "runtime failure")
      finishEpisode(writer, log, ownerStatus)
    let gameStart = getMonoTime()
    let playDeadline = min(shared.episodeDeadline - initDuration(seconds = ShutdownGraceSeconds),
      gameStart + initDuration(seconds = config.wallClockBudgetSeconds))
    let lobbySeconds = config.lobbyJoinTimeoutTicks / TargetFps
    let connectDeadline = min(playDeadline,
      gameStart + initDuration(nanoseconds = int64(lobbySeconds * 1_000_000_000)))
    while getMonoTime() < connectDeadline and not interruptionRequested():
      var allConnected = false
      withLock stateLock:
        allConnected = shared.playerSockets.len >= shared.seats
      if allConnected:
        break
      gameSim.lobbyTicks = max(0, (connectDeadline - getMonoTime()).inMilliseconds.int * TargetFps div 1000)
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its register frame.
    let registerDeadline = min(playDeadline, getMonoTime() + initDuration(seconds = 4))
    while getMonoTime() < registerDeadline and not interruptionRequested():
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var noShow = -1
    withLock stateLock:
      shared.started = true
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
          ## LOUD, and the design's rule: a joined seat with no register record
          ## is a defect, not a default. The episode still runs — nothing a
          ## player container does may stop the clock — but the log says so.
          if shared.playerSockets.hasKey(slot):
            echo "sokoban: ERROR seat ", slot, " connected but never sent a ",
              "register frame; refusing to treat it as a policy and seating ",
              "the pusher baseline"
          else:
            echo "sokoban: seat ", slot, " never connected; the seat plays ",
              "the pusher baseline"
          shared.isLlm[slot] = false
          shared.scripted[slot] = blPusher
        gameSim.seats[slot].kind =
          if shared.isLlm[slot]: "llm" else: "scripted"
        gameSim.seats[slot].policyLabel = shared.policies[slot]
        gameSim.seats[slot].baseline = $shared.scripted[slot]
        gameSim.seats[slot].name = shared.names[slot]
        gameSim.seats[slot].registered = shared.everRegistered[slot]
        gameSim.seats[slot].dead = not shared.everRegistered[slot]
      echo "sokoban: starting with ", shared.playerSockets.len, "/",
        shared.seats, " players connected"
    if noShow >= 0:
      declarePlayerFailure(noShow,
        "player slot " & $noShow & " never registered; the seat played the " &
        "pusher baseline", playDeadline)

    for slot in 0 ..< shared.seats:
      writer.writeChat(0, registerRecord(
        slot, seatAlias(slot), gameSim.seats[slot].name,
        gameSim.seats[slot].policyLabel, gameSim.seats[slot].kind,
        gameSim.seats[slot].baseline))

    gameSim.phase = phPlaying
    var
      reason = endComplete
      rule = erLadderComplete
      detail = ""
    while not gameSim.episodeOver() and not interruptionRequested():
      # THE WALL-CLOCK STOP, checked at the top of every loop iteration.
      if getMonoTime() >= playDeadline:
        reason = endDeadline
        rule = erWallClock
        detail = "wall clock budget of " & $config.wallClockBudgetSeconds &
          "s reached at turn " & $gameSim.turnsPlayed
        echo "sokoban: ", detail
        break
      if gameSim.needsLevel():
        let index = gameSim.levelIndex + 1
        let level = generateLevel(
          config.seed, index, gameSim.tierOf(index),
          config.genNodeCap, config.genAttemptCap)
        gameSim.startLevel(level)
        var payload = LevelPayload(
          index: index, tier: level.tier, optPushes: level.optPushes,
          tierRelaxed: level.tierRelaxed,
          rows: gameSim.levels[index].rows,
          dead: gameSim.levels[index].deadList)
        writer.writeLevel(gameSim.tick, payload)
        log.add(seLevelStart, gameSim.tick, %*{
          "level": index, "tier": $level.tier,
          "optPushes": level.optPushes})
      if not gameSim.levelActive:
        break
      let view = gameSim.observationJson(0)
      let budgetMs = min(config.turnBudgetMs,
        max(1, (playDeadline - getMonoTime()).inMilliseconds.int))
      let decision = playerTurn(view, gameSim.turnsPlayed + 1, budgetMs, playDeadline)
      if interruptionRequested(): break
      let outcome = (directive: decision.directive,
                     records: (if decision.cause.len > 0:
                       @[fallbackRecord(gameSim.turnsPlayed + 1, 1,
                         decision.cause, "")]
                       else: newSeq[string]()), view: view)
      var directive = outcome.directive
      for record in outcome.records:
        writer.writeChat(gameSim.tick, record)
        gameSim.noteChatRecord(parseJson(record))
      if directive.source == dsLlm:
        gameSim.seats[0].llmTurns.inc
      elif directive.source == dsFallback:
        gameSim.seats[0].fallbackTurns.inc
      writer.writePlan(gameSim.tick, PlanRecord(
        turn: gameSim.turnsPlayed + 1, level: gameSim.levelIndex,
        source: directive.source, actions: directive.actions,
        say: directive.say, notes: directive.notes))
      log.add(seTurnStart, gameSim.tick, %*{
        "turn": gameSim.turnsPlayed + 1, "source": $directive.source})
      log.add(seDirective, gameSim.tick, %*{
        "turn": gameSim.turnsPlayed + 1, "source": $directive.source,
        "actions": directive.actionsJson(), "latency_ms": directive.latencyMs,
        "dropped": directive.dropped + directive.overCap})
      if directive.source == dsFallback:
        log.add(seFallback, gameSim.tick, %*{
          "turn": gameSim.turnsPlayed + 1})
      gameSim.beginTurn(directive)
      decision.issued.applied = %*{"actions": directive.actionsJson(),
        "say": directive.say, "notes": directive.notes}
      while not gameSim.turnComplete() and not interruptionRequested():
        let before = gameSim.state.player
        let pushesBefore = gameSim.levelPushes
        ## The sim's own derived events accumulate until they are drained
        ## for the broadcast at the end of the turn, so the ones this tick
        ## produced are the entries past this mark. Mapping them here is
        ## what makes the tier-2 stream the FULL action trace the design
        ## note promises `cogamer-rl`, rather than three of its eleven
        ## kinds: nothing else knows a crate went on target, or which of
        ## the three deadlock rules fired.
        let eventMark = gameSim.events.len
        gameSim.stepTick()
        writer.writeHash(gameSim.gameHashValue)
        log.add(seMove, gameSim.tick, %*{
          "from": before, "to": gameSim.state.player,
          "push": gameSim.levelPushes > pushesBefore})
        if gameSim.levelPushes > pushesBefore:
          log.add(sePush, gameSim.tick, %*{
            "from": before, "to": gameSim.state.player,
            "pushes": gameSim.levelPushes})
        for i in eventMark ..< gameSim.events.len:
          let event = gameSim.events[i]
          case event{"k"}.getStr()
          of "boxon": log.add(seBoxOn, gameSim.tick, event.copy())
          of "boxoff": log.add(seBoxOff, gameSim.tick, event.copy())
          of "deadlock": log.add(seDeadlock, gameSim.tick, event.copy())
          of "solved": log.add(seSolved, gameSim.tick, event.copy())
          of "failed": log.add(seFailed, gameSim.tick, event.copy())
          else: discard
        if gameSim.turnEnded:
          break
      if interruptionRequested():
        decision.issued.terminal = true
        break
      gameSim.endTurn(directive.notes)
      decision.issued.terminal = gameSim.episodeOver()
      writer.writeChat(gameSim.tick, directiveRecord(
        gameSim, directive, gameSim.turnsPlayed, 0, outcome.view))
      gameSim.feed.add(parseJson(directiveRecord(
        gameSim, directive, gameSim.turnsPlayed, 0, nil)))
      if gameSim.feed.len > 40:
        gameSim.feed.delete(0)
      withLock stateLock:
        pushFrames()
    if reason == endComplete and not gameSim.ladderComplete():
      rule = erTurnCap
    if interruptionRequested():
      reason = endDeadline
      rule = erWallClock
      detail = "interrupted"
    if reason != endComplete:
      writer.writeStop(StopRecord(tick: gameSim.tick, reason: reason,
        endRule: rule, detail: detail))
    gameSim.settle(reason, rule, detail)
    ownerStatus = if reason == endComplete: esCompleted else: esTruncated

var gameThread: Thread[RuntimeConfig]

proc serveText(request: Request, body, contentType: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  request.respond(200, headers, body)

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    serveText(request, readFile(path), contentType)
  else:
    request.respond(404)

proc servePage(request: Request, path: string) =
  if not fileExists(path):
    request.respond(404)
    return
  var page = readFile(path)
  page = page.spliceWireConstants()
  let chromeCommon = clientDir() / "chrome_common.js"
  if fileExists(chromeCommon):
    page = page.replace("<!-- CHROME_COMMON -->",
      "<script>" & readFile(chromeCommon) & "</script>")
  let core = clientDir() / "broadcast_core.js"
  if fileExists(core):
    page = page.replace("<!-- BROADCAST_CORE -->",
      "<script>" & readFile(core) & "</script>")
  serveText(request, page, "text/html; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  serveText(request, """{"ok":true}""", "application/json")

proc replayPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}: servePage(request, clientDir() / "replay_broadcast.html")

proc playerPageHandler(request: Request) {.gcsafe.} =
  ## Token-checked, and it MUST NOT open the player socket: the certifier
  ## fetches this page as a browser probe before the player pods start.
  {.gcsafe.}:
    let token = request.queryParams["token"]
    var ok = false
    withLock stateLock:
      for candidate in gameSim.config.tokens:
        if candidate == token:
          ok = true
    if not ok and gameSim.config.tokens.len > 0 and token.len > 0:
      request.respond(403)
      return
    serveText(request,
      "<!doctype html><meta charset=utf-8><title>Sokoban seat</title>" &
      "<body style=\"background:#16110d;color:#f2e8d8;font:14px system-ui;" &
      "padding:24px\"><h1>Sokoban</h1><p>The player policy controls this " &
      "seat from the turn observation and action socket.</p>" &
      "<p><a style=\"color:#e8a33d\" href=\"/client/replay\">Watch the " &
      "board</a></p>", "text/html; charset=utf-8")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}: servePage(request, clientDir() / "replay_broadcast.html")

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".js"): "application/javascript; charset=utf-8"
      elif name.endsWith(".css"): "text/css; charset=utf-8"
      elif name.endsWith(".html"): "text/html; charset=utf-8"
      elif name.endsWith(".png"): "image/png"
      elif name.endsWith(".jpg"): "image/jpeg"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, clientDir() / name, contentType)

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayload.len == 0:
      request.respond(404)
      return
    serveText(request, replayPayload, "application/octet-stream")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and (shared.playerSockets.hasKey(slot) or
        shared.everRegistered[slot] or shared.started or shared.stopping or shared.finished)
    if not authorized:
      ## The certifier probes with a WRONG token and requires a close
      ## (cogame-flatland 0.1.1).
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    ## The REAL player name, spectator side only. The platform names a seat on
    ## the player websocket URL (`/player?slot&token&name=`), which is the
    ## starter's own route (`coworld-ctf`'s `playerIdentity`,
    ## `src/ctf/server.nim:471-475`); the registration blob the shipped player
    ## sends carries no name at all, so without this `results.names` fell back
    ## to the POLICY LABEL for every episode.
    let declaredName = request.queryParams["name"]
      .strip().truncateRunes(MaxPolicyLabelRunes)
    withLock stateLock:
      if shared.playerSockets.hasKey(slot) or shared.everRegistered[slot] or
          shared.started or shared.stopping or shared.finished:
        request.respond(409)
        return
      let websocket = request.upgradeToWebSocket()
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      if declaredName.len > 0:
        shared.names[slot] = declaredName
      echo "sokoban: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      try:
        websocket.send($(%*{
          "type": "welcome", "protocol": PlayerProtocolName, "slot": slot,
          "alias": seatAlias(slot),
          "turn_moves": gameSim.config.turnMoves}))
      except CatchableError:
        discard

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      shared.viewerStates[websocket] = initGlobalViewerState()
      var next: GlobalViewerState
      let packet = gameSim.buildViewerPacket(
        shared.viewerStates[websocket], next, liveChrome())
      shared.viewerStates[websocket] = next
      try:
        websocket.send(blobFromBytes(packet), BinaryMessage)
      except CatchableError:
        discard

proc applyRegistration(slot: int, text: string): bool =
  ## Registration carries metadata only. Actions are handled separately.
  var payload: JsonNode
  try:
    payload = parseJson(text)
  except CatchableError:
    return false
  if payload.isNil or payload.kind != JObject:
    return false
  if not payload.hasKey("policy"):
    return false
  let scriptedNode = payload{"scripted"}
  var scriptedName = ""
  if not scriptedNode.isNil and scriptedNode.kind == JString:
    scriptedName = scriptedNode.getStr().strip()
  var isLlm = payload{"kind"}.getStr() == "llm"
  if scriptedName.len > 0:
    isLlm = false
  withLock stateLock:
    if shared.started or shared.stopping or shared.finished or shared.everRegistered[slot]:
      raise newException(ValueError, "player registration is frozen")
    shared.prompts[slot] = payload["prompt"].getStr().truncateRunes(MaxPromptRunes)
    shared.isLlm[slot] = isLlm
    shared.scripted[slot] =
      if scriptedName.len > 0: parseBaseline(scriptedName) else: blPusher
    shared.policies[slot] =
      payload{"policy"}.getStr().truncateRunes(MaxPolicyLabelRunes)
    if shared.policies[slot].len == 0:
      shared.policies[slot] =
        if isLlm: "llm" else: $shared.scripted[slot]
    ## Name resolution, in order: the registration blob, then the name the
    ## platform put on the socket URL, then — only when neither exists — the
    ## policy label, which is what a local run has. The alias (`Alpha`) is a
    ## different name space and never appears here.
    let registeredName =
      payload{"name"}.getStr().strip().truncateRunes(MaxPolicyLabelRunes)
    if registeredName.len > 0:
      shared.names[slot] = registeredName
    elif shared.names[slot].len == 0:
      shared.names[slot] = shared.policies[slot]
    shared.registered[slot] = true
    shared.everRegistered[slot] = true
  echo "sokoban: slot ", slot, " registered (",
    (if isLlm: "llm" else: "scripted " & scriptedName), ")"
  true

proc applyPlayerFrame(slot: int, websocket: WebSocket, text: string,
    receivedAt: MonoTime): bool =
  var payload: JsonNode
  try:
    payload = parseJson(text)
    if payload.kind != JObject or not payload.hasKey("type") or payload["type"].kind != JString:
      return false
    let frameType = payload["type"].getStr()
    if frameType notin ["attempt_started", "action", "stopped"]: return false
    withLock stateLock:
      if shared.finished: return true
      if slot != 0 or not shared.everRegistered[slot]:
        raise newException(ValueError, "player frame lacks authenticated registration")
      if frameType == "stopped":
        if payload["worker_status"].getStr() notin ["joined", "no_active_call"] or
            payload["attempts"].kind != JArray:
          raise newException(ValueError, "invalid stopped owner evidence")
        let id = payload["decision_id"]
        if id.kind == JNull:
          if payload["attempts"].len != 0:
            raise newException(ValueError, "unissued stop has native attempts")
        else:
          if id.kind != JString or not shared.decisions.hasKey(id.getStr()):
            raise newException(ValueError, "stopped evidence has an unissued decision")
          for evidence in payload["attempts"]:
            retainAttempt(shared.decisions[id.getStr()], evidence, receivedAt, true)
        # Fact delivery precedes nonce credit; genuine older or self-stopped bytes survive.
        if shared.playerSockets.hasKey(slot) and shared.playerSockets[slot] == websocket:
          websocket.send($ %*{"type": "evidence_received", "decision_id": id,
            "stop_id": payload["stop_id"]})
        let expected = if shared.latestDecision.len > 0: %shared.latestDecision else: newJNull()
        if not shared.stopping or id != expected or payload["stop_id"] != %shared.stopId or
            receivedAt < shared.stopIssuedAt or receivedAt > shared.acknowledgementDeadline:
          raise newException(ValueError, "stop acknowledgement differs from issued cleanup window")
        for evidence in payload["attempts"]:
          if readAttemptEvidence(evidence).responseReaderJoined == some(false):
            raise newException(ValueError, "stopped owner retains an unjoined native reader")
        shared.acknowledgedSlots.incl(slot)
      else:
        let id = payload["decision_id"].getStr()
        if not shared.decisions.hasKey(id):
          raise newException(ValueError, "player frame has an unissued decision")
        let decision = shared.decisions[id]
        let evidence = payload["training_attempt"]
        if evidence.kind != JNull:
          retainAttempt(decision, evidence, receivedAt, frameType == "action")
        elif frameType == "attempt_started":
          raise newException(ValueError, "native start has no private evidence")
        if frameType == "action":
          if shared.stopping or id != shared.latestDecision or
              receivedAt < decision.issuedAt or receivedAt > decision.deadline:
            raise newException(ValueError, "action is outside the issued decision window")
          if decision.action.kind != JNull:
            raise newException(ValueError, "decision already has an action")
          if payload["source"].getStr() == "llm" and evidence.kind == JNull:
            raise newException(ValueError, "native action has no response evidence")
          decision.action = copy(payload)
          decision.actionReceivedAt = receivedAt
    true
  except CatchableError:
    echo "sokoban: rejected invalid private player frame"
    true

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      let receivedAt = getMonoTime()
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global AND /player to check the game is alive, so an unanswered ping
      ## fails certification. NOTHING else is guarded here: a
      ## `kind != TextMessage` guard drops the player's BINARY registration
      ## frames (lux-ai 0.1.0, snake-royale 0.1.0).
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        # A global viewer's transport command.
        withLock stateLock:
          if websocket in shared.viewerStates:
            var state = shared.viewerStates[websocket]
            state.applyGlobalViewerMessage(message.data)
            state.replayCommands.setLen(0)
            state.replaySeekTick = -1
            shared.viewerStates[websocket] = state
        return
      # The seat registers through the Sprite v1 chat channel (0x81) or, for a
      # plain text client, as a bare JSON frame.
      var handled = false
      for item in message.data.parseSpriteClientMessages():
        if item.kind == SpriteClientChatMessage:
          if applyRegistration(slot, item.text):
            handled = true
      if not handled:
        if message.kind == TextMessage and applyPlayerFrame(slot, websocket, message.data, receivedAt):
          return
        discard applyRegistration(slot, message.data)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let closing = shared.socketSlots[websocket]
          # Retain authenticated bindings for already-received callbacks until seal.
          if shared.playerSockets.getOrDefault(closing) == websocket:
            shared.playerSockets.del(closing)
          ## A seat that drops keeps playing: nothing a player container does
          ## can stop the clock.
          shared.registered[closing] = shared.everRegistered[closing]
        shared.globalSockets.excl(websocket)
        shared.viewerStates.del(websocket)

proc buildRouter(replayMode: bool): Router =
  ## The certifier's probes are registered BEFORE the catch-all asset route.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/replay", replayPageHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc stopReplayAtDeadline(deadline: MonoTime) {.gcsafe.} =
  {.gcsafe.}:
    while getMonoTime() < deadline and not interruptionRequested(): sleep(10)
    gameServer.close()

proc runReplayServer*(runtimeConfig: RuntimeConfig, episodeDeadline: MonoTime) =
  replayPayload = runtimeConfig.replay
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "sokoban: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  var owner: Thread[MonoTime]
  var ownerCreated = false
  try:
    gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host,
      onReady = proc(server: Server) {.gcsafe.} =
        {.gcsafe.}:
          createThread(owner, stopReplayAtDeadline, episodeDeadline)
          ownerCreated = true)
  finally:
    requestNativeStop()
    if ownerCreated: joinThread(owner)

proc stopServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig, episodeDeadline: MonoTime) =
  if config.tokens.len != config.numAgents:
    raise newException(SokobanError,
      "tokens must name exactly num_agents seats")
  runtimeCfg = runtimeConfig
  eventsSinkPath = requireFileUri("COGAME_EVENTS_URI")
  shared.episodeDeadline = episodeDeadline
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    shared.trajectory = some(newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
      "sokoban-" & $config.seed, "sokoban", getEnv("COWORLD_GAME_VERSION"),
      getEnv("COWORLD_SOURCE_REVISION")))
  gameSim = newSimServer(config)
  shared.seats = config.numAgents
  shared.scripted = newSeq[Baseline](shared.seats)
  shared.isLlm = newSeq[bool](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.prompts = newSeq[string](shared.seats)
  shared.names = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  for slot in 0 ..< shared.seats:
    shared.policies[slot] = "pusher"
    shared.names[slot] = ""
  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4,
    maxMessageLen = 16 * 1024 * 1024)
  var ownerCreated = false
  echo "sokoban: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  try:
    gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host,
      onReady = proc(server: Server) {.gcsafe.} =
        {.gcsafe.}:
          createThread(gameThread, runGame, runtimeConfig)
          ownerCreated = true)
  finally:
    requestNativeStop()
    if ownerCreated: joinThread(gameThread)
