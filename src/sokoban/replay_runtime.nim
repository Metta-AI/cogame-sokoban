## Replay playback: the runtime that re-derives an episode from the recorded
## bytes, tick by tick, with the SAME sim module the server ran.
##
## Forked from the starter's `src/ctf/replay_runtime.nim` + the transport half
## of `replays.nim`. Seeking rebuilds from tick 0 and re-steps: 1 200 ticks over
## a 100-cell grid is sub-millisecond, so there is no keyframe cache to go stale.

import std/[json, strutils]
import sim_types, sim, sim_config, replays

const
  ReplayFps* = 24
    ## Presentation frames per second the shell drives (`static_replay.js`
    ## `frameMs = 1000 / 24`).
  FramesPerTick* = 2
    ## At speed 1 the board advances ONE tick every two presentation frames —
    ## 12 ticks/second, so a 1 200-tick episode plays for 100 s and even a fast
    ## 400-tick episode plays for 33 s. That is what lets
    ## `viewer_smoke.mjs --soak 10` observe real advancement instead of a
    ## legitimately finished replay (the ecos 2026-08-23 scar).
  LullTicks* = 40
    ## A lull is 40 consecutive ticks with no push, no boxon/boxoff and no
    ## level change.
  EndHoldSeconds* = 4

type
  Beat* = object
    tick*: int
    kind*: string
    label*: string

  ReplayPlayer* = object
    data*: ReplayData
    recordIndex*: int
    hashIndex*: int
    hashMismatchTick*: int
    playing*: bool
    looping*: bool
    skipLulls*: bool
    speedIndex*: int
    frameCounter*: int
    endHoldFrames*: int
    maxTick*: int
    startTick*: int
    beats*: seq[Beat]
    lullSpans*: seq[array[2, int]]
    parkedSeries*: seq[array[2, int]]   ## [tick, cumulative crates parked]
    levelBoundaries*: seq[int]
    scanComplete*: bool
    fastForwarding*: bool

proc replaySpeed*(player: ReplayPlayer): int =
  PlaybackSpeeds[clamp(player.speedIndex, 0, PlaybackSpeeds.high)]

proc newSimFromReplay*(data: ReplayData): SimServer =
  var config = defaultConfig()
  config.update(data.config)
  result = newSimServer(config)
  result.phase = phPlaying

proc applyChat(sim: SimServer, record: string) =
  ## Chat records are re-applied at playback into NON-HASHED fields only: they
  ## drive the broadcast feed and `tools/replay_summary.py` and can never affect
  ## the simulation.
  var node: JsonNode
  try:
    node = parseJson(record)
  except CatchableError:
    return
  let kind = node{"k"}.getStr()
  case kind
  of "register":
    let slot = node{"slot"}.getInt()
    if slot >= 0 and slot < sim.seats.len:
      sim.seats[slot].name = node{"name"}.getStr()
      sim.seats[slot].policyLabel = node{"policy"}.getStr()
      sim.seats[slot].kind = node{"kind"}.getStr("scripted")
      sim.seats[slot].baseline = node{"baseline"}.getStr()
      sim.seats[slot].registered = true
  of "budget_guard":
    sim.events.add(%*{
      "k": "budget", "t": sim.tick, "turn": node{"turn"}.getInt(),
      "remaining_s": node{"remaining_s"}.getInt()})
  of "fallback", "directive":
    sim.noteChatRecord(node)
  else:
    discard

proc applyRecordsAt(player: var ReplayPlayer, sim: SimServer) =
  while player.recordIndex < player.data.records.len and
      player.data.records[player.recordIndex].tick <= sim.tick:
    let record = player.data.records[player.recordIndex]
    inc player.recordIndex
    case record.kind
    of rkLevel:
      sim.startLevel(levelFromPayload(record.level))
    of rkPlan:
      var directive = Directive(
        actions: record.plan.actions,
        say: record.plan.say,
        notes: record.plan.notes,
        source: record.plan.source)
      sim.beginTurn(directive)
      if record.plan.source == dsLlm:
        sim.seats[0].llmTurns.inc
      elif record.plan.source == dsFallback:
        sim.seats[0].fallbackTurns.inc
    of rkChat:
      sim.applyChat(record.chat)
    of rkStop:
      # The wall-clock / fault stop is a LOAD-BEARING record applied by the
      # SAME proc on record and on playback, so a deadline replay hashes
      # identically at its stop tick.
      sim.settle(record.stop.reason, record.stop.endRule, record.stop.detail)

proc stepReplay*(player: var ReplayPlayer, sim: SimServer) =
  ## One recorded tick.
  player.applyRecordsAt(sim)
  if sim.phase == phGameOver:
    return
  if not sim.levelActive and not sim.needsLevel():
    sim.settle(endComplete, erLadderComplete)
    return
  ## THE RECORDS ARE THE WHOLE INPUT LOG. When they run out with the current
  ## turn fully played, the episode is over even though a level is still in
  ## play: that is the TURN CAP, for which the server writes no stop record
  ## (it writes one only when the reason is not `complete`,
  ## `server.nim:386-390`). Stepping on would spend `wait` primitives the
  ## episode never spent — changing that level's outcome and inventing ticks
  ## past the recorded hash chain. The end rule is derived the same way the
  ## server derives it: `ladderComplete` if the ladder finished, else
  ## `turnCap`.
  if player.recordIndex >= player.data.records.len and sim.turnComplete():
    sim.settle(endComplete,
               if sim.ladderComplete(): erLadderComplete else: erTurnCap)
    return
  let before = sim.tick
  sim.stepTick()
  if sim.tick == before:
    # Nothing advanced (the level ended and the next record is not due yet):
    # the recording cannot produce this, but a truncated file can, so stop
    # rather than spin.
    sim.settle(endComplete, erLadderComplete)
    return
  if player.hashIndex < player.data.hashes.len:
    if player.data.hashes[player.hashIndex] != sim.gameHashValue and
        player.hashMismatchTick < 0:
      player.hashMismatchTick = sim.tick
    inc player.hashIndex

proc rewind*(player: var ReplayPlayer, sim: var SimServer) =
  sim = newSimFromReplay(player.data)
  player.recordIndex = 0
  player.hashIndex = 0

proc seekReplay*(player: var ReplayPlayer, sim: var SimServer, tick: int) =
  let target = clamp(tick, 0, player.maxTick)
  player.rewind(sim)
  while sim.tick < target and sim.phase != phGameOver:
    player.stepReplay(sim)
  sim.events.setLen(0)

proc scanReplay*(player: var ReplayPlayer) =
  ## The LOAD-TIME PRE-SCAN: re-simulate the whole episode once headlessly,
  ## recording the per-tick cumulative crates parked, the level boundary ticks,
  ## the beat ticks and the lull spans, then reset. That is what lets the
  ## progress sparkline and the scrubber beats draw at FULL WIDTH on the first
  ## frame instead of growing in.
  var sim = newSimFromReplay(player.data)
  var probe = ReplayPlayer(data: player.data, hashMismatchTick: -1)
  var
    parked = 0
    lastEventTick = 0
    quietStart = 0
  player.beats.setLen(0)
  player.lullSpans.setLen(0)
  player.parkedSeries.setLen(0)
  player.levelBoundaries.setLen(0)
  player.parkedSeries.add([0, 0])
  var bestPlaced = newSeq[int](max(1, sim.config.levelCount))
  while sim.phase != phGameOver and sim.tick < 100_000:
    probe.stepReplay(sim)
    for event in sim.events:
      let kind = event{"k"}.getStr()
      let tick = event{"t"}.getInt()
      case kind
      of "levelstart":
        player.beats.add(Beat(tick: tick, kind: "levelstart",
          label: "LEVEL " & $(event{"i"}.getInt() + 1) & " — " &
            event{"tier"}.getStr().toUpperAscii() & ", SOLVABLE IN " &
            $event{"optPushes"}.getInt() & " PUSHES"))
        player.levelBoundaries.add(tick)
        lastEventTick = tick
      of "boxon":
        let index = event{"i"}.getInt()
        let placed = event{"placed"}.getInt()
        let level = max(0, sim.levelIndex)
        if level < bestPlaced.len and placed > bestPlaced[level]:
          # A crate shuffled on and off a marked square draws ONE marker, not
          # ten: `boxon` is beaten only when it raises that level's `placed` to
          # a new maximum.
          bestPlaced[level] = placed
          parked.inc
          player.beats.add(Beat(tick: tick, kind: "boxon",
            label: "CRATE PARKED — " & $placed & " OF 4"))
          player.parkedSeries.add([tick, parked])
        discard index
        lastEventTick = tick
      of "boxoff":
        lastEventTick = tick
      of "deadlock":
        player.beats.add(Beat(tick: tick, kind: "deadlock",
          label: "DEADLOCK CREATED — CRATE " & $event{"box"}.getInt() &
            " CORNERED AT (" & $event{"x"}.getInt() & "," &
            $event{"y"}.getInt() & ")"))
        lastEventTick = tick
      of "solved":
        player.beats.add(Beat(tick: tick, kind: "solved",
          label: "LEVEL " & $(event{"i"}.getInt() + 1) & " SOLVED IN " &
            $event{"moves"}.getInt() & " MOVES / " &
            $event{"pushes"}.getInt() & " PUSHES"))
        lastEventTick = tick
      of "failed":
        player.beats.add(Beat(tick: tick, kind: "failed",
          label: "LEVEL " & $(event{"i"}.getInt() + 1) & " LOST — " &
            event{"why"}.getStr().toUpperAscii()))
        lastEventTick = tick
      of "fallback":
        player.beats.add(Beat(tick: tick, kind: "fallback",
          label: "MISSED THE CALL — pusher plan"))
        lastEventTick = tick
      of "end":
        player.beats.add(Beat(tick: tick, kind: "end",
          label: "FINAL — " & $event{"solved"}.getInt() & " OF " &
            $event{"of"}.getInt() & " SOLVED"))
      else:
        discard
    if sim.tick - lastEventTick >= LullTicks:
      if quietStart == 0:
        quietStart = lastEventTick + 1
    elif quietStart > 0:
      player.lullSpans.add([quietStart, sim.tick])
      quietStart = 0
    sim.events.setLen(0)
  if quietStart > 0 and sim.tick > quietStart:
    player.lullSpans.add([quietStart, sim.tick])
  player.maxTick = sim.tick
  player.parkedSeries.add([sim.tick, parked])
  player.scanComplete = true

proc initReplayRuntime*(
  data: ReplayData
): tuple[sim: SimServer, player: ReplayPlayer] =
  var player = ReplayPlayer(
    data: data, hashMismatchTick: -1, playing: true, looping: true,
    speedIndex: 0, startTick: 0)
  player.scanReplay()
  var sim = newSimFromReplay(data)
  player.rewind(sim)
  result.sim = sim
  result.player = player

proc isLullTick*(player: ReplayPlayer, tick: int): bool =
  for span in player.lullSpans:
    if tick >= span[0] and tick < span[1]:
      return true
  false

proc applyReplayCommand*(
  player: var ReplayPlayer, sim: var SimServer, command: char
) =
  ## The starter's transport vocabulary, kept 1:1 so `chrome_common.js`'s
  ## buttons and speed chips drive this runtime unchanged.
  case command
  of ' ':
    player.playing = not player.playing
  of 'p':
    player.playing = true
  of 'P':
    player.playing = false
  of '1': player.speedIndex = 0
  of '2': player.speedIndex = 1
  of '4': player.speedIndex = 2
  of '8': player.speedIndex = 3
  of '+', '=':
    player.speedIndex = min(player.speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    player.speedIndex = max(player.speedIndex - 1, 0)
  of ',', '<':
    player.playing = false
    player.seekReplay(sim, player.startTick)
  of 'b':
    player.playing = false
    player.seekReplay(sim, max(player.startTick, sim.tick - 1))
  of 'e':
    player.playing = false
    player.seekReplay(sim, player.maxTick)
  of 'r':
    player.looping = not player.looping
  of 'f':
    player.skipLulls = not player.skipLulls
  of '.', '>':
    player.playing = false
    player.seekReplay(sim, sim.tick + ReplayFps * 5)
  else:
    discard

proc advanceReplayFrame*(
  player: var ReplayPlayer, sim: var SimServer,
  seekTicks: openArray[int], commands: openArray[char]
): JsonNode =
  ## Applies viewer controls and advances ONE presentation frame.
  var jumped = false
  for tick in seekTicks:
    player.seekReplay(sim, tick)
    player.endHoldFrames = 0
    jumped = true
  for command in commands:
    let before = sim.tick
    player.applyReplayCommand(sim, command)
    if sim.tick != before:
      player.endHoldFrames = 0
      jumped = true
  sim.events.setLen(0)
  player.fastForwarding = false
  if not player.playing:
    return sim.drainEvents()
  if sim.phase == phGameOver:
    if player.looping:
      if player.endHoldFrames <= 0:
        player.endHoldFrames = EndHoldSeconds * ReplayFps
      dec player.endHoldFrames
      if player.endHoldFrames <= 0:
        player.seekReplay(sim, player.startTick)
    return sim.drainEvents()
  inc player.frameCounter
  var ticks = 0
  let speed = player.replaySpeed()
  if speed >= FramesPerTick:
    ticks = speed div FramesPerTick
  elif player.frameCounter mod FramesPerTick == 0:
    ticks = 1
  if player.skipLulls and player.isLullTick(sim.tick):
    ticks = max(ticks, 1) * 8
    player.fastForwarding = true
  for _ in 0 ..< ticks:
    if sim.phase == phGameOver:
      break
    player.stepReplay(sim)
  sim.drainEvents()

proc endHoldSecondsLeft*(player: ReplayPlayer): int =
  if player.endHoldFrames <= 0: 0
  else: (player.endHoldFrames + ReplayFps - 1) div ReplayFps
