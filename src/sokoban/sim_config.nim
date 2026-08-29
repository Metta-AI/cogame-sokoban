## The game config lifecycle: `COGAME_CONFIG_URI` in, a validated `GameConfig`
## out.
##
## The starter's validators are kept, and §Decisions' numbers satisfy them:
## `attempt1Ms` and `retryMs` must be WHOLE SECONDS (curl's `CURLOPT_TIMEOUT`
## granularity is whole seconds, so a 4500 ms deadline really runs with 4 s and
## is not the deadline it claims to be), `attempt1Ms + retryMs <= turnBudgetMs`,
## and `wallClockBudgetSeconds` must be positive.

import std/[json, strutils]
import sim_types

proc readCogameUri*(uri, label: string): string =
  ## `file:///...` for local runs; anything else is fetched by the caller. The
  ## runner only ever hands out file URIs to the game container.
  if uri.startsWith("file://"):
    return readFile(uri[7 .. ^1])
  raise newException(SokobanError, label & ": unsupported URI scheme: " & uri)

proc getInt(node: JsonNode, key: string, fallback: int): int =
  let value = node{key}
  if value.isNil: return fallback
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: value.getStr().strip().parseInt()
    except CatchableError: fallback
  else: fallback

proc getBool(node: JsonNode, key: string, fallback: bool): bool =
  let value = node{key}
  if value.isNil: return fallback
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  else: fallback

proc update*(config: var GameConfig, payload: JsonNode) =
  ## Applies the runner's `game_config` over the defaults. Unknown keys are
  ## ignored; `tokens` is runner-injected and is never read from a variant.
  if payload.isNil or payload.kind != JObject:
    return
  let players = payload{"players"}
  if not players.isNil and players.kind == JArray and players.len > 0:
    config.players = @[]
    for item in players:
      config.players.add(PlayerSpec(name: item{"name"}.getStr("Alpha")))
  let tokens = payload{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      config.tokens.add(item.getStr())
  let slots = payload{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slots = @[]
    for item in slots:
      config.slots.add(int(item.getBiggestInt()))
  let seed = payload{"seed"}
  if not seed.isNil and seed.kind in {JInt, JFloat}:
    config.seed = seed.getBiggestInt()
  let ladder = payload{"tierLadder"}
  if not ladder.isNil and ladder.kind == JArray and ladder.len > 0:
    config.tierLadder = @[]
    for item in ladder:
      let parsed = parseTier(item.getStr())
      if not parsed.ok:
        raise newException(SokobanError,
          "unknown tier in tierLadder: " & item.getStr())
      config.tierLadder.add(parsed.tier)
  config.numAgents = payload.getInt("num_agents",
    payload.getInt("numAgents", config.numAgents))
  config.minPlayers = payload.getInt("minPlayers", config.minPlayers)
  config.gridSize = payload.getInt("gridSize", config.gridSize)
  config.boxCount = payload.getInt("boxCount", config.boxCount)
  config.levelCount = payload.getInt("levelCount", config.levelCount)
  config.turnMoves = payload.getInt("turnMoves", config.turnMoves)
  config.levelTurnCap = payload.getInt("levelTurnCap", config.levelTurnCap)
  config.stepBudget = payload.getInt("stepBudget", config.stepBudget)
  config.maxTurns = payload.getInt("maxTurns", config.maxTurns)
  config.maxTicks = payload.getInt("maxTicks", config.maxTicks)
  config.parWeight = payload.getInt("parWeight", config.parWeight)
  config.maxActionsPerTurn = payload.getInt(
    "maxActionsPerTurn", config.maxActionsPerTurn)
  config.macroPrimitiveCap = payload.getInt(
    "macroPrimitiveCap", config.macroPrimitiveCap)
  config.genNodeCap = payload.getInt("genNodeCap", config.genNodeCap)
  config.genAttemptCap = payload.getInt("genAttemptCap", config.genAttemptCap)
  config.baselineNodeCap = payload.getInt(
    "baselineNodeCap", config.baselineNodeCap)
  config.attempt1Ms = payload.getInt("attempt1Ms", config.attempt1Ms)
  config.retryMs = payload.getInt("retryMs", config.retryMs)
  config.turnBudgetMs = payload.getInt("turnBudgetMs", config.turnBudgetMs)
  config.turnSpacingMs = payload.getInt("turnSpacingMs", config.turnSpacingMs)
  config.wallClockBudgetSeconds = payload.getInt(
    "wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  config.lobbyJoinTimeoutTicks = payload.getInt(
    "lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  config.gameOverTicks = payload.getInt("gameOverTicks", config.gameOverTicks)
  config.fastMode = payload.getBool("fastMode", config.fastMode)
  config.showPlayerLabels = payload.getBool(
    "showPlayerLabels", config.showPlayerLabels)
  config.maxOutputTokens = payload.getInt(
    "maxOutputTokens", config.maxOutputTokens)
  let model = payload{"model"}
  if not model.isNil and model.kind == JString:
    config.model = model.getStr()
  let variant = payload{"variant"}
  if not variant.isNil and variant.kind == JString:
    config.variant = variant.getStr()

proc validate*(config: GameConfig) =
  ## The starter's validators, kept.
  if config.numAgents < 1:
    raise newException(SokobanError, "num_agents must be at least 1")
  if config.gridSize != GridSize:
    raise newException(SokobanError,
      "gridSize is fixed at " & $GridSize & " in this coworld")
  if config.boxCount != BoxCount:
    raise newException(SokobanError,
      "boxCount is fixed at " & $BoxCount & " in this coworld")
  if config.levelCount < 1:
    raise newException(SokobanError, "levelCount must be at least 1")
  if config.tierLadder.len != config.levelCount:
    raise newException(SokobanError,
      "tierLadder must have levelCount entries")
  if config.stepBudget != config.levelTurnCap * config.turnMoves:
    raise newException(SokobanError,
      "stepBudget must equal levelTurnCap * turnMoves")
  if config.maxTurns != config.levelCount * config.levelTurnCap:
    raise newException(SokobanError,
      "maxTurns must equal levelCount * levelTurnCap")
  if config.maxTicks != config.maxTurns * config.turnMoves:
    raise newException(SokobanError,
      "maxTicks must equal maxTurns * turnMoves")
  if config.attempt1Ms mod 1000 != 0 or config.retryMs mod 1000 != 0:
    raise newException(SokobanError,
      "attempt1Ms and retryMs must be whole seconds: curl's CURLOPT_TIMEOUT " &
      "granularity is whole seconds, so a sub-second remainder is silently " &
      "floored and the deadline is not the one configured")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(SokobanError,
      "attempt1Ms + retryMs must fit inside turnBudgetMs")
  if config.wallClockBudgetSeconds <= 0:
    raise newException(SokobanError,
      "wallClockBudgetSeconds must be positive")
  if config.maxActionsPerTurn < 1:
    raise newException(SokobanError, "maxActionsPerTurn must be at least 1")

proc configJson*(config: GameConfig): JsonNode =
  ## The RESOLVED config, written into the replay header so the bytes are
  ## self-sufficient: a spectator holding the file can reconstruct the rules.
  var players = newJArray()
  for player in config.players:
    players.add(%*{"name": player.name})
  var slots = newJArray()
  for slot in config.slots:
    slots.add(%slot)
  var ladder = newJArray()
  var weights = newJArray()
  for tier in config.tierLadder:
    ladder.add(%($tier))
    weights.add(%TierWeights[tier])
  var bands = newJObject()
  for tier in Tier:
    bands[$tier] = %[TierBandMin[tier], TierBandMax[tier]]
  %*{
    "seed": config.seed,
    "variant": config.variant,
    "num_agents": config.numAgents,
    "gridSize": config.gridSize,
    "boxCount": config.boxCount,
    "levelCount": config.levelCount,
    "tierLadder": ladder,
    "tierWeights": weights,
    "tierBands": bands,
    "turnMoves": config.turnMoves,
    "levelTurnCap": config.levelTurnCap,
    "stepBudget": config.stepBudget,
    "maxTurns": config.maxTurns,
    "maxTicks": config.maxTicks,
    "parWeight": config.parWeight,
    "maxActionsPerTurn": config.maxActionsPerTurn,
    "macroPrimitiveCap": config.macroPrimitiveCap,
    "genNodeCap": config.genNodeCap,
    "genAttemptCap": config.genAttemptCap,
    "baselineNodeCap": config.baselineNodeCap,
    "players": players,
    "slots": slots,
    "fastMode": config.fastMode
  }

proc configFromJson*(payload: JsonNode): GameConfig =
  ## The inverse of `configJson` — what the replay runtime rebuilds the sim
  ## from.
  result = defaultConfig()
  result.update(payload)
