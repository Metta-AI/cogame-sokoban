## The sim: the numbered turn/tick resolution order of the design note, the
## per-tick hash chain, level and episode end evaluation, scoring, and the
## seat's observation builder.
##
## Imports and re-exports the sim modules, as the starter's `src/ctf/sim.nim`
## does, so `import sokoban/sim` sees everything.
##
## ALL SIM ARITHMETIC IS INTEGER. There is no floating point in this module or
## in grid/deadlock/levelgen/search/driver/baselines, and
## `tests/test_sokoban_sim.nim` greps for it. That makes the native <-> wasm
## hash chain exact by construction.

import std/json
import sim_types, sim_config, grid, deadlock, levelgen, search, driver,
  directives, baselines
export sim_types, sim_config, grid, deadlock, levelgen, search, driver,
  directives, baselines

type
  LevelRecord* = object
    tier*: Tier
    optPushes*: int
    outcome*: LevelOutcome
    boxesPlaced*: int
    moves*: int
    turns*: int
    pushes*: int
    tierRelaxed*: bool
    rows*: seq[string]      ## the ten XSB rows at level start
    deadList*: seq[int]

  SeatInfo* = object
    name*: string           ## the REAL policy name — spectator side only
    alias*: string          ## the in-game alias: `Alpha`
    policyLabel*: string
    kind*: string           ## "llm" | "scripted"
    baseline*: string
    registered*: bool
    joined*: bool
    dead*: bool
    llmTurns*: int
    fallbackTurns*: int

  TurnReport* = object
    ## What the seat is told about its own last turn.
    executed*: string
    pushes*: int
    blocked*: int
    truncated*: bool
    dropped*: int
    unreachable*: int
    notes*: string
    valid*: bool

  SimServer* = ref object
    config*: GameConfig
    phase*: Phase
    tick*: int
    startTick*: int
    turnsPlayed*: int
    lobbyTicks*: int
    gameOverHold*: int

    levelIndex*: int          ## 0-based index of the level in play
    level*: Level
    state*: LevelState
    levelActive*: bool
    levelMove*: int
    levelTurn*: int
    levelPushes*: int
    levelBoxesPlaced*: int
    levels*: seq[LevelRecord]

    queue*: seq[Primitive]
    queueIndex*: int
    turnTruncated*: bool
    turnUnreachable*: int
    turnDropped*: int         ## entries this turn's reply lost: failed
                              ## validation plus the ones past the cap
    turnPushes*: int
    turnBlocked*: int
    turnExecuted*: string
    turnEnded*: bool

    pushesTotal*: int
    blockedMoves*: int
    deadlocks*: int
    outOfSteps*: int
    actionsDropped*: int
    macrosUnreachable*: int
    repliesRepaired*: int

    reason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    seats*: seq[SeatInfo]
    lastReport*: TurnReport
    lastSay*: string

    gameHashValue*: uint64
    hashes*: seq[uint64]
    events*: seq[JsonNode]    ## derived broadcast events for this frame
    feed*: seq[JsonNode]      ## directive/fallback records for the feed

const SeatAliases* = ["Alpha", "Bravo", "Charlie", "Delta"]

proc seatAlias*(slot: int): string =
  ## `IdentityNames[slot]` title-cased. With one seat this is always `Alpha`,
  ## and it is the ONLY name that appears in an observation, in a prompt, in a
  ## `say`, or drawn on the board.
  if slot >= 0 and slot < SeatAliases.len: SeatAliases[slot] else: "Cog"

proc newSimServer*(config: GameConfig): SimServer =
  result = SimServer(
    config: config,
    phase: phLobby,
    reason: endComplete,
    endRule: erLadderComplete,
    levelIndex: -1
  )
  for slot in 0 ..< max(1, config.numAgents):
    result.seats.add(SeatInfo(
      name: "",
      alias: seatAlias(slot),
      policyLabel: "pusher",
      kind: "scripted",
      baseline: "pusher"))
  for i in 0 ..< config.levelCount:
    result.levels.add(LevelRecord(
      tier: (if i < config.tierLadder.len: config.tierLadder[i]
             else: tierUnfiltered),
      outcome: loUnreached))

proc seatCount*(sim: SimServer): int = sim.seats.len

proc tierOf*(sim: SimServer, index: int): Tier =
  if index >= 0 and index < sim.config.tierLadder.len:
    sim.config.tierLadder[index]
  else:
    tierUnfiltered

# ---------------------------------------------------------------------------
#  The hash chain
# ---------------------------------------------------------------------------

proc mixHash(value: var uint64, word: int64) {.inline.} =
  value = (value xor uint64(word)) * 0x100000001B3'u64
  value = value xor (value shr 29)

proc computeGameHash*(sim: SimServer): uint64 =
  ## Mixes, in this FIXED order: levelIndex, levelMove; the player's (x, y);
  ## every cell of the 10 x 10 grid in ascending (y, x) as
  ## (isWall, isTarget, hasBox); boxesOnTargets, levelBoxesPlaced, pushes,
  ## blockedMoves; the six levelOutcome codes and six levelBoxesPlaced values;
  ## then tick. Any reordering is a replay-format change and needs a
  ## GameVersion bump.
  result = 0xCBF29CE484222325'u64
  result.mixHash(int64(sim.levelIndex))
  result.mixHash(int64(sim.levelMove))
  result.mixHash(int64(cellX(sim.state.player)))
  result.mixHash(int64(cellY(sim.state.player)))
  for cell in 0 ..< GridCells:
    var code = 0
    if sim.state.board.wall[cell]: code = code or 1
    if sim.state.board.target[cell]: code = code or 2
    if sim.state.hasBox(cell): code = code or 4
    result.mixHash(int64(code))
  result.mixHash(int64(sim.state.boxesOnTargets()))
  result.mixHash(int64(sim.levelBoxesPlaced))
  result.mixHash(int64(sim.levelPushes))
  result.mixHash(int64(sim.blockedMoves))
  for record in sim.levels:
    result.mixHash(int64(ord(record.outcome)))
    result.mixHash(int64(record.boxesPlaced))
  result.mixHash(int64(sim.tick))

proc gameHash*(sim: SimServer): uint64 = sim.gameHashValue

# ---------------------------------------------------------------------------
#  Events
# ---------------------------------------------------------------------------

proc emit(sim: SimServer, node: JsonNode) =
  node["t"] = %sim.tick
  sim.events.add(node)

proc drainEvents*(sim: SimServer): JsonNode =
  result = newJArray()
  for node in sim.events:
    result.add(node)
  sim.events.setLen(0)

# ---------------------------------------------------------------------------
#  Levels
# ---------------------------------------------------------------------------

proc needsLevel*(sim: SimServer): bool =
  ## True when the driver must supply the next level: either nothing is in play
  ## or the level in play has finished.
  not sim.levelActive and sim.levelIndex + 1 < sim.config.levelCount

proc ladderComplete*(sim: SimServer): bool =
  not sim.levelActive and sim.levelIndex + 1 >= sim.config.levelCount

proc startLevel*(sim: SimServer, level: Level) =
  ## Starts the next level from a level the DRIVER supplied — generated live,
  ## or read back from the replay bytes. The sim never calls the generator
  ## itself, which is what lets the wasm viewer re-derive every frame with no
  ## generator call and no fetch.
  inc sim.levelIndex
  sim.level = level
  sim.state = level.state
  sim.levelActive = true
  sim.levelMove = 0
  sim.levelTurn = 0
  sim.levelPushes = 0
  sim.levelBoxesPlaced = sim.state.boxesOnTargets()
  var record = sim.levels[sim.levelIndex]
  record.tier = level.tier
  record.optPushes = level.optPushes
  record.outcome = loRunning
  record.tierRelaxed = level.tierRelaxed
  record.rows = sim.state.renderXsb()
  record.deadList = level.dead.deadSquareList()
  record.boxesPlaced = sim.levelBoxesPlaced
  sim.levels[sim.levelIndex] = record
  var boxes = newJArray()
  for box in sim.state.boxes:
    boxes.add(%[cellX(box), cellY(box)])
  var targets = newJArray()
  for cell in 0 ..< GridCells:
    if sim.state.board.target[cell]:
      targets.add(%[cellX(cell), cellY(cell)])
  sim.emit(%*{
    "k": "levelstart", "i": sim.levelIndex, "tier": $level.tier,
    "optPushes": level.optPushes, "boxes": boxes, "targets": targets,
    "relaxed": level.tierRelaxed
  })

proc finishLevel*(sim: SimServer, outcome: LevelOutcome) =
  sim.levelActive = false
  var record = sim.levels[sim.levelIndex]
  record.outcome = outcome
  record.boxesPlaced = sim.levelBoxesPlaced
  record.moves = sim.levelMove
  record.turns = sim.levelTurn
  record.pushes = sim.levelPushes
  sim.levels[sim.levelIndex] = record
  case outcome
  of loSolved:
    sim.emit(%*{"k": "solved", "i": sim.levelIndex, "moves": sim.levelMove,
                "pushes": sim.levelPushes, "turns": sim.levelTurn})
  of loDeadlocked:
    inc sim.deadlocks
    sim.emit(%*{"k": "failed", "i": sim.levelIndex, "why": "deadlocked"})
  of loOutOfSteps:
    inc sim.outOfSteps
    sim.emit(%*{"k": "failed", "i": sim.levelIndex, "why": "outofsteps"})
  else:
    discard

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc beginTurn*(sim: SimServer, directive: Directive) =
  ## Installs one turn's plan. The macros are expanded against the TURN-START
  ## snapshot; the whole expanded queue is truncated to `turnMoves` and nothing
  ## carries over.
  let expansion = expandDirective(
    sim.state, directive, sim.config.turnMoves, sim.config.macroPrimitiveCap)
  sim.queue = expansion.queue
  sim.queueIndex = 0
  sim.turnTruncated = expansion.truncated
  sim.turnUnreachable = expansion.unreachable
  sim.turnDropped = directive.dropped + directive.overCap
  sim.turnPushes = 0
  sim.turnBlocked = 0
  sim.turnExecuted = ""
  sim.turnEnded = false
  ## The two counters are DISJOINT, as the design note's turn steps 6a and 6b
  ## describe them: `actionsDropped` counts the entries past
  ## `maxActionsPerTurn`, `repliesRepaired` counts the entries that failed
  ## validation. A phase-60 reader adds them for the total.
  sim.actionsDropped += directive.overCap
  sim.macrosUnreachable += expansion.unreachable
  sim.repliesRepaired += directive.dropped
  inc sim.turnsPlayed
  inc sim.levelTurn
  sim.lastSay = directive.say
  sim.emit(%*{"k": "turn", "n": sim.turnsPlayed, "level": sim.levelIndex,
              "levelTurn": sim.levelTurn})
  sim.emit(%*{
    "k": "plan", "n": sim.turnsPlayed, "moves": expansion.queue.len,
    "actions": directive.actions.len, "truncated": expansion.truncated,
    "dropped": directive.dropped + directive.overCap,
    "unreachable": expansion.unreachable, "source": $directive.source
  })
  if directive.say.len > 0:
    sim.emit(%*{"k": "say", "text": directive.say})
  if directive.source == dsFallback:
    sim.emit(%*{"k": "fallback", "cause": "fallback"})

proc turnMovesLeft*(sim: SimServer): int =
  max(0, sim.config.turnMoves - sim.queueIndex)

proc stepTick*(sim: SimServer) =
  ## ONE tick, in the numbered order of the design note's §Turn and tick
  ## structure. THIS IS THE WHOLE PHYSICS OF THE GAME and nothing else mutates
  ## the world.
  if sim.turnEnded or not sim.levelActive:
    return
  # 1. tick += 1; levelMove += 1
  inc sim.tick
  inc sim.levelMove
  # 2. pop the next primitive; an empty queue is a `wait` (a real cost)
  let primitive = queueOrWait(
    Expansion(queue: sim.queue), sim.queueIndex)
  inc sim.queueIndex
  sim.turnExecuted.add(primitive.primitiveChar())

  # 3. apply the primitive
  var boxMoved = false
  if not primitive.isWait:
    let
      ahead = sim.state.player.step(primitive.dir)
      beyond = sim.state.player.step2(primitive.dir)
    if ahead < 0 or sim.state.board.wall[ahead]:
      inc sim.blockedMoves
      inc sim.turnBlocked
    else:
      let box = sim.state.boxAt(ahead)
      if box >= 0:
        if beyond < 0 or not sim.state.isFree(beyond):
          inc sim.blockedMoves
          inc sim.turnBlocked
        else:
          let wasTarget = sim.state.board.target[ahead]
          sim.state.boxes[box] = beyond
          sim.state.sortBoxes()
          sim.state.player = ahead
          inc sim.levelPushes
          inc sim.pushesTotal
          inc sim.turnPushes
          boxMoved = true
          let boxIndex = sim.state.boxAt(beyond)
          if sim.state.board.target[beyond]:
            sim.emit(%*{"k": "boxon", "box": boxIndex,
                        "x": cellX(beyond), "y": cellY(beyond),
                        "placed": sim.state.boxesOnTargets()})
          if wasTarget:
            sim.emit(%*{"k": "boxoff", "box": boxIndex,
                        "x": cellX(ahead), "y": cellY(ahead),
                        "placed": sim.state.boxesOnTargets()})
      else:
        sim.state.player = ahead

  # 4. recompute boxesOnTargets; levelBoxesPlaced is a running MAXIMUM
  let onTargets = sim.state.boxesOnTargets()
  if onTargets > sim.levelBoxesPlaced:
    sim.levelBoxesPlaced = onTargets

  # 5. level termination, evaluated in this order and ONLY when boxMoved
  var finished = false
  if boxMoved:
    if onTargets == BoxCount:
      sim.finishLevel(loSolved)
      finished = true
    else:
      let verdict = sim.state.isDeadlocked(sim.level.dead)
      if verdict.dead:
        sim.emit(%*{"k": "deadlock", "kind": $verdict.kind, "box": verdict.box,
                    "x": cellX(verdict.cell), "y": cellY(verdict.cell)})
        sim.finishLevel(loDeadlocked)
        finished = true

  # 6. the step cap, checked on EVERY tick
  if not finished and sim.levelMove >= sim.config.stepBudget:
    sim.finishLevel(loOutOfSteps)
    finished = true

  # 7. mix the tick into gameHash and append it to the chain
  sim.gameHashValue = sim.computeGameHash()
  sim.hashes.add(sim.gameHashValue)

  # 8. a finished level breaks out of the tick loop — the turn ends early
  if finished:
    sim.turnEnded = true

proc turnComplete*(sim: SimServer): bool =
  sim.turnEnded or sim.queueIndex >= sim.config.turnMoves

proc endTurn*(sim: SimServer, notes: string) =
  ## Records what the seat is told about its own last turn. `dropped` is the
  ## REAL count — the entries that failed validation plus the ones past
  ## `maxActionsPerTurn` — and it is the same number the replay's `directive`
  ## record carries (`decide.nim`'s `directiveRecord`). Both champion prompts
  ## tell the seat to read `last_turn`, so a hard-coded zero would silently
  ## disable the self-correction loop for every malformed entry.
  sim.lastReport = TurnReport(
    executed: sim.turnExecuted,
    pushes: sim.turnPushes,
    blocked: sim.turnBlocked,
    truncated: sim.turnTruncated,
    dropped: sim.turnDropped,
    unreachable: sim.turnUnreachable,
    notes: notes,
    valid: true)

# ---------------------------------------------------------------------------
#  Scoring
# ---------------------------------------------------------------------------

proc solvedWeight*(sim: SimServer): int =
  for record in sim.levels:
    if record.outcome == loSolved:
      result += TierWeights[record.tier]

proc levelsSolved*(sim: SimServer): int =
  for record in sim.levels:
    if record.outcome == loSolved:
      inc result

proc boxCredit*(sim: SimServer): int =
  for record in sim.levels:
    result += record.boxesPlaced

proc movesSavedTotal*(sim: SimServer): int =
  for record in sim.levels:
    if record.outcome == loSolved:
      result += max(0, sim.config.stepBudget - record.moves)

proc episodeScore*(sim: SimServer): int =
  ## `scores[0] = 1_000_000 * solvedWeight + 10_000 * boxCredit +
  ## movesSavedTotal`. Higher is better and EVERY TERM ONLY EVER ADDS: the
  ## minimum, 0, is the honest score of a cog that solved nothing and never got
  ## a crate onto a marked square. There is no penalty term for deadlocking.
  1_000_000 * sim.solvedWeight() + 10_000 * sim.boxCredit() +
    sim.movesSavedTotal()

proc episodeWin*(sim: SimServer): bool =
  sim.solvedWeight() >= sim.config.parWeight

proc finalTick*(sim: SimServer): int =
  for record in sim.levels:
    result += record.moves

# ---------------------------------------------------------------------------
#  Results
# ---------------------------------------------------------------------------

proc ladderResultsJson*(sim: SimServer): JsonNode =
  ## The CLOSED results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key
  ## set in the same commit — Coworld schemas are closed and undeclared keys
  ## are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    policyKinds = newJArray()
    deadSeats = newJArray()
  for seat in sim.seats:
    names.add(%(if seat.name.len > 0: seat.name else: seat.policyLabel))
    aliases.add(%seat.alias)
    policyKinds.add(%seat.kind)
    deadSeats.add(%seat.dead)
  scores.add(%sim.episodeScore())
  win.add(%sim.episodeWin())
  var
    tiers = newJArray()
    optPushes = newJArray()
    outcomes = newJArray()
    placed = newJArray()
    moves = newJArray()
    turns = newJArray()
    pushes = newJArray()
    relaxed = newJArray()
  for record in sim.levels:
    tiers.add(%($record.tier))
    optPushes.add(%record.optPushes)
    outcomes.add(%($(if record.outcome == loRunning: loUnreached
                     else: record.outcome)))
    placed.add(%record.boxesPlaced)
    moves.add(%record.moves)
    turns.add(%record.turns)
    pushes.add(%record.pushes)
    relaxed.add(%record.tierRelaxed)
  var llmTurns = 0
  var fallbackTurns = 0
  for seat in sim.seats:
    llmTurns += seat.llmTurns
    fallbackTurns += seat.fallbackTurns
  result = %*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "winner": (if sim.episodeWin(): %0 else: newJNull()),
    "reason": $sim.reason,
    "endRule": $sim.endRule,
    "variant": sim.config.variant,
    "seed": sim.config.seed,
    "levelCount": sim.config.levelCount,
    "stepBudget": sim.config.stepBudget,
    "parWeight": sim.config.parWeight,
    "maxWeight": (block:
      var total = 0
      for tier in sim.config.tierLadder: total += TierWeights[tier]
      total),
    "solvedWeight": sim.solvedWeight(),
    "levelsSolved": sim.levelsSolved(),
    "boxCredit": sim.boxCredit(),
    "movesSavedTotal": sim.movesSavedTotal(),
    "levelTier": tiers,
    "levelOptPushes": optPushes,
    "levelOutcome": outcomes,
    "levelBoxesPlaced": placed,
    "levelMoves": moves,
    "levelTurns": turns,
    "levelPushes": pushes,
    "levelTierRelaxed": relaxed,
    "deadlocks": sim.deadlocks,
    "outOfSteps": sim.outOfSteps,
    "pushesTotal": sim.pushesTotal,
    "blockedMoves": sim.blockedMoves,
    "actionsDropped": sim.actionsDropped,
    "macrosUnreachable": sim.macrosUnreachable,
    "repliesRepaired": sim.repliesRepaired,
    "finalTick": sim.finalTick(),
    "turnsPlayed": sim.turnsPlayed,
    "policyKinds": policyKinds,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "deadSeats": deadSeats,
    "stopDetail": sim.stopDetail.truncateRunes(MaxStopDetailRunes)
  }

const ResultsKeys* = [
  "names", "aliases", "scores", "win", "winner", "reason", "endRule",
  "variant", "seed", "levelCount", "stepBudget", "parWeight", "maxWeight",
  "solvedWeight", "levelsSolved", "boxCredit", "movesSavedTotal", "levelTier",
  "levelOptPushes", "levelOutcome", "levelBoxesPlaced", "levelMoves",
  "levelTurns", "levelPushes", "levelTierRelaxed", "deadlocks", "outOfSteps",
  "pushesTotal", "blockedMoves", "actionsDropped", "macrosUnreachable",
  "repliesRepaired", "finalTick", "turnsPlayed", "policyKinds", "llmTurns",
  "fallbackTurns", "deadSeats", "stopDetail"]

# ---------------------------------------------------------------------------
#  The observation
# ---------------------------------------------------------------------------

proc observationJson*(sim: SimServer, seat: int): JsonNode =
  ## Everything this seat may legitimately know. Sokoban is PERFECT
  ## INFORMATION and this game keeps it that way: the cog sees the entire
  ## board. Hidden: the episode SEED, any level not yet started, the level's
  ## solution, the agent's own score, and its own real policy name.
  var board = newJArray()
  for row in sim.state.renderXsb():
    board.add(%row)
  var boxes = newJArray()
  for i, box in sim.state.boxes:
    boxes.add(%*{"i": i, "x": cellX(box), "y": cellY(box),
                 "on_target": sim.state.board.target[box]})
  var targets = newJArray()
  for cell in 0 ..< GridCells:
    if sim.state.board.target[cell]:
      targets.add(%*{"x": cellX(cell), "y": cellY(cell),
                     "filled": sim.state.hasBox(cell)})
  var deadSquares = newJArray()
  for cell in sim.level.dead.deadSquareList():
    deadSquares.add(%[cellX(cell), cellY(cell)])
  var available = newJArray()
  for push in sim.state.legalPushes():
    # No deadlock annotation: the model must cross-reference `to` against
    # `dead_squares` itself and must reason about freezes on its own. That line
    # is where this game stops being bookkeeping and starts being Sokoban.
    available.add(%*{"box": push.box, "dir": $push.dir,
                     "to": [cellX(push.toCell), cellY(push.toCell)]})
  var history = newJArray()
  for i in 0 ..< sim.levelIndex:
    history.add(%*{"tier": $sim.levels[i].tier,
                   "outcome": $sim.levels[i].outcome})
  result = %*{
    "you": seatAlias(seat),
    "level": {
      "index": sim.levelIndex + 1,
      "of": sim.config.levelCount,
      "tier": $sim.level.tier,
      "opt_pushes": sim.level.optPushes,
      "moves_left": max(0, sim.config.stepBudget - sim.levelMove),
      "turns_left": max(0, sim.config.levelTurnCap - sim.levelTurn),
      "pushes_made": sim.levelPushes,
      "boxes_on_targets": sim.state.boxesOnTargets()
    },
    "turn": sim.turnsPlayed + 1,
    "tick": sim.tick,
    "world": {
      "size": GridSize,
      "legend": {"#": "wall", " ": "floor", ".": "target", "$": "box",
                 "*": "box on target", "@": "you", "+": "you on a target"},
      "dirs": ["U", "D", "L", "R"],
      "moves_per_turn": sim.config.turnMoves,
      "step_budget": sim.config.stepBudget
    },
    "board": board,
    "player": {"x": cellX(sim.state.player), "y": cellY(sim.state.player)},
    "boxes": boxes,
    "targets": targets,
    "dead_squares": deadSquares,
    "pushes_available": available,
    "levels_solved": sim.levelsSolved(),
    "solved_weight": sim.solvedWeight(),
    "history": history
  }
  if sim.lastReport.valid:
    result["last_turn"] = %*{
      "executed": sim.lastReport.executed,
      "pushes": sim.lastReport.pushes,
      "blocked": sim.lastReport.blocked,
      "truncated": sim.lastReport.truncated,
      "dropped": sim.lastReport.dropped,
      "unreachable": sim.lastReport.unreachable
    }
    result["notes"] = %sim.lastReport.notes
  else:
    result["last_turn"] = newJNull()
    result["notes"] = %""

proc boardRows*(sim: SimServer): seq[string] = sim.state.renderXsb()

proc searchParams*(sim: SimServer): SearchParams =
  result = DefaultSearchParams
  result.nodeCap = max(1, sim.config.baselineNodeCap)

proc scriptedDirective*(sim: SimServer, kind: Baseline): Directive =
  ## The scripted plan for the CURRENT state. `decide.nim`'s fallback path calls
  ## THIS proc with `blPusher`, which is what makes the fallback and the
  ## `pusher` filler the same code.
  scriptedPlan(kind, sim.state, sim.level.dead, sim.searchParams(),
               sim.config.turnMoves)

proc episodeOver*(sim: SimServer): bool =
  sim.ladderComplete() or sim.turnsPlayed >= sim.config.maxTurns

proc settle*(sim: SimServer, reason: EndReason, rule: EndRule, detail = "") =
  ## Ends the episode. Every level that never STARTED is marked `unreached`
  ## with zero moves, zero turns and zero crates placed; every level that DID
  ## run keeps its real result, including the one that was still in play when a
  ## deadline or a fault stopped the clock — a deadline episode is still
  ## rankable, so nothing earned is ever zeroed.
  ## The level that was IN PLAY is not an unstarted level: it keeps the moves,
  ## turns, pushes and crates it really earned, and it is recorded
  ## `outofsteps` — it was reached, it was neither solved nor deadlocked, and
  ## its budget ended under it. `unreached` stays reserved for a level that
  ## never started.
  if sim.levelActive:
    sim.finishLevel(loOutOfSteps)
  ## Levels start strictly in order, so `levelIndex` is the last level that
  ## started: everything past it is unstarted and only those are zeroed.
  for i in sim.levelIndex + 1 ..< sim.levels.len:
    sim.levels[i].outcome = loUnreached
    sim.levels[i].moves = 0
    sim.levels[i].turns = 0
    sim.levels[i].pushes = 0
    sim.levels[i].boxesPlaced = 0
  sim.reason = reason
  sim.endRule = rule
  sim.stopDetail = detail.truncateRunes(MaxStopDetailRunes)
  sim.phase = phGameOver
  var maxWeight = 0
  for tier in sim.config.tierLadder:
    maxWeight += TierWeights[tier]
  sim.emit(%*{
    "k": "end", "reason": $reason, "endRule": $rule,
    "solved": sim.levelsSolved(), "of": sim.config.levelCount,
    "weight": sim.solvedWeight(), "maxWeight": maxWeight,
    "score": sim.episodeScore()
  })

const EventKinds* = [
  "levelstart", "turn", "plan", "say", "fallback", "boxon", "boxoff",
  "deadlock", "solved", "failed", "budget", "end"]

const BeatKinds* = [
  "levelstart", "boxon", "deadlock", "solved", "failed", "fallback", "end"]
