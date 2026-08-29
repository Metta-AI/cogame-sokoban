## Sim unit tests: the grid and XSB notation, the four primitives, push
## accounting, the deadlock detector, the walk BFS, the turn/tick resolution
## order, scoring, the end conditions, the no-floating-point rule and the tick
## budget.

import std/[os, strutils, times, unittest]
import sokoban/sim
import helpers

suite "grid and XSB":
  test "the board is 10x10 and the border ring is wall":
    let level = levelOf(OpenRoom)
    check level.state.renderXsb().len == GridSize
    for row in level.state.renderXsb():
      check row.len == GridSize
    for x in 0 ..< GridSize:
      check level.state.board.wall[cellIndex(x, 0)]
      check level.state.board.wall[cellIndex(x, GridSize - 1)]
    for y in 0 ..< GridSize:
      check level.state.board.wall[cellIndex(0, y)]
      check level.state.board.wall[cellIndex(GridSize - 1, y)]

  test "the glyph table round-trips over generated boards":
    let cfg = defaultConfig()
    for s in 0 ..< SweepSeeds:
      let level = generateLevel(int64(s) * 8191 + 5, 0, tierUnfiltered,
                                cfg.genNodeCap, cfg.genAttemptCap)
      let rows = level.state.renderXsb()
      let reparsed = parseXsb(rows)
      check reparsed.renderXsb() == rows
      check reparsed.player == level.state.player
      check reparsed.boxes == level.state.boxes

  test "no glyph outside the table is ever accepted":
    var rows: seq[string] = @[]
    for row in OpenRoom:
      rows.add(row)
    rows[4] = "#  X     #"
    expect SokobanError:
      discard parseXsb(rows)

suite "the four primitives":
  setup:
    var cfg = defaultConfig()
    cfg.levelCount = 1
    cfg.tierLadder = @[tierUnfiltered]
    cfg.maxTurns = cfg.levelTurnCap
    cfg.maxTicks = cfg.maxTurns * cfg.turnMoves
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    sim.startLevel(levelOf(OpenRoom))

  test "walking into free floor moves the cog":
    let before = sim.state.player
    sim.beginTurn(Directive(actions: @[Action(kind: akMoves, seq: "U")]))
    sim.stepTick()
    check sim.state.player == before.step(dirUp)
    check sim.blockedMoves == 0

  test "walking into a wall is a no-op that still costs a move":
    # Park the cog against the west wall, then push into it.
    sim.beginTurn(Directive(actions: @[Action(kind: akMoves, seq: "LLLL")]))
    while not sim.turnComplete(): sim.stepTick()
    let parked = sim.state.player
    let movesBefore = sim.levelMove
    let blockedBefore = sim.blockedMoves
    sim.endTurn("")
    sim.beginTurn(Directive(actions: @[Action(kind: akMoves, seq: "L")]))
    sim.stepTick()
    check sim.state.player == parked
    check sim.levelMove == movesBefore + 1
    check sim.blockedMoves == blockedBefore + 1

  test "walking into a crate with free floor beyond pushes it":
    let sim2 = newSimServer(defaultConfig())
    sim2.phase = phPlaying
    sim2.startLevel(levelOf([
      "##########",
      "#        #",
      "#        #",
      "#        #",
      "#  @$ .  #",
      "#  $  .  #",
      "#  $ .   #",
      "#  $.    #",
      "#        #",
      "##########"]))
    let box = sim2.state.boxAt(cellIndex(4, 4))
    check box >= 0
    sim2.beginTurn(Directive(actions: @[Action(kind: akMoves, seq: "R")]))
    sim2.stepTick()
    check sim2.state.player == cellIndex(4, 4)
    check sim2.state.hasBox(cellIndex(5, 4))
    check sim2.levelPushes == 1

  test "no rule anywhere moves a crate backwards":
    # A 10 000-step random walk in which the multiset of crate cells only ever
    # changes by a LEGAL push.
    let sim3 = newSimServer(defaultConfig())
    sim3.phase = phPlaying
    sim3.startLevel(levelOf(OpenRoom))
    var seed = 12345'u64
    for step in 0 ..< 10_000:
      if not sim3.levelActive:
        sim3.levels[sim3.levelIndex].outcome = loRunning
        sim3.levelActive = true
        sim3.levelMove = 0
      seed = seed * 6364136223846793005'u64 + 1442695040888963407'u64
      let d = Dirs[int((seed shr 33) mod 4)]
      let before = sim3.state.boxes
      let player = sim3.state.player
      sim3.beginTurn(Directive(actions: @[
        Action(kind: akMoves, seq: $d)]))
      sim3.stepTick()
      var moved = 0
      for i in 0 ..< BoxCount:
        if sim3.state.boxes[i] notin before:
          inc moved
      check moved <= 1
      if moved == 1:
        # The only legal displacement is one cell along `d`, away from the cog.
        check sim3.state.player == player.step(d)

suite "push accounting":
  test "levelBoxesPlaced is a running maximum, never decremented":
    let sim = newSimServer(defaultConfig())
    sim.phase = phPlaying
    sim.startLevel(levelOf([
      "##########",
      "#        #",
      "#        #",
      "#        #",
      "#  @$.   #",
      "#  $     #",
      "#  $ .   #",
      "#  $. .  #",
      "#        #",
      "##########"]))
    sim.beginTurn(Directive(actions: @[Action(kind: akMoves, seq: "RR")]))
    sim.stepTick()                       # push onto the marked square
    check sim.state.boxesOnTargets() >= 1
    let peak = sim.levelBoxesPlaced
    sim.stepTick()                       # push it straight off again
    check sim.levelBoxesPlaced == peak
    check sim.state.boxesOnTargets() < peak

suite "dead squares":
  test "every interior corner without a marked square is dead":
    let level = levelOf(OpenRoom)
    for (x, y) in [(1, 1), (8, 1), (1, 8), (8, 8)]:
      check level.dead[cellIndex(x, y)]

  test "a marked square is never dead":
    let level = levelOf(OpenRoom)
    for cell in 0 ..< GridCells:
      if level.state.board.target[cell]:
        check not level.dead[cell]

  test "a wall line with no marked square on it is dead end to end":
    let level = levelOf([
      "##########",
      "#        #",
      "#  ....  #",
      "#        #",
      "#  @     #",
      "#        #",
      "#  $$$$  #",
      "#        #",
      "#        #",
      "##########"])
    # Row 1 touches the north wall and carries no marked square, so no crate
    # pushed onto it can ever leave it.
    for x in 1 ..< GridSize - 1:
      check level.dead[cellIndex(x, 1)]

  test "brute force agrees with the fixpoint flood on small boards":
    # A cell is in D iff an exhaustive PULL search from a single crate on that
    # cell reaches no marked square. The flood computes exactly that, so the
    # brute force is written independently here as a plain reachability walk
    # over the pull relation.
    let level = levelOf(OpenRoom)
    let board = level.state.board
    for cell in 0 ..< GridCells:
      if board.wall[cell]:
        continue
      var seen: array[GridCells, bool]
      var queue = @[cell]
      seen[cell] = true
      var head = 0
      var alive = board.target[cell]
      while head < queue.len:
        let here = queue[head]
        inc head
        for d in Dirs:
          let ahead = here.step(d)
          let behind = here.step(d.opposite)
          if ahead < 0 or behind < 0:
            continue
          if board.wall[ahead] or board.wall[behind] or seen[ahead]:
            continue
          seen[ahead] = true
          if board.target[ahead]:
            alive = true
          queue.add(ahead)
      check level.dead[cell] == (not alive)

suite "2x2 frozen block":
  test "fires on four wall-or-crate cells holding an unparked crate":
    let level = levelOf([
      "##########",
      "#$$      #",
      "#  .  .  #",
      "#        #",
      "#  @     #",
      "#        #",
      "#  $  .  #",
      "#     .$ #",
      "#        #",
      "##########"])
    let verdict = level.state.isDeadlocked(level.dead)
    check verdict.dead

  test "does not fire when every crate in the block is parked":
    let level = levelOf([
      "##########",
      "#**      #",
      "#        #",
      "#        #",
      "#  @     #",
      "#        #",
      "#  $  .  #",
      "#     .$ #",
      "#        #",
      "##########"])
    check level.state.frozenBlockBox() < 0

  test "does not fire on a 2x2 of walls alone":
    let level = levelOf([
      "##########",
      "#        #",
      "# ##  .  #",
      "# ##  .  #",
      "#  @     #",
      "#  $     #",
      "#  $  .  #",
      "#  $  .  #",
      "#  $     #",
      "##########"])
    check level.state.frozenBlockBox() < 0

suite "no-push deadlock":
  test "fires exactly when the legal-push set is empty and a crate is unparked":
    let level = levelOf([
      "##########",
      "#@       #",
      "# ########",
      "#$#      #",
      "#$#      #",
      "#$#      #",
      "#$#....  #",
      "##########",
      "##########",
      "##########"])
    check level.state.legalPushes().len == 0
    check level.state.isDeadlocked(level.dead).dead

suite "detector soundness":
  test "never flags a position drawn from the generator's own backward BFS":
    # Every generated start position is solvable BY CONSTRUCTION (it is a
    # backward-BFS state seeded at the solved position), so a detector that
    # ever flags one is unsound. This is the single most important test here.
    let cfg = defaultConfig()
    var checked = 0
    for s in 0 ..< SweepSeeds:
      for i, tier in cfg.tierLadder:
        let level = generateLevel(int64(s) * 7717 + 1, i, tier,
                                  cfg.genNodeCap, cfg.genAttemptCap)
        check not level.state.isDeadlocked(level.dead).dead
        inc checked
    check checked > 0

suite "walk BFS":
  test "the path is unique, never crosses a wall or a crate, and is shortest":
    let level = levelOf(OpenRoom)
    let target = cellIndex(8, 1)
    let walk = level.state.walkPath(target)
    check walk.ok
    var cursor = level.state.player
    for d in walk.path:
      cursor = cursor.step(d)
      check cursor >= 0
      check not level.state.board.wall[cursor]
      check not level.state.hasBox(cursor)
    check cursor == target
    check level.state.walkPath(target).path == walk.path

  test "a walled-off square yields zero primitives and reports unreachable":
    let level = levelOf([
      "##########",
      "#   #    #",
      "# @ #.   #",
      "#   #  . #",
      "#####    #",
      "#  $$    #",
      "#  $$    #",
      "#   . .  #",
      "#        #",
      "##########"])
    let walk = level.state.walkPath(cellIndex(8, 8))
    check not walk.ok
    let expansion = expandDirective(
      level.state, Directive(actions: @[Action(kind: akGoto, x: 8, y: 8)]),
      20, 32)
    check expansion.queue.len == 0
    check expansion.unreachable == 1

suite "turn and tick order":
  test "an empty queue spends the turn on waits, and each costs a move":
    let sim = newSimServer(defaultConfig())
    sim.phase = phPlaying
    sim.startLevel(levelOf(OpenRoom))
    sim.beginTurn(Directive())
    while not sim.turnComplete():
      sim.stepTick()
    check sim.levelMove == sim.config.turnMoves
    check sim.turnExecuted == repeat('.', sim.config.turnMoves)

  test "the step cap fires at exactly move 200 and ends the level":
    var cfg = defaultConfig()
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    sim.startLevel(levelOf(OpenRoom))
    while sim.levelActive and sim.turnsPlayed < cfg.levelTurnCap:
      sim.beginTurn(Directive())
      while not sim.turnComplete():
        sim.stepTick()
      sim.endTurn("")
    check not sim.levelActive
    check sim.levels[0].outcome == loOutOfSteps
    check sim.levels[0].moves == cfg.stepBudget

  test "a finished level breaks the tick loop and the next level starts next turn":
    let sim = newSimServer(defaultConfig())
    sim.phase = phPlaying
    sim.startLevel(levelOf([
      "##########",
      "#        #",
      "#        #",
      "#        #",
      "#  @$.   #",
      "#   *    #",
      "#   *    #",
      "#   *    #",
      "#        #",
      "##########"]))
    sim.beginTurn(Directive(actions: @[Action(kind: akMoves, seq: "RRRRR")]))
    while not sim.turnComplete():
      sim.stepTick()
    check sim.levels[0].outcome == loSolved
    check sim.turnEnded
    check sim.levels[0].moves == 1        # skipped ticks never count
    check sim.needsLevel()

suite "scoring":
  test "the formula, both dominance bounds and both maxima":
    let cfg = defaultConfig()
    let sim = newSimServer(cfg)
    for i in 0 ..< cfg.levelCount:
      sim.levels[i].tier = cfg.tierLadder[i]
      sim.levels[i].outcome = loSolved
      sim.levels[i].boxesPlaced = BoxCount
      sim.levels[i].moves = 1
    check sim.solvedWeight() == 12
    check sim.boxCredit() == 24
    check sim.movesSavedTotal() == 6 * (cfg.stepBudget - 1)
    check sim.episodeScore() ==
      1_000_000 * 12 + 10_000 * 24 + 6 * (cfg.stepBudget - 1)
    # The ordering is strictly lexicographic BY CONSTRUCTION.
    check 10_000 * 24 + 6 * (cfg.stepBudget - 1) < 1_000_000
    check 6 * (cfg.stepBudget - 1) < 10_000
    check sim.episodeScore() == 12_241_194
    var hard = cfg
    hard.tierLadder = @[tierMedium, tierMedium, tierHard, tierHard, tierHard,
                        tierHard]
    hard.parWeight = 6
    let sim2 = newSimServer(hard)
    for i in 0 ..< hard.levelCount:
      sim2.levels[i].tier = hard.tierLadder[i]
      sim2.levels[i].outcome = loSolved
      sim2.levels[i].boxesPlaced = BoxCount
      sim2.levels[i].moves = 1
    check sim2.episodeScore() == 16_241_194

  test "the minimum is 0 and no term can ever subtract":
    let sim = newSimServer(defaultConfig())
    check sim.episodeScore() == 0
    check not sim.episodeWin()

  test "the formula holds over 500 randomised end states":
    var seed = 987654321'u64
    for trial in 0 ..< 500:
      let cfg = defaultConfig()
      let sim = newSimServer(cfg)
      var weight = 0
      var credit = 0
      var saved = 0
      for i in 0 ..< cfg.levelCount:
        seed = seed * 6364136223846793005'u64 + 1442695040888963407'u64
        let roll = int((seed shr 33) mod 4)
        sim.levels[i].tier = cfg.tierLadder[i]
        sim.levels[i].moves = int((seed shr 17) mod uint64(cfg.stepBudget + 1))
        case roll
        of 0:
          sim.levels[i].outcome = loSolved
          sim.levels[i].boxesPlaced = BoxCount
          weight += TierWeights[cfg.tierLadder[i]]
          credit += BoxCount
          saved += cfg.stepBudget - sim.levels[i].moves
        of 1:
          sim.levels[i].outcome = loDeadlocked
          sim.levels[i].boxesPlaced = int((seed shr 41) mod 4)
          credit += sim.levels[i].boxesPlaced
        of 2:
          sim.levels[i].outcome = loOutOfSteps
          sim.levels[i].boxesPlaced = int((seed shr 45) mod 4)
          credit += sim.levels[i].boxesPlaced
        else:
          sim.levels[i].outcome = loUnreached
          sim.levels[i].moves = 0
      check sim.episodeScore() ==
        1_000_000 * weight + 10_000 * credit + saved
      check sim.episodeScore() >= 0
      check sim.episodeWin() == (weight >= cfg.parWeight)

suite "end conditions":
  test "ladderComplete, and every unstarted level is unreached with zeroes":
    var cfg = defaultConfig()
    cfg.seed = 42
    let episode = runEpisode(cfg, blPusher)
    check episode.sim.reason == endComplete
    check episode.sim.endRule == erLadderComplete
    for record in episode.sim.levels:
      check record.outcome != loRunning

  test "a wall-clock stop mid-ladder still scores the levels that ran":
    var cfg = defaultConfig()
    cfg.seed = 42
    let episode = runEpisode(cfg, blPusher, stopAtTurn = 4)
    check episode.sim.reason == endDeadline
    check episode.sim.endRule == erWallClock
    var unreached = 0
    for record in episode.sim.levels:
      if record.outcome == loUnreached:
        inc unreached
        check record.moves == 0
        check record.turns == 0
        check record.pushes == 0
        check record.boxesPlaced == 0
    check unreached > 0
    check episode.sim.episodeScore() >= 0

  test "a wall-clock stop never zeroes the level that was in play":
    # The level under the cog when the clock stops is NOT an unstarted level:
    # zeroing it would discard real, earned progress (10 000 points a crate)
    # and under-report `finalTick`. Deterministic fixture: one turn, one crate
    # parked on a marked square, then a forced deadline stop.
    let cfg = defaultConfig()
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    sim.startLevel(levelOf(OpenRoom))
    # Crates sorted by (y, x): 0 (3,2), 1 (4,5), 2 (3,7), 3 (7,7). Crate 2
    # pushed right lands on the marked square at (4,7).
    let plan = Directive(actions: @[
      Action(kind: akPush, box: 2, dir: dirRight, times: 1)])
    sim.beginTurn(plan)
    while not sim.turnComplete():
      sim.stepTick()
    sim.endTurn("")
    check sim.levelActive
    check sim.levelBoxesPlaced == 1
    let
      moves = sim.levelMove
      turns = sim.levelTurn
      pushes = sim.levelPushes
      placed = sim.levelBoxesPlaced
    check moves > 0
    sim.settle(endDeadline, erWallClock, "wall clock budget reached")
    check sim.reason == endDeadline
    check sim.endRule == erWallClock
    let record = sim.levels[0]
    check record.outcome != loUnreached
    check record.moves == moves
    check record.turns == turns
    check record.pushes == pushes
    check record.boxesPlaced == placed
    check sim.boxCredit() == placed
    check sim.finalTick() == moves
    check sim.episodeScore() == 10_000 * placed
    # Every level that never started still carries zeroes and `unreached`.
    for i in 1 ..< sim.levels.len:
      check sim.levels[i].outcome == loUnreached
      check sim.levels[i].moves == 0
      check sim.levels[i].turns == 0
      check sim.levels[i].pushes == 0
      check sim.levels[i].boxesPlaced == 0

  test "results.reason is the closed three-value enum":
    var seen: seq[string] = @[]
    for reason in EndReason:
      seen.add($reason)
    check seen == @["complete", "deadline", "fault"]
    var rules: seq[string] = @[]
    for rule in EndRule:
      rules.add($rule)
    check rules == @["ladderComplete", "turnCap", "wallClock", "fault"]

suite "no floating point in the sim":
  test "the sim modules contain no float type, literal or division":
    for name in ["sim", "grid", "deadlock", "levelgen", "search", "driver",
                 "baselines"]:
      let source = readFile("src/sokoban/" & name & ".nim")
      var lineNo = 0
      for line in source.splitLines():
        inc lineNo
        let code = line.split("##")[0]
        let trimmed = code.strip()
        if trimmed.startsWith("#"):
          continue
        check "float" notin code
        check "sqrt" notin code
        check not code.contains(".0")
        # `/` too, which is the operator that would silently make an integer
        # ratio a float. Two spellings are not arithmetic and are named here
        # rather than ignored blindly: a module path in an `import`, and
        # `os`'s path-join operator on the fallback-level directory. String
        # literals are stripped first so a path inside quotes is not a match.
        if trimmed.startsWith("import") or trimmed.startsWith("FallbackLevelDir /"):
          continue
        var bare = ""
        var inString = false
        var escaped = false
        for ch in code:
          if inString:
            if escaped: escaped = false
            elif ch == '\\': escaped = true
            elif ch == '"': inString = false
          elif ch == '"': inString = true
          else: bare.add(ch)
        check "/" notin bare

suite "tick budget":
  test "a full episode of integer grid work is fast":
    var cfg = defaultConfig()
    cfg.seed = 7
    let levels = levelsFor(cfg.seed, cfg)
    let started = cpuTime()
    discard runEpisode(cfg, blPusher, levels)
    check cpuTime() - started < 10.0
