## Sokoban entrypoint: reads the Coworld runtime contract and starts either a
## live episode server or a replay viewer server.
##
## SEED RANDOMISATION HAPPENS HERE, and the ORDER is: read the runner's config
## first, then randomise only if the runner did not pin a seed — so a pinned
## seed always wins and every seed-derived draw (the walls, the marked squares,
## the band depth, the state pick and the player start of every level) follows
## the FINAL seed. Nothing reads `config.seed` between the two steps: the first
## `generateLevel` call is `server.nim`'s, after both. `seedPinned` reads the
## RAW config text rather than the merged struct, because `defaultConfig()`
## already carries a seed and a merged struct cannot say whether the runner
## meant it. The seed is randomised by the runner, never disclosed to the seat,
## and spans 2^63.

import std/[json, math, monotimes, os, strutils, sysrand, times]
import bitworld/[native_http, runtime, runtime_input]
import bitworld/native_stop
import bitworld/decision_trajectory
import sokoban/[server, sim_config, sim_types]

proc randomSeed(): int64 =
  var buf: array[8, byte]
  if not urandom(buf):
    raise newException(SokobanError, "OS entropy source unavailable")
  var value: int64 = 0
  for b in buf:
    value = (value shl 8) or int64(b)
  value and 0x7FFF_FFFF_FFFF_FFFF'i64

proc seedPinned(configText: string): bool =
  if configText.strip().len == 0:
    return false
  try:
    let node = parseJson(configText)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  installNativeStopHandlers()
  let processStarted = getMonoTime()
  var episodeDeadline = processStarted + initDuration(seconds = 1200)
  var inputControl: NativeRequestControl
  var inputCaptures: seq[RuntimeInputCapture]
  var runtimeConfig: RuntimeConfig
  try:
    let timeout = getEnv("COWORLD_TIMEOUT_SECONDS", "1200").parseFloat()
    if timeout <= 0 or classify(timeout) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "episode timeout must be finite and positive")
    episodeDeadline = processStarted + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
    let inputDeadline = min(episodeDeadline - initDuration(seconds = ShutdownGraceSeconds),
      processStarted + initDuration(seconds = 60))
    proc input(value, source: string): string =
      readRuntimeInput(value, source, inputDeadline, inputControl,
        16 * 1024 * 1024, 64 * 1024, inputCaptures)
    runtimeConfig = readRuntimeConfig(input)
  except CatchableError as error:
    let status = if interruptionRequested(): esTruncated else: esFailed
    writeInitializationCheckpoint(status, "runtime_config", $error.name, error.msg,
      episodeDeadline, runtimeInputCapturesJson(inputCaptures))
    if status == esTruncated: quit(0)
    quit("sokoban: runtime configuration rejected (" & $error.name & ")", 2)

  if interruptionRequested():
    writeInitializationCheckpoint(esTruncated, "runtime_config", "stop_requested",
      "process stop requested", episodeDeadline, runtimeInputCapturesJson(inputCaptures))
    quit(0)
  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig, episodeDeadline)
  else:
    if runtimeConfig.config.strip().len == 0:
      writeInitializationCheckpoint(esFailed, "game_config", "missing_config", "COGAME_CONFIG_URI is required",
        episodeDeadline, runtimeInputCapturesJson(inputCaptures))
      quit("sokoban: COGAME_CONFIG_URI is required (no game config given)", 2)
    var config = defaultConfig()
    try:
      config.update(parseJson(runtimeConfig.config))
    except CatchableError as error:
      writeInitializationCheckpoint(esFailed, "game_config", $error.name, error.msg,
        episodeDeadline, runtimeInputCapturesJson(inputCaptures))
      quit("sokoban: game configuration rejected (" & $error.name & ")", 2)
    if not seedPinned(runtimeConfig.config):
      config.seed = randomSeed()
      echo "sokoban: seed not pinned; randomized to ", config.seed
    try:
      config.validate()
      if config.tokens.len == 0:
        raise newException(SokobanError, "game config must carry one token per seat")
      if config.players.len != config.numAgents:
        raise newException(SokobanError, "game config must name every seat")
    except CatchableError as error:
      writeInitializationCheckpoint(esFailed, "game_config", $error.name, error.msg,
        episodeDeadline, runtimeInputCapturesJson(inputCaptures))
      quit("sokoban: game configuration rejected (" & $error.name & ")", 2)
    echo "sokoban: seats=", config.numAgents,
      " variant=", config.variant,
      " levels=", config.levelCount,
      " stepBudget=", config.stepBudget,
      " maxTicks=", config.maxTicks,
      " wallClock=", config.wallClockBudgetSeconds, "s",
      " turnBudgetMs=", config.turnBudgetMs
    try:
      runGameServer(config, runtimeConfig, episodeDeadline)
    except CatchableError as error:
      writeInitializationCheckpoint(esFailed, "runtime_owner", $error.name, error.msg,
        episodeDeadline, runtimeInputCapturesJson(inputCaptures))
      quit("sokoban: runtime owner failed (" & $error.name & ")", 2)
