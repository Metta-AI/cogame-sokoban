## The decision layer: the per-turn loop that asks the seat what it does next,
## and ALWAYS has an answer.
##
## Cadence: one command turn every <= 20 ticks, at most 60 turns per episode.
## THE PER-TURN LLM CALL BUDGET IS EXACTLY ONE REQUEST, PLUS AT MOST ONE RETRY.
## There is a single seat, so the starter's one-parallel-batch-per-turn
## machinery (`curly.makeRequests`) carries a batch of one and is otherwise
## untouched: at most 60 x 2 = 120 provider calls per episode, never more than
## one in flight.
##
## DEGRADE, NEVER HANG. Every wait is bounded: attempt 1 gets `attempt1Ms`, the
## single retry gets `retryMs`, the whole turn is wrapped in a monotonic
## `turnBudgetMs` deadline, a rolling 60 s request counter refuses a call that
## would cross the sidecar's per-episode cap, and the budget guard switches the
## LLM off for the rest of the episode the moment two more full turns would not
## fit inside the engine's wall-clock stop.
##
## On the seat's timeout or parse failure the call is RETRIED ONCE; on the
## second failure the turn's plan becomes the `pusher` scripted plan computed
## inside the game — the same proc the `pusher` baseline uses, imported, never
## duplicated. The attempt-1 notice says "will retry"; only a genuine second
## failure logs "falling back" (the pommerman 0.1.1 phase-60 grep scar).

import std/[json, monotimes, os, strutils, times]
import curly
import sim_types, sim, directives, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `pusher`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: seq[SeatPolicy]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool               ## the budget guard fired; scripted from here on
    requestTimes*: seq[MonoTime]  ## the rolling 60 s request counter
    records*: seq[string]       ## chat records queued for the replay writer

const
  RollingWindowSeconds = 60
  RollingRequestCap = 28
    ## `turnSpacingMs` pins the steady state at 23 req/min, but a run of
    ## retrying turns issues two requests each. If issuing the next request
    ## would push the trailing-60 s count above this, the turn skips the call
    ## and takes the `pusher` plan with `cause = "rate_guard"`. Bounded,
    ## logged, and never a sleep on the episode's critical path (the raid
    ## round 2 sidecar-throttle scar).

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blPusher
    result.seats[i].label = "pusher"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm: "llm"
  else: "scripted"

proc fallbackRecord*(turn, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback", "turn": turn, "attempt": attempt, "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(
  slot: int, alias, name, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written: only
  ## the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register", "slot": slot, "alias": alias, "name": name,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind, "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc directiveRecord*(
  sim: SimServer, directive: Directive, turn, slot: int, view: JsonNode
): string =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## `tools/replay_summary.py` and can never affect the simulation.
  var record = %*{
    "k": "directive",
    "turn": turn,
    "level": sim.levelIndex,
    "slot": slot,
    "alias": seatAlias(slot),
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "actions": directive.actionsJson(),
    "executed": sim.lastReport.executed,
    "pushes": sim.lastReport.pushes,
    "blocked": sim.lastReport.blocked,
    "truncated": sim.lastReport.truncated,
    "dropped": sim.lastReport.dropped,
    "unreachable": sim.lastReport.unreachable,
    "say": directive.say
  }
  if not view.isNil:
    # The observation MINUS `notes`, so the replay explains every decision.
    var mirrored = view.copy()
    if mirrored.hasKey("notes"):
      mirrored.delete("notes")
    record["view"] = mirrored
  boundedRecord(record, "say", "detail")

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what makes
  ## the replay SELF-SUFFICIENT: without it the outcome exists only at
  ## `COGAME_RESULTS_URI`.
  "{\"k\":\"result\",\"results\":" & $sim.ladderResultsJson() & "}"

proc pruneWindow(engine: var DecisionEngine) =
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in engine.requestTimes:
    if (now - stamp).inSeconds < RollingWindowSeconds:
      kept.add(stamp)
  engine.requestTimes = kept

proc rateGuardBlocks(engine: var DecisionEngine): bool =
  engine.pruneWindow()
  engine.requestTimes.len >= RollingRequestCap

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex: int,
  elapsedSeconds: int
): tuple[directive: Directive, records: seq[string], view: JsonNode] =
  ## Runs ONE decision turn for the single seat and returns its directive plus
  ## the replay chat records the turn produced. NEVER RAISES: every failure path
  ## ends in a legal directive.
  const seat = 0
  let budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
  ## `turnBudgetMs` is the deadline around the DECISION — the attempt and its
  ## single retry — which is the invariant `sim_config.validate` enforces
  ## (`attempt1Ms + retryMs <= turnBudgetMs`). It is taken below, AFTER the
  ## `turnSpacingMs` rate floor, because that sleep is not part of the
  ## decision: it is a deliberate, separately bounded rate limit, and counting
  ## it inside the budget would silently shorten the retry on exactly the
  ## turns that had to wait. The two bounds are added explicitly in the budget
  ## guard below, so the episode arithmetic still holds.
  var turnStart = getMonoTime()
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false
  result.view = sim.observationJson(seat)

  template scripted(kind: Baseline): Directive =
    ## Templates, not closures: `engine` is a `var` parameter and a closure over
    ## it would not be memory safe.
    block:
      var directive = sim.scriptedDirective(kind)
      directive.source = dsScripted
      directive

  template fallbackPlan(cause, detail: string, attempt: int): Directive =
    ## The `pusher` scripted plan computed server-side — the SAME proc the
    ## `pusher` baseline uses, imported, never duplicated.
    block:
      var directive = sim.scriptedDirective(blPusher)
      directive.source = dsFallback
      directive.notes = ""
      engine.records.add(fallbackRecord(turnIndex, attempt, cause, detail))
      directive

  # --- budget guard: settle EARLY rather than overrun ----------------------
  ## The reserve is the REAL worst case of a turn: the rate floor plus the
  ## whole decision budget. A turn that burns both attempts costs
  ## `turnBudgetMs`, and a turn that follows a fast one additionally pays up to
  ## `turnSpacingMs` before it starts, so two more turns can cost
  ## `2 x (turnSpacingMs + turnBudgetMs)` = 23.2 s, not the 18 s the budget
  ## alone reserves. Reserving the smaller figure is how the guard lets the
  ## episode reach the engine's hard stop instead of settling ahead of it.
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000 +
      (max(0, sim.config.turnSpacingMs) + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      engine.records.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "sokoban: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  if not engine.seats[seat].isLlm:
    result.directive = scripted(engine.seats[seat].baseline)
    result.records = engine.records
    engine.records = @[]
    return

  if engine.llmOff or engine.client.disabled:
    let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
    result.directive = fallbackPlan(
      cause, "the LLM is unavailable for this turn; playing pusher", 1)
    echo "sokoban llm: seat ", seat, " falling back to pusher (", cause,
      ") on turn ", turnIndex
    result.records = engine.records
    engine.records = @[]
    return

  if engine.rateGuardBlocks():
    result.directive = fallbackPlan(
      "rate_guard", "the trailing 60 s request count is at the cap", 1)
    echo "sokoban llm: seat ", seat, " falling back to pusher (rate_guard)",
      " on turn ", turnIndex
    result.records = engine.records
    engine.records = @[]
    return

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE. Hold the START of
  # consecutive requests `turnSpacingMs` apart, which pins the episode at
  # 23 req/min. The cert fixture sets it to 0, so offline runs pay nothing.
  if engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  engine.lastBatchStart = getMonoTime()
  engine.batchStarted = true
  ## The decision deadline starts here, after the rate floor.
  turnStart = getMonoTime()

  var
    attempt = 0
    lastCause = "parse_error"
    lastDetail = "no usable reply"
  while attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      lastCause = "timeout"
      lastDetail = "per-turn budget exhausted before attempt " & $(attempt + 1)
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var user = $result.view
    if attempt > 0:
      user.add("\n\nYour previous reply was not usable. Reply with ONLY the " &
        "JSON object described above, starting with '{', with an \"actions\" " &
        "array of at most 8 entries.")
    let request = engine.client.requestFor(
      SystemPrompt, userMessage(engine.seats[seat].prompt, user))
    # ONE seat, so this is a batch of ONE through the starter's unchanged
    # batching path. The code is the starter's; the batch simply carries one
    # request.
    var batch: RequestBatch
    batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    engine.requestTimes.add(started)
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion floors — and sim_config REJECTS a config that
    # is not a whole number of seconds, so the floor below is an identity.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    try:
      let text = engine.client.textOf(
        responses[0].response, responses[0].error, batch[0].url)
      var directive = parseDirective(
        extractJsonObject(text), sim.config.maxActionsPerTurn)
      directive.source = dsLlm
      directive.latencyMs = latency
      result.directive = directive
      result.records = engine.records
      engine.records = @[]
      return
    except CatchableError as error:
      lastDetail = error.msg
      if responses[0].error.len > 0:
        lastCause =
          if "timeout" in responses[0].error.toLowerAscii(): "timeout"
          else: "transport_error"
      elif error.msg.startsWith("llm throttled"):
        ## A 429 is the provider refusing the call, so it is recorded as a
        ## `transport_error`: the design note's `fallback.cause` set is CLOSED
        ## — {timeout, parse_error, transport_error, no_credentials,
        ## rate_guard, budget_guard, disconnected} — and `rate_guard` is
        ## reserved for this engine's OWN rolling counter, which is a
        ## different fact about a different actor.
        lastCause = "transport_error"
      else:
        lastCause = "parse_error"
      if attempt == 0:
        ## "will retry" — NOT "falling back". Only a genuine second failure may
        ## say "falling back", which is the phrase phase 60 greps for.
        echo "sokoban llm: seat ", seat, " attempt 1 failed, will retry: ",
          error.msg
        engine.records.add(fallbackRecord(turnIndex, 1, lastCause, error.msg))
    inc attempt
    if engine.client.throttled:
      # FAIL FAST. The only model left answered 429, so the retry would be
      # refused the same way: spend the rest of the turn on the scripted layer.
      echo "sokoban llm: provider throttled with no other candidate; seat ",
        seat, " falls back for turn ", turnIndex
      break

  result.directive = fallbackPlan(lastCause, lastDetail, 2)
  echo "sokoban llm: seat ", seat, " falling back to pusher (", lastCause,
    ") on turn ", turnIndex
  result.records = engine.records
  engine.records = @[]
