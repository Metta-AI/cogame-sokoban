## The bounded best-first push-space search, and the greedy matching heuristic.
##
## ONE implementation, three callers — `pusher` (the scripted filler AND the
## server-side fallback), `nudger`'s one-ply scoring, and the tests — so the
## fallback and the filler can never drift.
##
## Everything here is integer: `h` is a sum of Manhattan distances, `g` is
## pushes so far, and the priority is the total order `(f, h, insertion)`, so
## the search is deterministic.

import std/[algorithm, tables]
import sim_types, grid, deadlock

type
  SearchParams* = object
    ## The tunables. Like the starter's `DefaultBaselineParams` these are a
    ## parameter object chosen by `tools/tune_baselines.nim`'s sweep and pinned
    ## by `tests/test_sokoban_tuning.nim`, not guessed.
    nodeCap*: int
    greedyMatch*: bool   ## greedy matching (true) vs nearest-target (false)
    tieOnH*: bool        ## break an `f` tie on `h` (true) or on insertion

  SearchResult* = object
    solved*: bool
    pushes*: seq[Push]   ## the push sequence to the best state found
    expanded*: int
    bestH*: int

const DefaultSearchParams* = SearchParams(
  nodeCap: 8, greedyMatch: true, tieOnH: false)
  ## THE SWEPT PICK, recorded in `tools/ci/baseline_tuning.json`. An unbounded
  ## best-first search over a 10 x 10 four-crate board solves essentially every
  ## level (a 20 000-node cap measured 1.00 / 1.00 / 0.99 across the tiers),
  ## which is precisely the superhuman floor the design note's test 25 exists to
  ## keep out of the image. The sweep picks the tightest bound that lands inside
  ## the band, and `tools/tune_baselines.nim --check` re-derives it.

proc manhattan(a, b: int): int {.inline.} =
  abs(cellX(a) - cellX(b)) + abs(cellY(a) - cellY(b))

proc heuristic*(state: LevelState, params: SearchParams): int =
  ## The sum, over boxes, of the Manhattan distance from the box to its
  ## assigned target under a greedy matching that repeatedly takes the globally
  ## smallest (box, unmatched target) distance, ties broken by ascending box
  ## index then ascending target index. `h == 0` iff every box is parked.
  var targets: seq[int] = @[]
  for cell in 0 ..< GridCells:
    if state.board.target[cell]:
      targets.add(cell)
  if not params.greedyMatch:
    for box in state.boxes:
      var best = high(int)
      for target in targets:
        best = min(best, manhattan(box, target))
      result += best
    return
  var
    boxTaken: array[BoxCount, bool]
    targetTaken = newSeq[bool](targets.len)
  for _ in 0 ..< BoxCount:
    var
      bestDistance = high(int)
      bestBox = -1
      bestTarget = -1
    for bi, box in state.boxes:
      if boxTaken[bi]:
        continue
      for ti, target in targets:
        if targetTaken[ti]:
          continue
        let distance = manhattan(box, target)
        if distance < bestDistance:
          bestDistance = distance
          bestBox = bi
          bestTarget = ti
    if bestBox < 0:
      break
    boxTaken[bestBox] = true
    targetTaken[bestTarget] = true
    result += bestDistance

proc encodeState*(state: LevelState): uint64 =
  ## Five cell bytes: the four sorted box cells plus the NORMALISED player cell
  ## (the lowest-index cell of the player's reachable region). Two positions
  ## that differ only by a walk encode identically, which is what keeps the
  ## search in push space.
  result = uint64(state.normalisedPlayer())
  for box in state.boxes:
    result = (result shl 8) or uint64(box)

type
  Node = object
    state: LevelState
    g: int
    h: int
    parent: int
    push: Push

proc bestFirstSearch*(
  start: LevelState, dead: DeadSquares, params: SearchParams
): SearchResult =
  ## Best-first over push space. Any successor the detector flags is PRUNED and
  ## never expanded. Stops at `h == 0` (solved) or when `nodeCap` expansions
  ## have been made; on failure it returns the push sequence to the lowest-`h`
  ## state reached, which is what keeps the baseline moving on a level it
  ## cannot finish.
  var
    nodes: seq[Node] = @[]
    seen = initTable[uint64, bool]()
    bestIndex = 0
  nodes.add(Node(state: start, g: 0, h: start.heuristic(params), parent: -1))
  seen[start.encodeState()] = true
  result.bestH = nodes[0].h

  proc pathTo(index: int): seq[Push] =
    var
      cursor = index
      reversed: seq[Push] = @[]
    while cursor > 0:
      reversed.add(nodes[cursor].push)
      cursor = nodes[cursor].parent
    reversed.reverse()
    reversed

  if nodes[0].h == 0:
    result.solved = true
    return

  # The open set is a sorted-on-demand index list. Push counts are tiny (<= 34
  # here) and the node cap is 20 000, so an O(n log n) resort per pop would
  # dominate; instead the open list is scanned for the minimum, which is O(n)
  # with a tiny constant and — unlike a binary heap — is trivially a TOTAL
  # order, so two runs cannot differ.
  var open: seq[int] = @[0]
  while open.len > 0 and result.expanded < params.nodeCap:
    var
      pick = 0
      pickF = nodes[open[0]].g + nodes[open[0]].h
      pickH = nodes[open[0]].h
    for i in 1 ..< open.len:
      let
        index = open[i]
        f = nodes[index].g + nodes[index].h
      var better = f < pickF
      if not better and f == pickF:
        if params.tieOnH:
          better = nodes[index].h < pickH
        else:
          better = index < open[pick]
      if better:
        pick = i
        pickF = f
        pickH = nodes[index].h
    let current = open[pick]
    open.del(pick)
    inc result.expanded

    for push in nodes[current].state.legalPushes():
      var next = nodes[current].state
      next.applyPush(push)
      let key = next.encodeState()
      if seen.hasKeyOrPut(key, true):
        continue
      if next.isDeadlocked(dead).dead:
        continue
      let h = next.heuristic(params)
      nodes.add(Node(state: next, g: nodes[current].g + 1, h: h,
                     parent: current, push: push))
      let index = nodes.len - 1
      if h < result.bestH:
        result.bestH = h
        bestIndex = index
      if h == 0:
        result.solved = true
        result.pushes = pathTo(index)
        return
      open.add(index)

  result.pushes = pathTo(bestIndex)

proc primitivesForPushes*(
  start: LevelState, pushes: openArray[Push], limit: int
): seq[Dir] =
  ## Realises a push sequence as primitives: walk to each push's approach
  ## square, then step into the box. Stops at `limit` primitives; a push whose
  ## approach square has become unreachable stops the realisation there (it
  ## cannot happen for a sequence the search produced, but a caller may hand in
  ## a stale plan).
  var state = start
  for push in pushes:
    if result.len >= limit:
      break
    let stand = push.fromCell.step(push.dir.opposite)
    if stand < 0 or not state.isFree(stand):
      break
    let walk = state.walkPath(stand)
    if not walk.ok:
      break
    for d in walk.path:
      if result.len >= limit:
        return
      result.add(d)
      state.player = state.player.step(d)
    if result.len >= limit:
      return
    # The push itself.
    var live: Push
    var found = false
    for candidate in state.legalPushes():
      if candidate.fromCell == push.fromCell and candidate.dir == push.dir:
        live = candidate
        found = true
        break
    if not found:
      break
    result.add(push.dir)
    state.applyPush(live)
