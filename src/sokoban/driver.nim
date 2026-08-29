## The driver: directive -> per-tick actuation.
##
## Forked from the starter's `src/ctf/control.nim`, retargeted from pixel
## steering to a PRIMITIVE QUEUE. It is the ONLY producer of primitives and it
## contains no randomness.
##
## Every macro is expanded against the TURN-START snapshot; execution is always
## the literal primitive sequence, and a primitive that turns out to be blocked
## at execution time is a no-op that still costs a move. That is what keeps
## expansion and replay identical.
##
## The driver never invents a move the schema does not express, and it never
## converts an illegal macro into a different legal one.

import sim_types, grid, directives

type
  Primitive* = object
    ## One tick's worth of actuation. `isWait` is a real cost: the move is
    ## spent.
    isWait*: bool
    dir*: Dir

  Expansion* = object
    queue*: seq[Primitive]
    unreachable*: int    ## macros that yielded ZERO primitives
    truncated*: bool     ## the turn's queue was cut to turnMoves

proc waitPrimitive*(): Primitive = Primitive(isWait: true)
proc movePrimitive*(d: Dir): Primitive = Primitive(isWait: false, dir: d)

proc primitiveChar*(p: Primitive): char =
  if p.isWait: '.' else: ($p.dir)[0]

proc executedString*(queue: openArray[Primitive]): string =
  ## The LURD string that actually ran, `.` for a wait.
  for p in queue:
    result.add(p.primitiveChar())

proc expandDirective*(
  start: LevelState, directive: Directive,
  turnMoves, macroPrimitiveCap: int
): Expansion =
  ## Expands one turn's accepted actions against the turn-start board, in the
  ## order the reply lists them, then truncates the whole queue to `turnMoves`.
  ## NOTHING CARRIES OVER TO THE NEXT TURN.
  ##
  ## `push.box` indexes the TURN-START crate order — the order the observation
  ## handed the policy, "stable within a turn". `live[k]` therefore tracks where
  ## turn-start crate `k` currently stands as the expansion walks forward, so a
  ## turn that pushes crate 1 and then crate 3 addresses both correctly even
  ## though the sorted order changed under it.
  var
    state = start
    live = start.boxes
  for action in directive.actions:
    var produced: seq[Primitive] = @[]
    case action.kind
    of akWait:
      produced.add(waitPrimitive())
    of akMoves:
      for ch in action.seq:
        if produced.len >= macroPrimitiveCap:
          break
        case ch
        of 'U': produced.add(movePrimitive(dirUp))
        of 'D': produced.add(movePrimitive(dirDown))
        of 'L': produced.add(movePrimitive(dirLeft))
        of 'R': produced.add(movePrimitive(dirRight))
        else: discard
    of akGoto:
      let walk = state.walkPath(cellIndex(action.x, action.y))
      if not walk.ok:
        inc result.unreachable
      else:
        for d in walk.path:
          if produced.len >= macroPrimitiveCap:
            break
          produced.add(movePrimitive(d))
    of akPush:
      if action.box < 0 or action.box >= BoxCount:
        inc result.unreachable
      else:
        let
          cell = live[action.box]
          stand = cell.step(action.dir.opposite)
          ahead = cell.step(action.dir)
        if stand < 0 or ahead < 0 or not state.hasBox(cell) or
            not state.isFree(stand) or not state.isFree(ahead):
          inc result.unreachable
        else:
          let walk = state.walkPath(stand)
          if not walk.ok:
            inc result.unreachable
          else:
            for d in walk.path:
              if produced.len >= macroPrimitiveCap:
                break
              produced.add(movePrimitive(d))
            for _ in 0 ..< action.times:
              if produced.len >= macroPrimitiveCap:
                break
              produced.add(movePrimitive(action.dir))
    # Advance the expansion snapshot so the NEXT macro plans from where this
    # one leaves the cog. Blocked primitives are no-ops here exactly as they
    # will be at execution time, so expansion and execution agree.
    for p in produced:
      if p.isWait:
        continue
      let
        ahead = state.player.step(p.dir)
        beyond = state.player.step2(p.dir)
      if ahead < 0 or state.board.wall[ahead]:
        continue
      let box = state.boxAt(ahead)
      if box >= 0:
        if beyond < 0 or not state.isFree(beyond):
          continue
        state.boxes[box] = beyond
        state.sortBoxes()
        state.player = ahead
        for k in 0 ..< BoxCount:
          if live[k] == ahead:
            live[k] = beyond
            break
      else:
        state.player = ahead
    result.queue.add(produced)

  if result.queue.len > turnMoves:
    result.queue.setLen(turnMoves)
    result.truncated = true

proc queueOrWait*(expansion: Expansion, index: int): Primitive =
  ## The tick loop always has a primitive: the turn's queue, else `wait`.
  if index >= 0 and index < expansion.queue.len:
    expansion.queue[index]
  else:
    waitPrimitive()
