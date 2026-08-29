## The per-seat observation: the board and the structured lists agree,
## `pushes_available` is exactly the legal set, and nothing hidden leaks.

import std/[json, strutils, unittest]
import sokoban/sim
import helpers

proc observationsFor(count: int): seq[JsonNode] =
  let cfg = defaultConfig()
  var made = 0
  var s = 0
  while made < count:
    let levels = levelsFor(int64(s) * 8837 + 11, cfg)
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    while made < count and not sim.episodeOver():
      if sim.needsLevel():
        sim.startLevel(levels[sim.levelIndex + 1])
      if not sim.levelActive:
        break
      result.add(sim.observationJson(0))
      inc made
      let plan = sim.scriptedDirective(blPusher)
      sim.beginTurn(plan)
      while not sim.turnComplete():
        sim.stepTick()
      sim.endTurn(plan.notes)
      discard sim.drainEvents()
    inc s

suite "board and structure agree":
  test "re-parsing `board` reconstructs player, boxes and targets exactly":
    for view in observationsFor(SampleStates * 2):
      var rows: seq[string] = @[]
      for row in view["board"]:
        rows.add(row.getStr())
      check rows.len == GridSize
      for row in rows:
        check row.len == GridSize
      let state = parseXsb(rows)
      check cellX(state.player) == view["player"]["x"].getInt()
      check cellY(state.player) == view["player"]["y"].getInt()
      check view["boxes"].len == BoxCount
      check view["targets"].len == BoxCount
      var lastCell = -1
      for i, entry in view["boxes"].getElems():
        let cell = cellIndex(entry["x"].getInt(), entry["y"].getInt())
        check entry["i"].getInt() == i
        check state.boxes[i] == cell
        # sorted ascending by (y, x)
        check cell > lastCell
        lastCell = cell
        check entry["on_target"].getBool() == state.board.target[cell]
      for entry in view["targets"]:
        check state.board.target[
          cellIndex(entry["x"].getInt(), entry["y"].getInt())]

suite "pushes_available is exactly the legal set":
  test "it equals the sim's own predicate and carries no deadlock annotation":
    for view in observationsFor(SampleStates * 2):
      var rows: seq[string] = @[]
      for row in view["board"]:
        rows.add(row.getStr())
      let state = parseXsb(rows)
      var expected: seq[string] = @[]
      for push in state.legalPushes():
        expected.add($push.box & $push.dir & "@" & $push.toCell)
      var got: seq[string] = @[]
      for entry in view["pushes_available"]:
        let cell = cellIndex(entry["to"][0].getInt(), entry["to"][1].getInt())
        got.add($entry["box"].getInt() & entry["dir"].getStr() & "@" & $cell)
        # No deadlock annotation: the model must cross-reference `to` against
        # `dead_squares` itself.
        check entry.len == 3
        check not entry.hasKey("dead")
        check not entry.hasKey("safe")
      check got == expected

suite "last_turn reports the seat's own turn accurately":
  test "dropped counts the entries the reply lost, and matches the replay":
    # Both champion prompts tell the seat to read `last_turn`; a hard-coded
    # zero would silently disable that self-correction loop.
    let cfg = defaultConfig()
    let levels = levelsFor(cfg.seed, cfg)
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    sim.startLevel(levels[0])
    # Two entries that fail validation (box 9 is out of range, `sideways` is
    # not a direction) plus one past a cap of two.
    let payload = parseJson("""{"actions":[
      {"do":"push","box":9,"dir":"R"},
      {"do":"push","box":2,"dir":"sideways"},
      {"do":"wait"},
      {"do":"wait"},
      {"do":"wait"}]}""")
    var directive = parseDirective(payload, 2)
    check directive.dropped == 2
    check directive.overCap == 1
    sim.beginTurn(directive)
    while not sim.turnComplete():
      sim.stepTick()
    sim.endTurn("")
    check sim.lastReport.dropped == directive.dropped + directive.overCap
    let view = sim.observationJson(0)
    check view["last_turn"]["dropped"].getInt() == 3
    check view["last_turn"]["unreachable"].getInt() == sim.turnUnreachable

suite "nothing hidden leaks":
  test "the observation names no seed, no future level, no solution, no score":
    let cfg = defaultConfig()
    let levels = levelsFor(cfg.seed, cfg)
    let sim = newSimServer(cfg)
    sim.phase = phPlaying
    sim.startLevel(levels[0])
    let view = sim.observationJson(0)
    let text = $view
    check "seed" notin text
    check "score" notin text
    check "solution" notin text
    check not view.hasKey("seed")
    check view["you"].getStr() == "Alpha"
    # A future level's board must not exist yet, let alone appear. The border
    # ring is shared by every board, so the whole board is what identifies one.
    for i in 1 ..< cfg.levelCount:
      check levels[i].state.renderXsb().join("\",\"") notin text

  test "no real policy name reaches a prompt":
    let cfg = defaultConfig()
    let levels = levelsFor(cfg.seed, cfg)
    let sim = newSimServer(cfg)
    sim.seats[0].name = "sokoban-lookahead"
    sim.seats[0].policyLabel = "lookahead"
    sim.phase = phPlaying
    sim.startLevel(levels[0])
    let text = $sim.observationJson(0)
    check "sokoban-lookahead" notin text
    check "lookahead" notin text
    check "daveey" notin text

  test "the fixed field shapes never change":
    for view in observationsFor(SampleStates div 2):
      check view["board"].len == GridSize
      check view["boxes"].len == BoxCount
      check view["targets"].len == BoxCount
      var dirs: seq[string] = @[]
      for d in view["world"]["dirs"]:
        dirs.add(d.getStr())
      check dirs == @["U", "D", "L", "R"]
