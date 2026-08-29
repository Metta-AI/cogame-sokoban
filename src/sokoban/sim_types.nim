## Sokoban — the shared types, the wire caps and the game constants.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_types.nim`: the `GameVersion`
## prepend-only changelog discipline, `TargetFps`, and the RUNE caps that every
## recorded string is truncated against are that file's, because they are what
## keeps a replay parseable by a strict UTF-8 reader.
##
## GameVersion changelog — PREPEND ONLY, one line per bump:
##   "1"  first release: 10x10 four-crate Sokoban, six-level tier ladder.
##
## Everything in this module is INTEGER. There is no floating point anywhere in
## the sim (`tests/test_sokoban_sim.nim` greps for it), which is what makes the
## native <-> wasm hash chain exact by construction.

import std/[strutils, unicode]

const
  GameVersion* = "1"
    ## Bumped whenever a recorded replay's meaning changes. Committed fixtures
    ## carry it and `tools/ci/check_gameversion.sh` refuses a bump without a
    ## changelog line above.

  ProtocolName* = "sokoban/v1"
  GameName* = "sokoban"

  TargetFps* = 24
    ## Sim ticks per second. The chrome's clock divides by this.

  GridSize* = 10
    ## The board is ALWAYS 10 x 10 — gym-sokoban's and Boxoban's own size. The
    ## whole border ring is wall, so the playable interior is 8 x 8 = 64 cells.
  GridCells* = GridSize * GridSize
  BoxCount* = 4
    ## Crates, and marked squares: Boxoban's own count. Never configurable.

  MaxSayRunes* = 140
    ## The cog thinking out loud. RE-PINNED in this fork: the starter's
    ## `MaxSayRunes = ShoutMaxChars = 10` is an in-world shout; a cog narrating
    ## a puzzle needs a sentence.
  MaxNoteRunes* = 320
    ## The private scratchpad echoed back to this seat next turn. Sized for a
    ## four-crate push order plus the forbidden pushes.
  MaxPromptRunes* = 4000     ## PLAYER_PROMPT, at registration.
  MaxPolicyLabelRunes* = 64
  MaxFallbackDetailRunes* = 200
  MaxStopDetailRunes* = 200
  MaxDirectiveRunes* = 6000  ## the serialized `directive` replay record.
  MaxReplyBytes* = 4096      ## bytes read from the provider before parsing.
  MaxActionSeqRunes* = 20
  MaxActionDoRunes* = 6
  MaxActionDirRunes* = 5

  PlaybackSpeeds* = [1, 2, 4, 8]
    ## The chrome's speed chips. chrome_common.js maps a speed to a transport
    ## command char through a fixed table, so these must be drawn from
    ## {1,2,3,4,8,16}.
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 never-drawn sprite whose LABEL carries the broadcast chrome
    ## JSON. Smuggling the chrome through the same binary channel the board
    ## rides is what makes it survive a hosted replay.

  CellPixels* = 48
    ## Board pixels per grid cell in the emitted sprite protocol frame. 10 x 10
    ## cells => a 480 x 480 board, aspect exactly 1.000.
  BoardPixels* = GridSize * CellPixels

type
  Dir* = enum
    ## The four primitives, in the fixed order every tie-break in this game
    ## uses. Never reorder: `pushes_available`, the walk BFS, the generator and
    ## both baselines all break ties on this order.
    dirUp = "U"
    dirDown = "D"
    dirLeft = "L"
    dirRight = "R"

  Tier* = enum
    tierUnfiltered = "unfiltered"
    tierMedium = "medium"
    tierHard = "hard"

  LevelOutcome* = enum
    loRunning = "running"
    loSolved = "solved"
    loDeadlocked = "deadlocked"
    loOutOfSteps = "outofsteps"
    loUnreached = "unreached"

  DeadlockKind* = enum
    dkNone = "none"
    dkDeadSquare = "dead_square"
    dkFrozenBlock = "frozen_block"
    dkNoPush = "no_push"

  EndRule* = enum
    erLadderComplete = "ladderComplete"
    erTurnCap = "turnCap"
    erWallClock = "wallClock"
    erFault = "fault"

  EndReason* = enum
    ## The starter's closed enum. Exactly these three values are legal.
    endComplete = "complete"
    endDeadline = "deadline"
    endFault = "fault"

  Phase* = enum
    phLobby = "lobby"
    phPlaying = "playing"
    phGameOver = "gameover"

  SokobanError* = object of CatchableError

  PlayerSpec* = object
    name*: string

  GameConfig* = object
    ## The resolved episode configuration. Every field is also a
    ## `game.config_schema` property in `coworld_manifest_template.json`, and
    ## `tests/test_sokoban_manifest.nim` asserts that every variant's
    ## `game_config` constructs one of these.
    players*: seq[PlayerSpec]
    slots*: seq[int]
    tokens*: seq[string]
    seed*: int64
    numAgents*: int
    minPlayers*: int
    gridSize*: int
    boxCount*: int
    levelCount*: int
    tierLadder*: seq[Tier]
    turnMoves*: int
    levelTurnCap*: int
    stepBudget*: int
    maxTurns*: int
    maxTicks*: int
    parWeight*: int
    maxActionsPerTurn*: int
    macroPrimitiveCap*: int
    genNodeCap*: int
    genAttemptCap*: int
    baselineNodeCap*: int
    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int
    variant*: string

const
  Dirs* = [dirUp, dirDown, dirLeft, dirRight]
  TierWeights*: array[Tier, int] = [1, 2, 3]
  TierBandMin*: array[Tier, int] = [6, 13, 23]
  TierBandMax*: array[Tier, int] = [12, 22, 34]

proc dirDelta*(d: Dir): tuple[dx, dy: int] =
  ## U is y-1, D is y+1, L is x-1, R is x+1. `(0, 0)` is the north-west corner.
  case d
  of dirUp: (0, -1)
  of dirDown: (0, 1)
  of dirLeft: (-1, 0)
  of dirRight: (1, 0)

proc parseDir*(text: string): tuple[ok: bool, dir: Dir] =
  ## Case-insensitive, and the long spellings a model actually emits.
  case text.strip().toLowerAscii()
  of "u", "up", "north", "n": (true, dirUp)
  of "d", "down", "south", "s": (true, dirDown)
  of "l", "left", "west", "w": (true, dirLeft)
  of "r", "right", "east", "e": (true, dirRight)
  else: (false, dirUp)

proc parseTier*(text: string): tuple[ok: bool, tier: Tier] =
  for tier in Tier:
    if $tier == text:
      return (true, tier)
  (false, tierUnfiltered)

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single place
  ## any recorded string is shortened. Byte truncation is what makes a replay
  ## that renders in a browser fail a strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc defaultTierLadder*(): seq[Tier] =
  @[tierUnfiltered, tierUnfiltered, tierMedium, tierMedium, tierHard, tierHard]

proc defaultConfig*(): GameConfig =
  ## The `ladder` variant's numbers, which are also every test's starting
  ## point. `sim_config.update` overwrites them from the runner's JSON.
  GameConfig(
    players: @[PlayerSpec(name: "Alpha")],
    slots: @[],
    tokens: @[],
    seed: 1,
    numAgents: 1,
    minPlayers: 1,
    gridSize: GridSize,
    boxCount: BoxCount,
    levelCount: 6,
    tierLadder: defaultTierLadder(),
    turnMoves: 20,
    levelTurnCap: 10,
    stepBudget: 200,
    maxTurns: 60,
    maxTicks: 1200,
    parWeight: 5,
    maxActionsPerTurn: 8,
    macroPrimitiveCap: 32,
    genNodeCap: 200_000,
    genAttemptCap: 8,
    baselineNodeCap: 8,
    attempt1Ms: 6000,
    retryMs: 3000,
    turnBudgetMs: 9000,
    turnSpacingMs: 2600,
    wallClockBudgetSeconds: 690,
    lobbyJoinTimeoutTicks: 2400,
    gameOverTicks: 96,
    fastMode: true,
    showPlayerLabels: false,
    model: "",
    maxOutputTokens: 900,
    variant: "ladder"
  )
