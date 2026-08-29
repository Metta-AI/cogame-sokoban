## The scripted baselines, and the server-side fallback.
##
## Both emit the SAME reply objects an LLM does, through the SAME validator,
## which is what makes the bounded-orders test meaningful. NEITHER EVER EMITS
## `say` OR `notes` — a baseline that narrated would make the feed lie about
## which seats are LLMs.
##
## `pusher` is also the server-side fallback: `decide.nim` imports THIS proc
## rather than duplicating it, so the fallback and the filler can never drift
## (`tests/test_sokoban_baselines.nim` asserts they are the same proc).

import std/strutils
import sim_types, grid, deadlock, search, directives

type
  Baseline* = enum
    blPusher = "pusher"
    blNudger = "nudger"

proc parseBaseline*(name: string): Baseline =
  ## Anything unrecognised is the published default — the starter's rule.
  case name.strip().toLowerAscii()
  of "nudger": blNudger
  else: blPusher

proc pushAction(
  live: array[BoxCount, int], push: Push, times: int
): Action =
  ## The push, addressed by the crate's TURN-START index — the order the
  ## observation hands the policy and the order `driver.expandDirective`
  ## resolves. `live[k]` is where turn-start crate `k` currently stands.
  var box = push.box
  for k in 0 ..< BoxCount:
    if live[k] == push.fromCell:
      box = k
      break
  Action(kind: akPush, box: box, dir: push.dir, times: max(1, times))

proc pusherPlan*(
  state: LevelState, dead: DeadSquares, params: SearchParams,
  turnMoves: int
): Directive =
  ## `pusher` — a bounded best-first search over push space, and the "search"
  ## half of the idea's "reasoning-model vs search ladder".
  ##
  ## The search is re-run from the current state every turn: it is cheap and it
  ## keeps the baseline STATELESS, so a fallback turn in the middle of an LLM
  ## episode behaves identically to a filler episode.
  result.source = dsScripted
  let found = bestFirstSearch(state, dead, params)
  if found.pushes.len > 0:
    # Emit the leading pushes of the solution, as `push` actions, capped so the
    # realised primitive sequence cannot exceed the turn.
    var
      probe = state
      live = state.boxes
      emitted = 0
      moves = 0
    for push in found.pushes:
      if emitted >= 8 or moves >= turnMoves:
        break
      var chosen: Push
      var ok = false
      for candidate in probe.legalPushes():
        if candidate.fromCell == push.fromCell and candidate.dir == push.dir:
          chosen = candidate
          ok = true
          break
      if not ok:
        break
      let stand = chosen.fromCell.step(chosen.dir.opposite)
      let walk = probe.walkPath(stand)
      if not walk.ok:
        break
      moves += walk.path.len + 1
      result.actions.add(pushAction(live, chosen, 1))
      for k in 0 ..< BoxCount:
        if live[k] == chosen.fromCell:
          live[k] = chosen.toCell
          break
      inc emitted
      probe.applyPush(chosen)
    if result.actions.len > 0:
      return

  # No solution and no progress path: if not even one legal non-deadlocking
  # push exists, take the push that minimises `h` regardless. The level is lost
  # either way, and a `deadlock` beat is more honest and more watchable than
  # twenty waits.
  let pushes = state.legalPushes()
  if pushes.len == 0:
    result.actions.add(Action(kind: akWait, times: 1))
    return
  var
    bestPush = pushes[0]
    bestH = high(int)
  for push in pushes:
    var next = state
    next.applyPush(push)
    let h = next.heuristic(params)
    if h < bestH:
      bestH = h
      bestPush = push
  result.actions.add(pushAction(state.boxes, bestPush, 1))

proc nudgerPlan*(
  state: LevelState, dead: DeadSquares, params: SearchParams
): Directive =
  ## `nudger` — the ONE-PLY control, and the answer to "did the champion
  ## actually plan?". Every turn: enumerate the legal pushes, drop the ones the
  ## deadlock detector flags, take the single push that most reduces `h` (ties:
  ## ascending box index, then U, D, L, R). No search, no ordering, no
  ## lookahead.
  result.source = dsScripted
  let pushes = state.legalPushes()
  if pushes.len == 0:
    result.actions.add(Action(kind: akWait, times: 1))
    return
  var
    best = -1
    bestH = high(int)
    fallbackBest = 0
    fallbackH = high(int)
  for i, push in pushes:
    var next = state
    next.applyPush(push)
    let h = next.heuristic(params)
    if h < fallbackH:
      fallbackH = h
      fallbackBest = i
    if next.isDeadlocked(dead).dead:
      continue
    if h < bestH:
      bestH = h
      best = i
  let chosen = if best >= 0: pushes[best] else: pushes[fallbackBest]
  result.actions.add(pushAction(state.boxes, chosen, 1))

proc scriptedPlan*(
  kind: Baseline, state: LevelState, dead: DeadSquares,
  params: SearchParams, turnMoves: int
): Directive =
  case kind
  of blPusher: pusherPlan(state, dead, params, turnMoves)
  of blNudger: nudgerPlan(state, dead, params)
