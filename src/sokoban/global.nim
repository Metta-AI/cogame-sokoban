## The sprite-protocol compositor: the board, as bytes the inherited
## `client/broadcast_core.js` composites.
##
## Forked from the starter's `src/ctf/global.nim`, with its three named edits:
##
## 1. THE BOARD IS A 10 x 10 CELL GRID, NOT A PIXEL ARENA. Placements are
##    cell-space coordinates scaled by `CellPixels`; the raycast fov cache and
##    the shadowcasting are DELETED OUTRIGHT — this game is perfect information
##    and there is nothing to occlude.
## 2. CRATE AND MARKED-SQUARE POOLS. `CrateBase` (sized to 4) is filled in
##    ascending `(y, x)` and emitted incrementally like the starter's other
##    object families; the marked squares and the static dead-square mask are
##    baked into the level bed and sent once at `levelstart`.
## 3. BAKED ROOM BED. `data/arena_floor.png` is tiled and darkened at install
##    with pixie, exactly the way the starter bakes endzone paint, and the floor
##    grain, the cell gridlines, the wall bevels, the marked squares and the
##    dead-square hatch are baked onto it ONCE PER LEVEL — so the per-frame cost
##    is the cog and four crates.

import std/[json, os, strutils]
import pixie
import bitworld/spriteprotocol
import sim_types, grid, sim

const
  MapLayerId = 0
  MapLayerType = 0
  ZoomableLayerFlag = 1

  BedSpriteId = 10
  CrateSpriteId = 20
  CrateParkedSpriteId = 21
  CogSpriteBase = 30        ## + ord(Dir): down/up/left/right

  BedObjectId = 40          ## 40..99 with z = -32768 is broadcast_core.js's
  StaticBandZ = -32768      ## static-band cache window; the bed never moves.
  CrateObjectBase = 200
  CogObjectId = 260

type
  GlobalViewerState* = object
    ## What one viewer has been told. `nextState` is threaded through every
    ## packet build so a redefinition is emitted only when something changed.
    bedLevel*: int
    spritesSent*: bool
    leadSent*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    crateCells*: array[BoxCount, int]
    cogCell*: int
    cogFacing*: Dir
    initialised*: bool

proc initGlobalViewerState*(): GlobalViewerState =
  GlobalViewerState(bedLevel: -1, replaySeekTick: -1, cogCell: -1)

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies the viewer's client messages. Whole-string commands (`s:<tick>`)
  ## are intercepted before the legacy char-by-char transport path, so a
  ## multi-digit tick is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    else:
      discard

# ---------------------------------------------------------------------------
#  Art
# ---------------------------------------------------------------------------

var
  artLoaded = false
  floorTile: Image
  wallTileH: Image
  wallTileV: Image
  crateImage: Image
  crateParkedImage: Image
  cogImages: array[4, Image]

proc dataPath(name: string): string =
  ## The wasm bundle preloads `data@data`, and the native image copies `data/`
  ## into its workdir, so one relative path serves both.
  if fileExists(name): name
  else: "/" & name

proc loadArt() =
  if artLoaded:
    return
  artLoaded = true
  floorTile = readImage(dataPath("data/arena_floor.png"))
  wallTileH = readImage(dataPath("data/art/wall_h.jpg"))
  wallTileV = readImage(dataPath("data/art/wall_v.jpg"))
  crateImage = readImage(dataPath("data/art/crate.png")).resize(
    CellPixels, CellPixels)
  crateParkedImage = readImage(dataPath("data/art/crate_parked.png")).resize(
    CellPixels, CellPixels)
  for i, name in ["cog_up.png", "cog_down.png", "cog_left.png",
                  "cog_right.png"]:
    # Index by ord(Dir): U, D, L, R.
    cogImages[i] = readImage(dataPath("data/art/" & name)).resize(
      CellPixels, CellPixels)

proc imageToStraightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc shade(image: Image, x, y: int, r, g, b, a: int) {.inline.} =
  if x < 0 or y < 0 or x >= image.width or y >= image.height:
    return
  let existing = image[x, y].rgba()
  let alpha = clamp(a, 0, 255)
  proc mix(src, dst: int): uint8 =
    uint8(clamp((src * alpha + dst * (255 - alpha)) div 255, 0, 255))
  image[x, y] = rgba(
    mix(r, int(existing.r)), mix(g, int(existing.g)), mix(b, int(existing.b)),
    255'u8)

proc bakeBed(sim: SimServer): Image =
  ## One pixie bake per level: the tiled and darkened floor, the baked cell
  ## gridlines, the bevelled masonry walls, the recessed amber marked squares
  ## and the dead-square hatch.
  loadArt()
  result = newImage(BoardPixels, BoardPixels)
  # Floor: tile the starter's arena floor and darken it 30 %.
  var tile = floorTile
  if tile.width < 1 or tile.height < 1:
    tile = newImage(8, 8)
  for y in 0 ..< BoardPixels:
    for x in 0 ..< BoardPixels:
      let c = tile[x mod tile.width, y mod tile.height].rgba()
      result[x, y] = rgba(
        uint8(int(c.r) * 7 div 10), uint8(int(c.g) * 7 div 10),
        uint8(int(c.b) * 7 div 10), 255'u8)
  # Cell gridlines, in the palette's paper at a whisper.
  for i in 0 .. GridSize:
    let p = min(i * CellPixels, BoardPixels - 1)
    for q in 0 ..< BoardPixels:
      result.shade(p, q, 242, 232, 216, 26)
      result.shade(q, p, 242, 232, 216, 26)
  # Walls: cut from the starter's masonry, with a baked bevel so a wall run
  # reads as stone rather than a black bar.
  for cell in 0 ..< GridCells:
    if not sim.state.board.wall[cell]:
      continue
    let
      ox = cellX(cell) * CellPixels
      oy = cellY(cell) * CellPixels
      source = if cellY(cell) == 0 or cellY(cell) == GridSize - 1: wallTileH
               else: wallTileV
    for y in 0 ..< CellPixels:
      for x in 0 ..< CellPixels:
        let c = source[(ox + x) mod source.width,
                       (oy + y) mod source.height].rgba()
        result[ox + x, oy + y] = rgba(c.r, c.g, c.b, 255'u8)
    for k in 0 ..< 3:
      for x in 0 ..< CellPixels:
        result.shade(ox + x, oy + k, 255, 255, 255, 46)
        result.shade(ox + x, oy + CellPixels - 1 - k, 0, 0, 0, 70)
      for y in 0 ..< CellPixels:
        result.shade(ox + k, oy + y, 255, 255, 255, 30)
        result.shade(ox + CellPixels - 1 - k, oy + y, 0, 0, 0, 70)
  # Marked squares: recessed amber diamonds inlaid in the floor.
  for cell in 0 ..< GridCells:
    if not sim.state.board.target[cell]:
      continue
    let
      ox = cellX(cell) * CellPixels
      oy = cellY(cell) * CellPixels
      half = CellPixels div 2
    for y in 0 ..< CellPixels:
      for x in 0 ..< CellPixels:
        let d = abs(x - half) + abs(y - half)
        if d < half - 6:
          result.shade(ox + x, oy + y, 232, 163, 61, 200)
        elif d < half - 3:
          result.shade(ox + x, oy + y, 120, 82, 26, 220)
  # The dead-square wash: a 45 degree hatch in the palette's reds, so a
  # spectator can SEE the trap before the cog walks into it.
  for cell in 0 ..< GridCells:
    if not sim.level.dead[cell] or sim.state.board.wall[cell]:
      continue
    let
      ox = cellX(cell) * CellPixels
      oy = cellY(cell) * CellPixels
    for y in 0 ..< CellPixels:
      for x in 0 ..< CellPixels:
        if (x + y) mod 8 < 3:
          result.shade(ox + x, oy + y, 224, 82, 58, 46)

# ---------------------------------------------------------------------------
#  Packets
# ---------------------------------------------------------------------------

proc addSpriteImage(packet: var seq[uint8], spriteId: int, image: Image) =
  packet.addSprite(spriteId, image.width, image.height,
                   image.imageToStraightRgba())

proc buildSpriteProtocolInit*(): seq[uint8] =
  ## Layer + viewport. The board is a FIXED 10 x 10 grid with no off-frame
  ## area, so there is exactly one zoomable map layer and no minimap.
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, BoardPixels, BoardPixels)

proc facingFor(previous: int, current: int, fallback: Dir): Dir =
  ## The cog faces the way it last moved; a cog that has not moved keeps its
  ## last facing.
  if previous < 0 or previous == current:
    return fallback
  let
    dx = cellX(current) - cellX(previous)
    dy = cellY(current) - cellY(previous)
  if dy < 0: dirUp
  elif dy > 0: dirDown
  elif dx < 0: dirLeft
  elif dx > 0: dirRight
  else: fallback

proc buildViewerPacket*(
  sim: SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  chrome: string
): seq[uint8] =
  ## One presentation frame: the layer/viewport on the first packet, the level
  ## bed whenever the level changes, the four crates and the cog every frame
  ## (the client re-describes only what moved), and the chrome JSON smuggled as
  ## the label of the reserved 1 x 1 sprite.
  nextState = state
  if not state.initialised:
    result.add(buildSpriteProtocolInit())
    nextState.initialised = true
  if sim.levelActive and state.bedLevel != sim.levelIndex:
    result.addSpriteImage(BedSpriteId, sim.bakeBed())
    result.addObject(BedObjectId, 0, 0, StaticBandZ, MapLayerId, BedSpriteId)
    nextState.bedLevel = sim.levelIndex
  if not state.spritesSent:
    loadArt()
    result.addSpriteImage(CrateSpriteId, crateImage)
    result.addSpriteImage(CrateParkedSpriteId, crateParkedImage)
    for i in 0 .. 3:
      result.addSpriteImage(CogSpriteBase + i, cogImages[i])
    nextState.spritesSent = true
  if sim.levelActive:
    for i, cell in sim.state.boxes:
      let sprite = if sim.state.board.target[cell]: CrateParkedSpriteId
                   else: CrateSpriteId
      result.addObject(CrateObjectBase + i, cellX(cell) * CellPixels,
                       cellY(cell) * CellPixels, cellY(cell) * 4,
                       MapLayerId, sprite)
      nextState.crateCells[i] = cell
    let facing = facingFor(state.cogCell, sim.state.player, state.cogFacing)
    result.addObject(CogObjectId, cellX(sim.state.player) * CellPixels,
                     cellY(sim.state.player) * CellPixels,
                     cellY(sim.state.player) * 4 + 2, MapLayerId,
                     CogSpriteBase + ord(facing))
    nextState.cogCell = sim.state.player
    nextState.cogFacing = facing
  result.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chrome)

proc boardAspect*(): float = 1.0
