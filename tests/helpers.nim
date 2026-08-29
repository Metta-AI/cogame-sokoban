## Shared test helpers: a headless episode driver and a few board fixtures.
##
## `runEpisode` is the same loop `src/sokoban/server.nim` runs, minus the
## sockets: the sim, the level provider, the per-turn plan and the tick loop.
## Every test that needs a whole episode goes through it, so a test can never
## exercise a different resolution order from the one the server ships.

import std/[json, strutils]
import sokoban/[sim, replays]

const SweepSeeds* = when defined(release): 8 else: 2
  ## Level generation is a bounded backward BFS: six levels measure ~2.8 s in a
  ## release build and ~6.8 s in a debug one, and `ci.yml` runs EVERY test file
  ## in BOTH modes. The design note's sweeps are written for thousands of
  ## seeds, which is hours of CI; the shipped sweeps keep every assertion and
  ## shrink the sample so the job finishes. DIVERGENCE, recorded here rather
  ## than hidden: the design note asks for 5 000-seed sweeps.

proc levelsFor*(seed: int64, cfg: GameConfig): seq[Level] =
  for i, tier in cfg.tierLadder:
    result.add(generateLevel(seed, i, tier, cfg.genNodeCap, cfg.genAttemptCap))

type EpisodeResult* = object
  sim*: SimServer
  replay*: string
  levels*: seq[Level]

proc runEpisode*(
  cfg: GameConfig, kind: Baseline, levels: seq[Level] = @[],
  record = false, stopAtTurn = -1, stopReason = endDeadline,
  stopRule = erWallClock
): EpisodeResult =
  var config = cfg
  let sim = newSimServer(config)
  sim.phase = phPlaying
  result.levels = if levels.len > 0: levels else: levelsFor(config.seed, config)
  var writer: ReplayWriter
  if record:
    writer = newReplayWriter(configJson(config))
    writer.writeChat(0, $(%*{
      "k": "register", "slot": 0, "alias": "Alpha", "name": $kind,
      "policy": $kind, "kind": "scripted", "baseline": $kind}))
  while not sim.episodeOver():
    if sim.needsLevel():
      let index = sim.levelIndex + 1
      sim.startLevel(result.levels[index])
      if record:
        writer.writeLevel(sim.tick, LevelPayload(
          index: index, tier: result.levels[index].tier,
          optPushes: result.levels[index].optPushes,
          tierRelaxed: result.levels[index].tierRelaxed,
          rows: sim.levels[index].rows, dead: sim.levels[index].deadList))
    if not sim.levelActive:
      break
    if stopAtTurn >= 0 and sim.turnsPlayed >= stopAtTurn:
      if record and stopReason != endComplete:
        ## PARITY WITH THE SERVER, which writes a stop record only when the
        ## reason is not `complete` (`server.nim:386-390`). Writing one for
        ## every forced stop made the `turnCap` round trip exercise a byte
        ## shape the shipped server never produces.
        writer.writeStop(StopRecord(
          tick: sim.tick, reason: stopReason, endRule: stopRule,
          detail: "forced stop"))
      sim.settle(stopReason, stopRule, "forced stop")
      if record:
        writer.writeChat(sim.tick, "{\"k\":\"result\",\"results\":" &
          $sim.ladderResultsJson() & "}")
        result.replay = writer.bytes()
      result.sim = sim
      return
    let plan = sim.scriptedDirective(kind)
    if record:
      writer.writePlan(sim.tick, PlanRecord(
        turn: sim.turnsPlayed + 1, level: sim.levelIndex,
        source: dsScripted, actions: plan.actions,
        say: plan.say, notes: plan.notes))
    sim.beginTurn(plan)
    while not sim.turnComplete():
      sim.stepTick()
      if record:
        writer.writeHash(sim.gameHashValue)
      if sim.turnEnded:
        break
    sim.endTurn(plan.notes)
    discard sim.drainEvents()
  ## The server's own end-rule derivation (`server.nim:377-378`): a `complete`
  ## episode that stopped without finishing the ladder stopped on the TURN CAP.
  sim.settle(endComplete,
             if sim.ladderComplete(): erLadderComplete else: erTurnCap)
  if record:
    writer.writeChat(sim.tick, "{\"k\":\"result\",\"results\":" &
      $sim.ladderResultsJson() & "}")
    result.replay = writer.bytes()
  result.sim = sim

const SampleStates* = when defined(release): 60 else: 12
  ## The same trade as `SweepSeeds`, for the tests that walk a set of positions
  ## rather than whole episodes.

proc boardOf*(rows: openArray[string]): LevelState = parseXsb(rows)

proc levelOf*(rows: openArray[string], tier = tierUnfiltered, opt = 1): Level =
  result.state = parseXsb(rows)
  result.tier = tier
  result.optPushes = opt
  result.dead = result.state.board.deadSquares()

const OpenRoom* = [
  "##########",
  "#        #",
  "#  $  .  #",
  "#        #",
  "#  @     #",
  "#   $ .  #",
  "#        #",
  "#  $. .$ #",
  "#        #",
  "##########"]

proc repoRoot*(): string =
  ## Tests run from the repo ROOT (`nim r --path:src tests/<t>.nim`), so a
  ## relative data path is already correct; this exists so a test that needs to
  ## say so can.
  "."

proc readableText*(node: JsonNode): string = $node

proc contains*(text: string, needles: openArray[string]): bool =
  for needle in needles:
    if needle notin text:
      return false
  true
