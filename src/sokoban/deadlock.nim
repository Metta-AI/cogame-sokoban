## Deadlock detection — sound, and deliberately incomplete.
##
## It never flags a position that is still winnable; some unwinnable positions
## are not flagged and simply burn out on the step budget. Soundness is what
## makes "the level ends the instant it goes dead" honest; completeness would
## require solving the level.
##
## `isDeadlocked` is the ordered disjunction of exactly three tests, and the
## first that fires supplies the `kind` recorded in the `deadlock` event.

import sim_types, grid

type
  DeadSquares* = array[GridCells, bool]

  DeadlockVerdict* = object
    dead*: bool
    kind*: DeadlockKind
    box*: int      ## index into the sorted box order, or -1
    cell*: int     ## the offending cell, or -1

proc deadSquares*(board: Board): DeadSquares =
  ## The level's static dead-square set `D`, computed ONCE per level from walls
  ## and targets only — never from box positions, which is what makes it sound.
  ##
  ## Mark every target `alive`; then to a fixpoint, for every `alive` cell `c`
  ## and every direction `d`, mark `c - d` alive if `c - d` is floor AND
  ## `c - 2d` is floor (a box on `c - d` could have been PULLED to `c` by a
  ## player standing on `c - 2d`, ignoring all other boxes). `D` is every floor
  ## cell not marked alive.
  var alive: array[GridCells, bool]
  for cell in 0 ..< GridCells:
    if board.target[cell] and not board.wall[cell]:
      alive[cell] = true
  var changed = true
  while changed:
    changed = false
    for cell in 0 ..< GridCells:
      if not alive[cell]:
        continue
      for d in Dirs:
        let
          back = cell.step(d.opposite)
          back2 = cell.step2(d.opposite)
        if back < 0 or back2 < 0 or alive[back]:
          continue
        if board.wall[back] or board.wall[back2]:
          continue
        alive[back] = true
        changed = true
  for cell in 0 ..< GridCells:
    if not board.wall[cell] and not alive[cell]:
      result[cell] = true

proc deadSquareList*(dead: DeadSquares): seq[int] =
  for cell in 0 ..< GridCells:
    if dead[cell]:
      result.add(cell)

proc frozenBlockBox*(state: LevelState): int =
  ## Test 2: a 2 x 2 block of cells in which ALL FOUR are wall-or-box and at
  ## least one is a box NOT on a target. No box in such a block can ever move
  ## again. Returns the index of an offending box, or -1.
  for y in 0 ..< GridSize - 1:
    for x in 0 ..< GridSize - 1:
      var
        filled = 0
        offender = -1
      for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
        let cell = cellIndex(x + dx, y + dy)
        if state.board.wall[cell]:
          inc filled
          continue
        let box = state.boxAt(cell)
        if box >= 0:
          inc filled
          if not state.board.target[cell] and offender < 0:
            offender = box
      if filled == 4 and offender >= 0:
        return offender
  -1

proc isDeadlocked*(state: LevelState, dead: DeadSquares): DeadlockVerdict =
  ## The ordered disjunction. Tests 1 and 2 are the ones that fire in practice;
  ## test 3 is the catch-all that guarantees the sim can never spin out a level
  ## in a frozen position.
  result = DeadlockVerdict(dead: false, kind: dkNone, box: -1, cell: -1)

  # 1. dead_square — a box that is not on a target stands on a cell of D.
  for i, box in state.boxes:
    if state.board.target[box]:
      continue
    if dead[box]:
      return DeadlockVerdict(dead: true, kind: dkDeadSquare, box: i, cell: box)

  # 2. frozen_block — a 2x2 of wall-or-box holding an unparked box.
  let frozen = state.frozenBlockBox()
  if frozen >= 0:
    return DeadlockVerdict(dead: true, kind: dkFrozenBlock, box: frozen,
                           cell: state.boxes[frozen])

  # 3. no_push — a box is off-target and the legal-push set is empty.
  var unparked = -1
  for i, box in state.boxes:
    if not state.board.target[box]:
      unparked = i
      break
  if unparked >= 0 and state.legalPushes().len == 0:
    return DeadlockVerdict(dead: true, kind: dkNoPush, box: unparked,
                           cell: state.boxes[unparked])

proc isDeadlocked*(state: LevelState): DeadlockVerdict =
  state.isDeadlocked(state.board.deadSquares())

proc pushCreatesDeadlock*(
  state: LevelState, push: Push, dead: DeadSquares
): bool =
  ## Would this push leave the position dead? Used by both baselines to drop a
  ## suicidal push while a safe one exists, and by the search to prune.
  var next = state
  next.applyPush(push)
  next.isDeadlocked(dead).dead
