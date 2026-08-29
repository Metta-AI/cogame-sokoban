## End-to-end: an episode writes artifacts, the six results identities hold,
## the certification seed is interesting, no seat can stall, and the guards
## settle early.

import std/[json, os, osproc, strutils, unittest]
import sokoban/[sim, decide]
import helpers

const ManifestPath = "coworld_manifest_template.json"

suite "episode writes artifacts":
  test "a real one-seat episode settles complete and scores by the formula":
    var cfg = defaultConfig()
    cfg.seed = 4242
    let episode = runEpisode(cfg, blPusher, record = true)
    let sim = episode.sim
    check sim.reason == endComplete
    check episode.replay.len > 0
    let results = sim.ladderResultsJson()

    # Identity 1: sum(levelMoves) == finalTick
    var movesTotal = 0
    for value in results["levelMoves"]:
      movesTotal += value.getInt()
    check movesTotal == results["finalTick"].getInt()

    # Identity 2: sum(levelTurns) == turnsPlayed
    var turnsTotal = 0
    for value in results["levelTurns"]:
      turnsTotal += value.getInt()
    check turnsTotal == results["turnsPlayed"].getInt()

    # Identity 3: solved <=> four crates parked
    for i, outcome in results["levelOutcome"].getElems():
      let placed = results["levelBoxesPlaced"][i].getInt()
      check (outcome.getStr() == "solved") == (placed == BoxCount)

    # Identity 4: solvedWeight is the tier-weighted solve count
    var weight = 0
    for i, outcome in results["levelOutcome"].getElems():
      if outcome.getStr() != "solved":
        continue
      let tier = parseTier(results["levelTier"][i].getStr())
      check tier.ok
      weight += TierWeights[tier.tier]
    check weight == results["solvedWeight"].getInt()

    # Identity 5: boxCredit and movesSavedTotal
    var credit = 0
    for value in results["levelBoxesPlaced"]:
      credit += value.getInt()
    check credit == results["boxCredit"].getInt()
    var saved = 0
    for i, outcome in results["levelOutcome"].getElems():
      if outcome.getStr() == "solved":
        saved += cfg.stepBudget - results["levelMoves"][i].getInt()
    check saved == results["movesSavedTotal"].getInt()

    # Identity 6: the score, the win flag and the winner
    check results["scores"][0].getInt() ==
      1_000_000 * results["solvedWeight"].getInt() +
      10_000 * results["boxCredit"].getInt() +
      results["movesSavedTotal"].getInt()
    check results["win"][0].getBool() ==
      (results["solvedWeight"].getInt() >= cfg.parWeight)
    if results["win"][0].getBool():
      check results["winner"].getInt() == 0
    else:
      check results["winner"].kind == JNull

  test "the results key set equals the manifest's results_schema exactly":
    let sim = newSimServer(defaultConfig())
    let results = sim.ladderResultsJson()
    let manifest = parseFile(ManifestPath)
    let declared = manifest["game"]["results_schema"]["properties"]
    var produced: seq[string] = @[]
    for key, _ in results:
      produced.add(key)
    var expected: seq[string] = @[]
    for key, _ in declared:
      expected.add(key)
    for key in produced:
      check key in expected
    for key in expected:
      check key in produced
    for key in ResultsKeys:
      check key in produced

suite "the cert seed is interesting":
  test "seed 42 on `ladder` yields a long replay with a solve and a deadlock":
    let manifest = parseFile(ManifestPath)
    var cfg = defaultConfig()
    cfg.update(manifest["certification"]["game_config"])
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    let levels = levelsFor(cfg.seed, cfg)
    var deadlocks = 0
    var ticks = 0
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
        if event{"k"}.getStr() == "deadlock":
          inc deadlocks
      ticks = sim.tick
    sim.settle(endComplete, erLadderComplete)
    # The viewer soak watches ten seconds of uninterrupted playback at
    # 12 ticks/second, so the smoke replay must outlast it comfortably.
    check ticks >= 400
    check sim.levelsSolved() >= 1
    check deadlocks >= 1

suite "no seat can stall":
  test "a seat that never answers still finishes the episode inside the budget":
    # The tick loop ALWAYS has a primitive: the turn's queue, else `wait`. A
    # seat that sends nothing therefore burns its step budget and the ladder
    # runs to its natural end.
    var cfg = defaultConfig()
    cfg.seed = 99
    let levels = levelsFor(cfg.seed, cfg)
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    sim.seats[0].dead = true
    while not sim.episodeOver():
      if sim.needsLevel():
        sim.startLevel(levels[sim.levelIndex + 1])
      if not sim.levelActive:
        break
      sim.beginTurn(Directive())          # the silent seat
      while not sim.turnComplete():
        sim.stepTick()
      sim.endTurn("")
      discard sim.drainEvents()
    sim.settle(endComplete, erLadderComplete)
    check sim.reason == endComplete
    check sim.turnsPlayed <= cfg.maxTurns
    check sim.tick <= cfg.maxTicks
    let results = sim.ladderResultsJson()
    check results["deadSeats"][0].getBool()
    check results["levelsSolved"].getInt() == 0

  test "the player-failure payload is the platform's CLOSED two-key schema":
    let payload = %*{"failed_policy_index": 0, "message": "never registered"}
    var keys: seq[string] = @[]
    for key, _ in payload:
      keys.add(key)
    check keys.len == 2
    check "message" in keys
    check "failed_policy_index" in keys

  test "the settle and the artifact write sit INSIDE the fault guard":
    # The design note's `fault` rule is "caught; the episode is settled from
    # the last completed tick, artifacts are still written, exit 0".
    # `writeArtifact` raises IOError on a non-2xx POST, so a stop record, a
    # settle or an upload outside the guard takes the game thread down with no
    # results and no replay.
    let source = readFile("src/sokoban/server.nim")
    let guard = source.find("THE SETTLE AND THE ARTIFACT WRITE ARE INSIDE")
    check guard > 0
    let tail = source[guard .. ^1]
    let settleAt = tail.find("gameSim.settle(reason, rule, detail)")
    let finishAt = tail.find("finishEpisode(writer, log)")
    let tryAt = tail.find("    try:")
    let exceptAt = tail.find("    except CatchableError")
    check tryAt >= 0
    check settleAt > tryAt
    check finishAt > tryAt
    check exceptAt > finishAt
    # And the two artifact writes are independent, so a failed replay upload
    # does not also cost `results.json`.
    check "sokoban: replay write FAILED" in source
    check "sokoban: results write FAILED" in source

  test "the real player name comes off the socket, not the policy label":
    # `results.names` is the SPECTATOR name space. The shipped player's
    # registration blob carries no `name` key at all, so the server reads the
    # one the platform puts on the player socket URL — the starter's own
    # `/player?slot&token&name=` route — and only falls back to the policy
    # label when nothing named the seat.
    let source = readFile("src/sokoban/server.nim")
    check "queryParams.getOrDefault(\"name\", \"\")" in source
    check "shared.names[slot] = declaredName" in source
    check "shared.names[slot] = registeredName" in source
    # And the alias never leaks into that space.
    let cfg = defaultConfig()
    let sim = newSimServer(cfg)
    sim.seats[0].name = "daveey"
    sim.seats[0].policyLabel = "lookahead"
    check sim.ladderResultsJson()["names"][0].getStr() == "daveey"
    check sim.ladderResultsJson()["aliases"][0].getStr() == "Alpha"

  test "the server refuses to start silently when a joined seat never registers":
    let source = readFile("src/sokoban/server.nim")
    check "connected but never sent a " in source
    check "refusing to treat it as a policy" in source

suite "budget guard and rate guard settle early":
  test "a forced budget guard still ends the episode complete":
    var cfg = defaultConfig()
    cfg.seed = 11
    let sim = newSimServer(cfg)
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    sim.phase = phPlaying
    sim.startLevel(levelsFor(cfg.seed, cfg)[0])
    # elapsed is already past the point where two more turns would fit.
    let outcome = engine.turn(sim, 1, cfg.wallClockBudgetSeconds - 5)
    check engine.llmOff
    var sawGuard = false
    for record in outcome.records:
      if parseJson(record){"k"}.getStr() == "budget_guard":
        sawGuard = true
        check parseJson(record){"turn"}.getInt() == 1
    check sawGuard
    check outcome.directive.source == dsFallback

  test "with no credentials every turn falls back instantly and is recorded":
    var cfg = defaultConfig()
    cfg.seed = 12
    let sim = newSimServer(cfg)
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    sim.phase = phPlaying
    sim.startLevel(levelsFor(cfg.seed, cfg)[0])
    let outcome = engine.turn(sim, 1, 0)
    check outcome.directive.source == dsFallback
    var causes: seq[string] = @[]
    for record in outcome.records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "fallback":
        causes.add(node{"cause"}.getStr())
    check "no_credentials" in causes
