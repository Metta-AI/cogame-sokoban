## Sokoban entrypoint: reads the Coworld runtime contract and starts either a
## live episode server or a replay viewer server.
##
## SEED RANDOMISATION HAPPENS HERE, before `config.update`'s pinned seed is
## honoured, so every seed-derived draw — the walls, the marked squares, the
## band depth, the state pick and the player start of every level — follows the
## FINAL seed (paintbot's rule, `src/ctf.nim:7-46`). The seed is randomised by
## the runner, never disclosed to the seat, and spans 2^63.

import std/[json, strutils, sysrand]
import bitworld/runtime
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
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("sokoban: bad runtime configuration: " & error.msg, 2)

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    if runtimeConfig.config.strip().len == 0:
      quit("sokoban: COGAME_CONFIG_URI is required (no game config given)", 2)
    var config = defaultConfig()
    try:
      config.update(parseJson(runtimeConfig.config))
    except CatchableError as error:
      quit("sokoban: invalid game config: " & error.msg, 2)
    if not seedPinned(runtimeConfig.config):
      config.seed = randomSeed()
      echo "sokoban: seed not pinned; randomized to ", config.seed
    try:
      config.validate()
    except CatchableError as error:
      quit("sokoban: invalid game config: " & error.msg, 2)
    if config.tokens.len == 0:
      quit("sokoban: the game config must carry one token per seat", 2)
    if config.players.len != config.numAgents:
      quit("sokoban: the game config must name " & $config.numAgents &
        " players", 2)
    echo "sokoban: seats=", config.numAgents,
      " variant=", config.variant,
      " levels=", config.levelCount,
      " stepBudget=", config.stepBudget,
      " maxTicks=", config.maxTicks,
      " wallClock=", config.wallClockBudgetSeconds, "s",
      " model=", config.model
    try:
      runGameServer(config, runtimeConfig)
    except CatchableError as error:
      quit("sokoban: " & error.msg, 2)
