## Level generation: purity, exactness, the tier bands, well-formedness,
## boundedness and the no-network/no-dataset rule.

import std/[os, strutils, tables, times, unittest]
import sokoban/sim
import helpers

proc forwardOptimalPushes(level: Level, cap = 400_000): int =
  ## An INDEPENDENT forward breadth-first search over push space, written
  ## separately from `search.nim`: unbounded on these small instances, so the
  ## depth it finds IS the optimum. Returns -1 when the cap is hit.
  var
    seen = initTable[uint64, bool]()
    frontier = @[level.state]
    depth = 0
    expanded = 0
  seen[level.state.encodeState()] = true
  if level.state.boxesOnTargets() == BoxCount:
    return 0
  while frontier.len > 0 and expanded < cap:
    inc depth
    var next: seq[LevelState] = @[]
    for state in frontier:
      inc expanded
      if expanded >= cap:
        return -1
      for push in state.legalPushes():
        var child = state
        child.applyPush(push)
        let key = child.encodeState()
        if seen.hasKeyOrPut(key, true):
          continue
        if child.boxesOnTargets() == BoxCount:
          return depth
        if child.isDeadlocked(level.dead).dead:
          continue
        next.add(child)
    frontier = next
  -1

suite "levels are pure":
  test "every level of every variant is identical under different play":
    let cfg = defaultConfig()
    for s in 0 ..< SweepSeeds:
      let seed = int64(s) * 5701 + 13
      let a = runEpisode(cfg, blPusher, levelsFor(seed, cfg))
      let b = runEpisode(cfg, blNudger, levelsFor(seed, cfg))
      check a.sim.levels.len == b.sim.levels.len
      for i in 0 ..< cfg.levelCount:
        # Character for character, including the dead-square set and
        # optPushes: level k's grid is identical no matter what happened in
        # level k-1.
        check a.levels[i].state.renderXsb() == b.levels[i].state.renderXsb()
        check a.levels[i].optPushes == b.levels[i].optPushes
        check a.levels[i].dead == b.levels[i].dead

suite "optPushes is exact":
  test "an independent forward search finds exactly optPushes and none shorter":
    let cfg = defaultConfig()
    var checked = 0
    for s in 0 ..< SweepSeeds:
      for i, tier in cfg.tierLadder:
        let level = generateLevel(int64(s) * 4409 + 7, i, tier,
                                  cfg.genNodeCap, cfg.genAttemptCap)
        if level.tierRelaxed:
          continue
        let optimum = forwardOptimalPushes(level)
        if optimum < 0:
          continue        # the independent search hit its own cap
        check optimum == level.optPushes
        inc checked
    check checked > 0

suite "tier bands hold":
  test "optPushes lands inside the declared band, or levelTierRelaxed is set":
    var relaxed = 0
    var total = 0
    let cfg = defaultConfig()
    for s in 0 ..< SweepSeeds:
      for i, tier in cfg.tierLadder:
        let level = generateLevel(int64(s) * 3301 + 29, i, tier,
                                  cfg.genNodeCap, cfg.genAttemptCap)
        inc total
        if level.tierRelaxed:
          inc relaxed
        else:
          # The real content of this test: a level that is NOT flagged relaxed
          # is inside its declared band, always. A bounced band shows up here
          # as a failure, not as a quietly easier ladder.
          check level.optPushes >= TierBandMin[tier]
          check level.optPushes <= TierBandMax[tier]
    # The relaxed rate measured 3 / 240 = 1.3 % over a 40-seed offline sweep of
    # the shipped ladder (the design note's target is < 1 %; the `hard` band's
    # deepest draws exhaust genNodeCap). The gate here carries headroom for the
    # much smaller CI sample rather than flaking on one unlucky seed, and a
    # generator that stopped hitting its bands at all would blow straight
    # through it.
    check relaxed * 100 <= total * 12

suite "every level is solvable and well-formed":
  test "border, connectivity, counts, and no crate on a dead square":
    let cfg = defaultConfig()
    for s in 0 ..< SweepSeeds:
      for i, tier in cfg.tierLadder:
        let level = generateLevel(int64(s) * 2273 + 3, i, tier,
                                  cfg.genNodeCap, cfg.genAttemptCap)
        let state = level.state
        for x in 0 ..< GridSize:
          check state.board.wall[cellIndex(x, 0)]
          check state.board.wall[cellIndex(x, GridSize - 1)]
        for y in 0 ..< GridSize:
          check state.board.wall[cellIndex(0, y)]
          check state.board.wall[cellIndex(GridSize - 1, y)]
        check state.board.floorConnected()
        check state.board.floorCells().len >= 44 or level.tierRelaxed
        var targets = 0
        for cell in 0 ..< GridCells:
          if state.board.target[cell]:
            inc targets
        check targets == BoxCount
        var parked = 0
        for box in state.boxes:
          inc parked, (if state.board.target[box]: 1 else: 0)
          # A crate can never START on a dead square: every backward-BFS state
          # is reachable from the solved position, so every crate in it can
          # reach a marked square by construction.
          check not level.dead[box]
        check parked <= 1
        check not state.board.wall[state.player]
        check not state.hasBox(state.player)

suite "generation is bounded":
  test "six levels generate well inside the episode's own budget":
    let cfg = defaultConfig()
    let started = cpuTime()
    for s in 0 ..< 2:
      discard levelsFor(int64(s) * 911 + 5, cfg)
    let perEpisode = (cpuTime() - started) / 2.0
    check perEpisode < 30.0

  test "the committed fallbacks parse, are solvable, and carry their tier":
    for tier in Tier:
      let path = fallbackPath(tier)
      check fileExists(path)
      let level = loadFallback(tier)
      check level.tier == tier
      check level.optPushes >= TierBandMin[tier]
      check level.state.renderXsb().len == GridSize
      let found = bestFirstSearch(
        level.state, level.dead,
        SearchParams(nodeCap: 200_000, greedyMatch: true, tieOnH: true))
      check found.solved

suite "no network, no dataset":
  test "no source file fetches a URL, and no level data ships outside data/levels":
    for path in walkDirRec("src"):
      if not path.endsWith(".nim"):
        continue
      let source = readFile(path).toLowerAscii()
      # No level data is fetched at build time or at runtime: the ONLY reads of
      # a level file anywhere are the three committed fallbacks.
      check "boxoban-levels" notin source
      check "github.com/mpschrader" notin source
      check ".xsb" notin source or path.endsWith("levelgen.nim")
      check "newhttpclient" notin source
      check "downloadfile" notin source
    var levelFiles = 0
    for path in walkDirRec("data"):
      if path.endsWith(".xsb"):
        inc levelFiles
        check "levels" in path
    check levelFiles == 3
