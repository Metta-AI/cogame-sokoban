## The event vocabulary, the label manifest and the swept baseline tunables.

import std/[algorithm, json, os, strutils, unittest]
import sokoban/[sim, events, labels, broadcast]
import helpers

suite "events are the closed enum":
  test "the set stepEvents can emit equals exactly the twelve declared kinds":
    var declared: seq[string] = @[]
    for kind in EventKinds:
      declared.add(kind)
    declared.sort()
    check declared.len == 12

    var seen: seq[string] = @[]
    var cfg = defaultConfig()
    cfg.seed = 8080
    let levels = levelsFor(cfg.seed, cfg)
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    while not sim.episodeOver():
      if sim.needsLevel():
        sim.startLevel(levels[sim.levelIndex + 1])
      if not sim.levelActive:
        break
      let plan = sim.scriptedDirective(blPusher)
      sim.beginTurn(plan)
      while not sim.turnComplete():
        sim.stepTick()
      sim.endTurn("")
      for event in sim.drainEvents():
        let kind = event{"k"}.getStr()
        if kind notin seen:
          seen.add(kind)
        check kind in declared
    sim.settle(endComplete, erLadderComplete)
    for event in sim.drainEvents():
      if event{"k"}.getStr() notin seen:
        seen.add(event{"k"}.getStr())
    # A real episode exercises most of the vocabulary; every kind it emits must
    # be declared, and the declared set is closed.
    for required in ["levelstart", "turn", "plan", "boxon", "solved", "end"]:
      check required in seen

  test "nothing fires per tick: the feed can never flood":
    var cfg = defaultConfig()
    cfg.seed = 5150
    let levels = levelsFor(cfg.seed, cfg)
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    var perTurn = 0
    var turns = 0
    while not sim.episodeOver():
      if sim.needsLevel():
        sim.startLevel(levels[sim.levelIndex + 1])
      if not sim.levelActive:
        break
      let plan = sim.scriptedDirective(blPusher)
      sim.beginTurn(plan)
      while not sim.turnComplete():
        sim.stepTick()
      sim.endTurn("")
      inc turns
      var planEvents = 0
      for event in sim.drainEvents():
        if event{"k"}.getStr() == "plan":
          inc planEvents
      check planEvents == 1
      perTurn += planEvents
    check perTurn == turns
    check turns <= cfg.maxTurns

  test "the scrubber beat kinds are a subset of the emitted kinds":
    for beat in BeatKinds:
      check beat in EventKinds

suite "the tier-2 analysis stream":
  test "the JSON-lines log always ends with the mandatory summary row":
    let log = newEventLog(true)
    log.add(seLevelStart, 0, %*{"level": 1})
    log.add(seMove, 1, %*{"from": 0, "to": 1})
    let text = log.eventsJsonl(2)
    let lines = text.strip().splitLines()
    check lines.len == 3
    let summary = parseJson(lines[^1])
    check summary["type"].getStr() == "summary"
    check summary["ticks"].getInt() == 2
    check summary["events"].getInt() == 2
    check summary["gameVersion"].getStr() == GameVersion
    for line in lines:
      discard parseJson(line)

  test "the SimEventKind set is the reduced vocabulary the design names":
    var names = eventKindNames()
    names.sort()
    var expected = @["BoxOff", "BoxOn", "Deadlock", "Directive", "Failed",
                     "Fallback", "LevelStart", "Move", "Push", "Solved",
                     "TurnStart"]
    expected.sort()
    check names == expected

suite "the fallback cause set is closed":
  test "every cause decide.nim can write is one of the seven declared":
    # `fallback.cause` is a CLOSED set in the design note; a cause outside it
    # is a record a phase-60 reader cannot classify.
    const Declared = ["timeout", "parse_error", "transport_error",
                      "no_credentials", "rate_guard", "budget_guard",
                      "disconnected"]
    let source = readFile("src/sokoban/decide.nim")
    var found: seq[string] = @[]
    for marker in ["lastCause = \"", "fallbackPlan(\n      \""]:
      var index = 0
      while true:
        index = source.find(marker, index)
        if index < 0:
          break
        index += marker.len
        var cause = ""
        while index < source.len and source[index] != '"':
          cause.add(source[index])
          inc index
        if cause.len > 0 and cause notin found:
          found.add(cause)
    check found.len >= 4
    for cause in found:
      check cause in Declared

suite "label manifest":
  test "the drawn board vocabulary equals tests/label_manifest.txt":
    var declared: seq[string] = @[]
    for line in readFile("tests/label_manifest.txt").splitLines():
      if line.strip().len > 0 and not line.startsWith("#"):
        declared.add(line.strip())
    declared.sort()
    var emitted = boardLabelVocabulary()
    emitted.sort()
    check emitted == declared

  test "showPlayerLabels is false, so no identity is drawn on the board":
    let manifest = parseFile("coworld_manifest_template.json")
    for variant in manifest["variants"]:
      check not variant["game_config"]["showPlayerLabels"].getBool()
    check not manifest["certification"]["game_config"][
      "showPlayerLabels"].getBool()
    for label in boardLabelVocabulary():
      check label notin ["daveey", "daveey-1", "sokoban-lookahead",
                         "sokoban-orderfirst"]

suite "the two name spaces":
  test "the alias is what the model sees, the real name what the spectator sees":
    var cfg = defaultConfig()
    cfg.seed = 21
    let sim = newSimServer(cfg)
    sim.seats[0].name = "sokoban-lookahead"
    sim.seats[0].policyLabel = "lookahead"
    sim.phase = phPlaying
    sim.startLevel(levelsFor(cfg.seed, cfg)[0])
    check "sokoban-lookahead" notin $sim.observationJson(0)
    check sim.observationJson(0)["you"].getStr() == "Alpha"
    # Spectator side: the scorebug plate and results carry the real name.
    let frame = sim.buildStateJson(
      sim.drainEvents(), playing = true, speed = 1, maxTick = 100,
      looping = false, transportEnabled = true, mismatchTick = -1)
    check "sokoban-lookahead" in frame
    check "Alpha" in frame
    check sim.ladderResultsJson()["names"][0].getStr() == "sokoban-lookahead"
    check sim.ladderResultsJson()["aliases"][0].getStr() == "Alpha"

suite "baseline tuning is the swept pick":
  test "the shipped defaults equal tools/ci/baseline_tuning.json":
    let recorded = parseFile("tools/ci/baseline_tuning.json")
    check recorded["nodeCap"].getInt() == DefaultSearchParams.nodeCap
    check recorded["greedyMatch"].getBool() == DefaultSearchParams.greedyMatch
    check recorded["tieOnH"].getBool() == DefaultSearchParams.tieOnH
    # And the manifest ships the swept node cap, not a guessed one.
    let manifest = parseFile("coworld_manifest_template.json")
    for variant in manifest["variants"]:
      check variant["game_config"]["baselineNodeCap"].getInt() ==
        DefaultSearchParams.nodeCap
    check manifest["certification"]["game_config"][
      "baselineNodeCap"].getInt() == DefaultSearchParams.nodeCap

  test "the recorded sweep lands inside the design's strength band":
    let recorded = parseFile("tools/ci/baseline_tuning.json")
    let rates = recorded["pusherSolveRate"]
    check rates["unfiltered"].getFloat() >= 0.60
    check rates["unfiltered"].getFloat() <= 0.95
    check rates["medium"].getFloat() >= 0.15
    check rates["medium"].getFloat() <= 0.55
    check rates["hard"].getFloat() >= 0.00
    check rates["hard"].getFloat() <= 0.20
    let nudger = recorded["nudgerSolveRate"]
    for tier in ["unfiltered", "medium", "hard"]:
      check nudger[tier].getFloat() <= rates[tier].getFloat()
