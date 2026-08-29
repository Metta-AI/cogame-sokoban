import
  std/json,
  sokoban/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  packet: seq[uint8]
  lastError: string
  leadSent = false

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the module's
## own globals instead of trapping. The bundle is therefore linked with
## `-s ABORTING_MALLOC=1` — allocation failure aborts the runtime loudly — and
## this FIXED buffer, stamped before each risky phase, stays readable from JS
## after the abort (aborting kills the call stack, not the linear memory), so
## the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  let sendLead = not leadSent and replay.scanComplete
  let chrome = game.buildStateJson(
    events,
    playing = replay.playing,
    speed = replay.replaySpeed(),
    maxTick = replay.maxTick,
    looping = replay.looping,
    transportEnabled = true,
    mismatchTick = replay.hashMismatchTick,
    startTick = replay.startTick,
    endHoldSeconds = replay.endHoldSecondsLeft(),
    skipLulls = replay.skipLulls,
    fastForwarding = replay.fastForwarding,
    lullSpans = (if sendLead: replay.lullSpans else: @[]),
    parkedSeries = (if sendLead: replay.parkedSeries else: @[]),
    beats = (if sendLead: replay.beats else: @[]),
    sendLead = sendLead)
  if sendLead:
    leadSent = true
  var nextViewer: GlobalViewerState
  packet = game.buildViewerPacket(viewer, nextViewer, chrome)
  viewer = nextViewer

proc sokobanLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "sokoban_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    ## THE LOAD-TIME PRE-SCAN. `initReplayRuntime` re-simulates the whole
    ## episode once headlessly (<= 1 200 ticks over a 100-cell grid, and there
    ## is NO GENERATOR TO RE-RUN because the boards are in the bytes), records
    ## the per-tick cumulative crates parked, the level boundary ticks, the beat
    ## ticks and the lull spans, then resets and renders frame 0.
    stampStage("pre-scan replay")
    var initialized = initReplayRuntime(replayData)
    game = initialized.sim
    replay = initialized.player
    viewer = initGlobalViewerState()
    leadSent = false
    runtimeLoaded = true
    frameStage = "advance replay"
    stampStage("render first frame")
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc sokobanInput(data: ptr uint8, length: cint)
    {.exportc: "sokoban_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc sokobanFrame(): cint {.exportc: "sokoban_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let commands = viewer.replayCommands
    viewer.replaySeekTick = -1
    viewer.replayCommands.setLen(0)
    let events = replay.advanceReplayFrame(game, seekTicks, commands)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc sokobanPacketPointer(): ptr uint8
    {.exportc: "sokoban_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc sokobanPacketLength(): cint {.exportc: "sokoban_packet_len", cdecl.} =
  cint(packet.len)

proc sokobanMismatchTick(): cint {.exportc: "sokoban_mismatch_tick", cdecl.} =
  ## `checkReplayHash`'s divergence tick, or -1. One divergent bit is caught at
  ## the tick it happens and surfaced as `mismatchTick` in `#mmwarn`.
  if runtimeLoaded: cint(replay.hashMismatchTick) else: -1

proc sokobanErrorPointer(): ptr uint8 {.exportc: "sokoban_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc sokobanErrorLength(): cint {.exportc: "sokoban_error_len", cdecl.} =
  cint(lastError.len)

proc sokobanStagePointer(): ptr uint8 {.exportc: "sokoban_stage_ptr", cdecl.} =
  ## Unlike `sokoban_error_*`, this stays valid after an allocation-failure
  ## abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc sokobanStageLength(): cint {.exportc: "sokoban_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the loaded art, the replay data — everything — while the wasm module
  # stays alive and JS keeps calling sokoban_load_replay/sokoban_frame. The
  # whole session then runs on freed globals. Unwinding main through
  # emscripten's live-runtime exit skips the destructor epilogue entirely, so
  # globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
