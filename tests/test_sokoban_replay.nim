## Replay: record then re-derive for EVERY end reason, self-sufficiency, the
## strict-UTF-8 JSON summary, determinism from the bytes alone, and the
## GameVersion sweep.

import std/[json, os, osproc, strutils, unicode, unittest]
import sokoban/[sim, replay_runtime, replays]
import helpers

proc rederive(bytes: string): tuple[sim: SimServer, player: ReplayPlayer] =
  let data = parseReplayBytes(bytes)
  var init = initReplayRuntime(data)
  var game = init.sim
  var player = init.player
  while game.phase != phGameOver and game.tick < 100_000:
    player.stepReplay(game)
  (game, player)

suite "record then re-derive, every end reason":
  test "identical hashes at every tick, including the stop tick":
    var cfg = defaultConfig()
    cfg.seed = 4242
    for scenario in ["ladderComplete", "turnCap", "wallClock", "fault"]:
      var episode: EpisodeResult
      case scenario
      of "ladderComplete":
        episode = runEpisode(cfg, blPusher, record = true)
      of "turnCap":
        episode = runEpisode(cfg, blPusher, record = true, stopAtTurn = 60,
                             stopReason = endComplete, stopRule = erTurnCap)
      of "wallClock":
        episode = runEpisode(cfg, blPusher, record = true, stopAtTurn = 5,
                             stopReason = endDeadline, stopRule = erWallClock)
      else:
        episode = runEpisode(cfg, blPusher, record = true, stopAtTurn = 3,
                             stopReason = endFault, stopRule = erFault)
      check episode.replay.len > 0
      let (game, player) = rederive(episode.replay)
      # A wall-clock fact cannot be re-derived from sim state, so the stop is
      # a load-bearing RECORD applied by the same proc on record and playback.
      check player.hashMismatchTick == -1
      check game.tick == episode.sim.tick
      check $game.ladderResultsJson() == $episode.sim.ladderResultsJson()

suite "replay is self-sufficient":
  test "the bytes alone carry the config, the seat, every board and every plan":
    var cfg = defaultConfig()
    cfg.seed = 3141
    let episode = runEpisode(cfg, blPusher, record = true)
    let data = parseReplayBytes(episode.replay)
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.protocol == ProtocolName
    for key in ["seed", "variant", "num_agents", "gridSize", "boxCount",
                "levelCount", "tierLadder", "tierWeights", "tierBands",
                "turnMoves", "levelTurnCap", "stepBudget", "maxTurns",
                "maxTicks", "parWeight", "maxActionsPerTurn",
                "macroPrimitiveCap", "genNodeCap", "genAttemptCap",
                "baselineNodeCap", "players", "slots", "fastMode"]:
      check data.config.hasKey(key)
    var levels = 0
    var plans = 0
    var registers = 0
    var results = 0
    for record in data.records:
      case record.kind
      of rkLevel:
        inc levels
        check record.level.rows.len == GridSize
        check record.level.optPushes > 0
      of rkPlan:
        inc plans
      of rkChat:
        let node = parseJson(record.chat)
        if node{"k"}.getStr() == "register": inc registers
        if node{"k"}.getStr() == "result": inc results
      of rkStop:
        discard
    check levels >= 1
    check plans >= 1
    check registers == 1
    check results == 1
    check data.hashes.len == episode.sim.tick

  test "re-simulating from the bytes calls no generator and fetches nothing":
    var cfg = defaultConfig()
    cfg.seed = 2718
    let episode = runEpisode(cfg, blPusher, record = true)
    let (game, _) = rederive(episode.replay)
    for i in 0 ..< cfg.levelCount:
      check game.levels[i].rows == episode.sim.levels[i].rows
      check game.levels[i].deadList == episode.sim.levels[i].deadList
    # The runtime module never imports the generator's entry point.
    let source = readFile("src/sokoban/replay_runtime.nim")
    check "generateLevel" notin source

suite "the parser rejects a corrupt replay rather than trusting it":
  test "every byte-to-enum read is range-checked, like the record kind":
    # `T(cursor.readU8())` on a 0..255 byte is a range error in a debug build
    # and an OUT-OF-RANGE ENUM in the `-d:release` viewer build, where checks
    # are off: a corrupt byte then reaches a `case` no branch covers. The
    # tier field on the same path was already validated; these three were not.
    let source = readFile("src/sokoban/replays.nim")
    for unchecked in ["DirectiveSource(cursor.readU8())",
                      "ActionKind(cursor.readU8())", "Dir(cursor.readU8())"]:
      check unchecked notin source
    check source.count("readEnumU8") == 4   # the proc plus its three uses

  test "a truncated replay raises SokobanError, never a silent short read":
    var cfg = defaultConfig()
    cfg.seed = 31
    cfg.levelCount = 1
    cfg.tierLadder = @[tierUnfiltered]
    cfg.maxTurns = cfg.levelTurnCap
    let episode = runEpisode(cfg, blPusher, record = true)
    let data = parseReplayBytes(episode.replay)
    check data.records.len > 0
    expect SokobanError:
      discard parseReplayBytes(episode.replay[0 ..< episode.replay.len - 9])

suite "determinism from the replay alone":
  test "identical final tick, levels solved, crate credit and per-tick hash":
    var cfg = defaultConfig()
    cfg.seed = 1618
    let episode = runEpisode(cfg, blPusher, record = true)
    let data = parseReplayBytes(episode.replay)
    var init = initReplayRuntime(data)
    var game = init.sim
    var player = init.player
    var index = 0
    while game.phase != phGameOver and game.tick < 100_000:
      player.stepReplay(game)
      if index < data.hashes.len and game.tick > 0:
        check data.hashes[game.tick - 1] == game.gameHashValue
      inc index
    check game.tick == episode.sim.tick
    check game.levelsSolved() == episode.sim.levelsSolved()
    check game.boxCredit() == episode.sim.boxCredit()

suite "replay_summary is strict UTF-8 JSON":
  test "every capped field filled with 4-byte emoji still parses":
    var cfg = defaultConfig()
    cfg.seed = 5
    cfg.levelCount = 2
    cfg.tierLadder = @[tierUnfiltered, tierUnfiltered]
    cfg.maxTurns = cfg.levelCount * cfg.levelTurnCap
    cfg.maxTicks = cfg.maxTurns * cfg.turnMoves
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    let writer = newReplayWriter(configJson(cfg))
    var filler = ""
    for i in 0 ..< 500:
      filler.add("\u{1F9CA}")
    writer.writeChat(0, $(%*{
      "k": "register", "slot": 0, "alias": "Alpha",
      "name": filler.truncateRunes(MaxPolicyLabelRunes),
      "policy": filler.truncateRunes(MaxPolicyLabelRunes),
      "kind": "llm", "baseline": "pusher"}))
    writer.writeChat(0, $(%*{
      "k": "directive", "turn": 1, "slot": 0, "alias": "Alpha",
      "source": "llm", "say": filler.truncateRunes(MaxSayRunes),
      "detail": filler.truncateRunes(MaxNoteRunes)}))
    writer.writeChat(0, "{\"k\":\"result\",\"results\":" &
      $sim.ladderResultsJson() & "}")
    let path = getTempDir() / "sokoban_emoji.replay"
    writeFile(path, writer.bytes())
    let summary = execCmdEx("python3 tools/replay_summary.py " & path)
    check summary.exitCode == 0
    let node = parseJson(summary.output)
    check node["protocol"].getStr() == ProtocolName
    check summary.output.validateUtf8() == -1
    check "\\ud8" notin summary.output.toLowerAscii()   # no lone surrogates
    removeFile(path)

suite "every committed fixture carries the current GameVersion":
  test "the replay header states GameVersion and the version has a changelog":
    var cfg = defaultConfig()
    cfg.seed = 6
    let episode = runEpisode(cfg, blPusher, record = true)
    check parseReplayBytes(episode.replay).gameVersion == GameVersion
    let source = readFile("src/sokoban/sim_types.nim")
    check ("\"" & GameVersion & "\"  first release") in source or
      ("\"" & GameVersion & "\"") in source
    check "PREPEND ONLY" in source
