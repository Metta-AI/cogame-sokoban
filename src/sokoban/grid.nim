## The board: cells, XSB notation, 4-adjacency, the player-reachability flood,
## the legal-push enumerator and the walk BFS that `goto`, `push` and the
## `pusher` baseline all share.
##
## Pure integer. No pixie, no pixel queries, no floating point.
##
## Canonical XSB notation — the format every published Sokoban level and every
## Sokoban solver on the internet uses, and therefore the format a language
## model has actually seen:
##
##   `#` wall   ` ` floor   `.` target   `$` box   `*` box on target
##   `@` player   `+` player on a target
##
## Rows are always exactly 10 characters and there are always exactly 10 of
## them; leading and trailing spaces are significant and are never trimmed.

import std/[algorithm, strutils]
import sim_types

type
  Board* = object
    ## The STATIC half of a level: walls and marked squares. Boxes and the
    ## player live in `LevelState`, because the deadlock detector's dead-square
    ## set is a pure function of this half and nothing else — which is what
    ## makes it sound.
    wall*: array[GridCells, bool]
    target*: array[GridCells, bool]

  LevelState* = object
    board*: Board
    boxes*: array[BoxCount, int]   ## cell indices, kept sorted ascending
    player*: int                   ## cell index

proc cellIndex*(x, y: int): int {.inline.} = y * GridSize + x
proc cellX*(cell: int): int {.inline.} = cell mod GridSize
proc cellY*(cell: int): int {.inline.} = cell div GridSize

proc inBounds*(x, y: int): bool {.inline.} =
  x >= 0 and x < GridSize and y >= 0 and y < GridSize

proc step*(cell: int, d: Dir): int =
  ## The neighbour of `cell` in `d`, or -1 off the board. The border ring is
  ## always wall, so in a well-formed level this never actually leaves the
  ## board — the guard is here so a hand-built test fixture cannot index out of
  ## range.
  let delta = dirDelta(d)
  let
    nx = cellX(cell) + delta.dx
    ny = cellY(cell) + delta.dy
  if not inBounds(nx, ny): -1 else: cellIndex(nx, ny)

proc step2*(cell: int, d: Dir): int =
  ## Two cells along `d` — the "beyond" cell a push needs free.
  let first = cell.step(d)
  if first < 0: -1 else: first.step(d)

proc buildNeighbours(): array[GridCells, array[4, int]] {.compileTime.} =
  for cell in 0 ..< GridCells:
    for i, d in Dirs:
      let delta = dirDelta(d)
      let
        nx = cellX(cell) + delta.dx
        ny = cellY(cell) + delta.dy
      result[cell][i] = if inBounds(nx, ny): cellIndex(nx, ny) else: -1

const Neighbours* = buildNeighbours()
  ## `Neighbours[cell][ord(d)]` — the 4-adjacency table, precomputed at compile
  ## time. The generator's backward BFS floods millions of times per level and
  ## recomputing the arithmetic dominated it.

proc isWall*(board: Board, cell: int): bool {.inline.} =
  cell < 0 or cell >= GridCells or board.wall[cell]

proc isTarget*(board: Board, cell: int): bool {.inline.} =
  cell >= 0 and cell < GridCells and board.target[cell]

proc sortBoxes*(state: var LevelState) =
  ## Ascending cell index == ascending `(y, x)`, which is the order the seat's
  ## `boxes` array and every tie-break in the game use. An in-place insertion
  ## sort over four elements: this runs once per generated successor state
  ## (millions of times in a level generation), so it must not allocate.
  for i in 1 ..< BoxCount:
    let value = state.boxes[i]
    var j = i - 1
    while j >= 0 and state.boxes[j] > value:
      state.boxes[j + 1] = state.boxes[j]
      dec j
    state.boxes[j + 1] = value

proc boxAt*(state: LevelState, cell: int): int =
  ## The index of the box on `cell`, or -1.
  for i, box in state.boxes:
    if box == cell:
      return i
  -1

proc hasBox*(state: LevelState, cell: int): bool {.inline.} =
  state.boxAt(cell) >= 0

proc isFree*(state: LevelState, cell: int): bool {.inline.} =
  ## Free floor: on the board, not wall, not holding a box. Targets are free.
  cell >= 0 and cell < GridCells and not state.board.wall[cell] and
    not state.hasBox(cell)

proc boxesOnTargets*(state: LevelState): int =
  for box in state.boxes:
    if state.board.target[box]:
      inc result

proc floodFrom*(
  blocked: array[GridCells, bool], start: int,
  region: var array[GridCells, bool]
) =
  ## The 4-connected region of `start` through unblocked cells, over the
  ## precomputed neighbour table. ALLOCATION-FREE: the generator's backward BFS
  ## floods once per node and once per successor, millions of times per level,
  ## and a seq-backed queue here made level generation a second each instead of
  ## tens of milliseconds.
  zeroMem(addr region[0], GridCells * sizeof(bool))
  var
    queue: array[GridCells, int]
    tail = 0
    head = 0
  region[start] = true
  queue[tail] = start
  inc tail
  while head < tail:
    let cell = queue[head]
    inc head
    for i in 0 .. 3:
      let next = Neighbours[cell][i]
      if next < 0 or region[next] or blocked[next]:
        continue
      region[next] = true
      queue[tail] = next
      inc tail

proc blockedInto*(state: LevelState, blocked: var array[GridCells, bool]) =
  ## Wall-or-box, as one flat array — the flood's own view of the board.
  for cell in 0 ..< GridCells:
    blocked[cell] = state.board.wall[cell]
  for box in state.boxes:
    blocked[box] = true

proc reachableInto*(state: LevelState, region: var array[GridCells, bool]) =
  ## The player's 4-connected region through free floor; boxes block. The
  ## legality of a push and the state normalisation both read this.
  var blocked: array[GridCells, bool]
  state.blockedInto(blocked)
  if blocked[state.player]:
    # A player standing on a box is not a state the sim can produce, but a
    # hand-built fixture can ask; report the single cell so callers stay total.
    zeroMem(addr region[0], GridCells * sizeof(bool))
    region[state.player] = true
    return
  blocked.floodFrom(state.player, region)

proc reachable*(state: LevelState): array[GridCells, bool] =
  state.reachableInto(result)

proc normalisedPlayer*(state: LevelState): int =
  ## The lowest-index cell of the player's reachable region — the canonical
  ## representative used by the search's state encoding and by the generator's
  ## backward BFS, so two positions that differ only by a walk are one state.
  var region: array[GridCells, bool]
  state.reachableInto(region)
  for cell in 0 ..< GridCells:
    if region[cell]:
      return cell
  state.player

type
  Push* = object
    box*: int        ## index into the SORTED box order
    dir*: Dir
    fromCell*: int
    toCell*: int
    standCell*: int  ## the cell the player must stand on to make the push

proc legalPushes*(state: LevelState): seq[Push] =
  ## Every push that is legal right now, in ascending box index then U, D, L,
  ## R. A push is legal iff `c + d` is free floor, `c - d` is free floor, and
  ## `c - d` is in the player's reachable region. This is the ONE predicate:
  ## the observation's `pushes_available`, deadlock test 3, both baselines and
  ## the search all call it.
  let region = state.reachable()
  for i, box in state.boxes:
    for d in Dirs:
      let
        ahead = box.step(d)
        behind = box.step(Dirs[(ord(d) xor 1)])
      # U<->D and L<->R differ by exactly one bit in this enum order.
      if ahead < 0 or behind < 0:
        continue
      if not state.isFree(ahead) or not state.isFree(behind):
        continue
      if not region[behind]:
        continue
      result.add(Push(box: i, dir: d, fromCell: box, toCell: ahead,
                      standCell: behind))

proc opposite*(d: Dir): Dir {.inline.} = Dirs[(ord(d) xor 1)]

proc applyPush*(state: var LevelState, push: Push) =
  ## Moves the box and the player. The caller has already checked legality.
  state.player = push.fromCell
  for i in 0 ..< BoxCount:
    if state.boxes[i] == push.fromCell:
      state.boxes[i] = push.toCell
      break
  state.sortBoxes()

proc walkPath*(state: LevelState, target: int): tuple[ok: bool, path: seq[Dir]] =
  ## The walk BFS, run against the TURN-START board: nodes are floor cells, a
  ## cell is traversable iff it is floor and holds no box, edges are
  ## 4-adjacency in the fixed order U, D, L, R, so the path is UNIQUE for a
  ## given board. `ok = false` means the target is not free floor or is not
  ## reachable — the `unreachable` outcome, which yields ZERO primitives.
  if target < 0 or target >= GridCells or not state.isFree(target):
    return (false, @[])
  if target == state.player:
    return (true, @[])
  var
    cameFrom = newSeq[int](GridCells)
    cameDir = newSeq[Dir](GridCells)
    seen: array[GridCells, bool]
    queue = newSeqOfCap[int](GridCells)
  for i in 0 ..< GridCells:
    cameFrom[i] = -1
  seen[state.player] = true
  queue.add(state.player)
  var head = 0
  while head < queue.len:
    let cell = queue[head]
    inc head
    for d in Dirs:
      let next = cell.step(d)
      if next < 0 or seen[next] or not state.isFree(next):
        continue
      seen[next] = true
      cameFrom[next] = cell
      cameDir[next] = d
      if next == target:
        var
          path: seq[Dir] = @[]
          cursor = target
        while cursor != state.player:
          path.add(cameDir[cursor])
          cursor = cameFrom[cursor]
        path.reverse()
        return (true, path)
      queue.add(next)
  (false, @[])

# ---------------------------------------------------------------------------
#  XSB notation
# ---------------------------------------------------------------------------

proc renderRow*(state: LevelState, y: int): string =
  result = newStringOfCap(GridSize)
  for x in 0 ..< GridSize:
    let cell = cellIndex(x, y)
    if state.board.wall[cell]:
      result.add('#')
    elif state.player == cell:
      result.add(if state.board.target[cell]: '+' else: '@')
    elif state.hasBox(cell):
      result.add(if state.board.target[cell]: '*' else: '$')
    elif state.board.target[cell]:
      result.add('.')
    else:
      result.add(' ')

proc renderXsb*(state: LevelState): seq[string] =
  ## Ten strings of ten characters. Always. Never trimmed.
  for y in 0 ..< GridSize:
    result.add(state.renderRow(y))

proc parseXsb*(rows: openArray[string]): LevelState =
  ## The total inverse of `renderXsb`. Raises on any glyph outside the table or
  ## on a board that is not 10 x 10 with exactly four boxes and four targets.
  if rows.len != GridSize:
    raise newException(SokobanError,
      "XSB board must have " & $GridSize & " rows, got " & $rows.len)
  var
    boxes: seq[int] = @[]
    targets = 0
    player = -1
  for y, row in rows:
    if row.len != GridSize:
      raise newException(SokobanError,
        "XSB row " & $y & " must be " & $GridSize & " characters, got " &
        $row.len)
    for x, glyph in row:
      let cell = cellIndex(x, y)
      case glyph
      of '#': result.board.wall[cell] = true
      of ' ': discard
      of '.':
        result.board.target[cell] = true
        inc targets
      of '$': boxes.add(cell)
      of '*':
        result.board.target[cell] = true
        inc targets
        boxes.add(cell)
      of '@':
        if player >= 0:
          raise newException(SokobanError, "XSB board has two players")
        player = cell
      of '+':
        if player >= 0:
          raise newException(SokobanError, "XSB board has two players")
        result.board.target[cell] = true
        inc targets
        player = cell
      else:
        raise newException(SokobanError,
          "XSB board has an unknown glyph: '" & $glyph & "'")
  if boxes.len != BoxCount:
    raise newException(SokobanError,
      "XSB board must have " & $BoxCount & " boxes, got " & $boxes.len)
  if targets != BoxCount:
    raise newException(SokobanError,
      "XSB board must have " & $BoxCount & " targets, got " & $targets)
  if player < 0:
    raise newException(SokobanError, "XSB board has no player")
  boxes.sort()
  for i in 0 ..< BoxCount:
    result.boxes[i] = boxes[i]
  result.player = player

proc parseXsbText*(text: string): LevelState =
  var rows: seq[string] = @[]
  for line in text.splitLines():
    if line.len == 0 and rows.len == GridSize:
      break
    if line.len == 0 and rows.len == 0:
      continue
    rows.add(line)
  parseXsb(rows)

proc floorCells*(board: Board): seq[int] =
  for cell in 0 ..< GridCells:
    if not board.wall[cell]:
      result.add(cell)

proc floorConnected*(board: Board): bool =
  ## Every floor cell reachable from every other, ignoring boxes. A level whose
  ## floor is not 4-connected is rejected by the generator.
  let cells = board.floorCells()
  if cells.len == 0:
    return false
  var
    seen: array[GridCells, bool]
    queue = @[cells[0]]
    count = 1
  seen[cells[0]] = true
  var head = 0
  while head < queue.len:
    let cell = queue[head]
    inc head
    for d in Dirs:
      let next = cell.step(d)
      if next < 0 or seen[next] or board.wall[next]:
        continue
      seen[next] = true
      inc count
      queue.add(next)
  count == cells.len
