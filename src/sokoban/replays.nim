## The binary `COWLDSOK` replay codec.
##
## Forked from the starter's `src/ctf/replays.nim`: magic + format version +
## game name/version header, the RESOLVED config JSON, then the record stream
## and one `gameHash` per tick. This game's ONLY inputs are the per-turn plans,
## so the record stream is tiny and the whole episode re-derives from it.
##
## THE LEVEL GRIDS ARE RECORDED, NOT REGENERATED. A deliberate divergence from
## cogame-minigrid, which re-runs its generators in wasm: here the generator is
## a bounded BFS costing hundreds of milliseconds per level, and paying that on
## viewer load would delay the first drawn frame for no benefit. Six levels x
## (10 rows + ~40 dead-square pairs) is about 1.5 KB.
##
## THE WALL-CLOCK STOP IS A LOAD-BEARING RECORD, not an inference. A wall-clock
## fact cannot be re-derived from sim state, so the stop is written as one
## record applied by the SAME proc on record and on playback (the
## particle-worlds 2026-08-26 scar).

import std/json
import sim_types, grid, levelgen, directives

const
  SokobanReplayMagic* = "COWLDSOK"
  ReplayFormatVersion* = 1

type
  RecordKind* = enum
    rkLevel = 1
    rkPlan = 2
    rkChat = 3
    rkStop = 4

  PlanRecord* = object
    turn*: int
    level*: int
    source*: DirectiveSource
    actions*: seq[Action]
    say*: string
    notes*: string

  LevelPayload* = object
    index*: int
    tier*: Tier
    optPushes*: int
    tierRelaxed*: bool
    rows*: seq[string]
    dead*: seq[int]

  StopRecord* = object
    tick*: int
    reason*: EndReason
    endRule*: EndRule
    detail*: string

  ReplayRecord* = object
    kind*: RecordKind
    tick*: int
    level*: LevelPayload
    plan*: PlanRecord
    chat*: string
    stop*: StopRecord

  ReplayData* = object
    gameName*: string
    gameVersion*: string
    protocol*: string
    config*: JsonNode
    records*: seq[ReplayRecord]
    hashes*: seq[uint64]

# ---------------------------------------------------------------------------
#  Little-endian primitives
# ---------------------------------------------------------------------------

proc addU8(bytes: var string, value: int) =
  bytes.add(char(value and 0xFF))

proc addU16(bytes: var string, value: int) =
  bytes.add(char(value and 0xFF))
  bytes.add(char((value shr 8) and 0xFF))

proc addU32(bytes: var string, value: int) =
  for shift in [0, 8, 16, 24]:
    bytes.add(char((value shr shift) and 0xFF))

proc addU64(bytes: var string, value: uint64) =
  for shift in 0 ..< 8:
    bytes.add(char(int((value shr (shift * 8)) and 0xFF'u64)))

proc addText(bytes: var string, text: string) =
  bytes.addU32(text.len)
  bytes.add(text)

type Cursor = object
  data: string
  offset: int

proc need(cursor: var Cursor, count: int) =
  if cursor.offset + count > cursor.data.len:
    raise newException(SokobanError, "replay truncated")

proc readU8(cursor: var Cursor): int =
  cursor.need(1)
  result = int(uint8(cursor.data[cursor.offset]))
  inc cursor.offset

proc readU16(cursor: var Cursor): int =
  cursor.need(2)
  result = int(uint8(cursor.data[cursor.offset])) or
    (int(uint8(cursor.data[cursor.offset + 1])) shl 8)
  cursor.offset += 2

proc readU32(cursor: var Cursor): int =
  cursor.need(4)
  for shift in [0, 8, 16, 24]:
    result = result or (int(uint8(cursor.data[cursor.offset])) shl shift)
    inc cursor.offset

proc readU64(cursor: var Cursor): uint64 =
  cursor.need(8)
  for shift in 0 ..< 8:
    result = result or (uint64(uint8(cursor.data[cursor.offset])) shl
      (shift * 8))
    inc cursor.offset

proc readText(cursor: var Cursor): string =
  let length = cursor.readU32()
  cursor.need(length)
  result = cursor.data[cursor.offset ..< cursor.offset + length]
  cursor.offset += length

# ---------------------------------------------------------------------------
#  Writing
# ---------------------------------------------------------------------------

type ReplayWriter* = ref object
  header*: string
  body*: string
  hashes*: seq[uint64]

proc newReplayWriter*(config: JsonNode): ReplayWriter =
  result = ReplayWriter()
  result.header.add(SokobanReplayMagic)
  result.header.addU16(ReplayFormatVersion)
  result.header.addText(GameName)
  result.header.addText(GameVersion)
  result.header.addText(ProtocolName)
  result.header.addText($config)

proc writeLevel*(writer: ReplayWriter, tick: int, payload: LevelPayload) =
  writer.body.addU8(ord(rkLevel))
  writer.body.addU32(tick)
  writer.body.addU16(payload.index)
  writer.body.addText($payload.tier)
  writer.body.addU16(payload.optPushes)
  writer.body.addU8(if payload.tierRelaxed: 1 else: 0)
  writer.body.addU16(payload.rows.len)
  for row in payload.rows:
    writer.body.addText(row)
  writer.body.addU16(payload.dead.len)
  for cell in payload.dead:
    writer.body.addU16(cell)

proc writePlan*(writer: ReplayWriter, tick: int, plan: PlanRecord) =
  writer.body.addU8(ord(rkPlan))
  writer.body.addU32(tick)
  writer.body.addU16(plan.turn)
  writer.body.addU16(plan.level)
  writer.body.addU8(ord(plan.source))
  writer.body.addU16(plan.actions.len)
  for action in plan.actions:
    writer.body.addU8(ord(action.kind))
    writer.body.addText(action.seq)
    writer.body.addU8(action.box)
    writer.body.addU8(ord(action.dir))
    writer.body.addU8(action.times)
    writer.body.addU8(action.x)
    writer.body.addU8(action.y)
  writer.body.addText(plan.say)
  writer.body.addText(plan.notes)

proc writeChat*(writer: ReplayWriter, tick: int, record: string) =
  writer.body.addU8(ord(rkChat))
  writer.body.addU32(tick)
  writer.body.addText(record)

proc writeStop*(writer: ReplayWriter, stop: StopRecord) =
  writer.body.addU8(ord(rkStop))
  writer.body.addU32(stop.tick)
  writer.body.addText($stop.reason)
  writer.body.addText($stop.endRule)
  writer.body.addText(stop.detail)

proc writeHash*(writer: ReplayWriter, value: uint64) =
  writer.hashes.add(value)

proc bytes*(writer: ReplayWriter): string =
  result = writer.header
  result.addU32(writer.body.len)
  result.add(writer.body)
  result.addU32(writer.hashes.len)
  for value in writer.hashes:
    result.addU64(value)

# ---------------------------------------------------------------------------
#  Reading
# ---------------------------------------------------------------------------

proc parseReplayBytes*(data: string): ReplayData =
  var cursor = Cursor(data: data, offset: 0)
  cursor.need(SokobanReplayMagic.len)
  if data[0 ..< SokobanReplayMagic.len] != SokobanReplayMagic:
    raise newException(SokobanError, "not a " & SokobanReplayMagic & " replay")
  cursor.offset = SokobanReplayMagic.len
  let format = cursor.readU16()
  if format != ReplayFormatVersion:
    raise newException(SokobanError,
      "replay format version " & $format & " is not supported")
  result.gameName = cursor.readText()
  result.gameVersion = cursor.readText()
  result.protocol = cursor.readText()
  result.config = parseJson(cursor.readText())
  let bodyLength = cursor.readU32()
  let bodyEnd = cursor.offset + bodyLength
  while cursor.offset < bodyEnd:
    var record: ReplayRecord
    let kind = cursor.readU8()
    if kind < ord(low(RecordKind)) or kind > ord(high(RecordKind)):
      raise newException(SokobanError, "unknown replay record kind " & $kind)
    record.kind = RecordKind(kind)
    record.tick = cursor.readU32()
    case record.kind
    of rkLevel:
      record.level.index = cursor.readU16()
      let tier = parseTier(cursor.readText())
      if not tier.ok:
        raise newException(SokobanError, "unknown tier in replay level record")
      record.level.tier = tier.tier
      record.level.optPushes = cursor.readU16()
      record.level.tierRelaxed = cursor.readU8() != 0
      let rows = cursor.readU16()
      for _ in 0 ..< rows:
        record.level.rows.add(cursor.readText())
      let dead = cursor.readU16()
      for _ in 0 ..< dead:
        record.level.dead.add(cursor.readU16())
    of rkPlan:
      record.plan.turn = cursor.readU16()
      record.plan.level = cursor.readU16()
      record.plan.source = DirectiveSource(cursor.readU8())
      let actions = cursor.readU16()
      for _ in 0 ..< actions:
        var action: Action
        action.kind = ActionKind(cursor.readU8())
        action.seq = cursor.readText()
        action.box = cursor.readU8()
        action.dir = Dir(cursor.readU8())
        action.times = cursor.readU8()
        action.x = cursor.readU8()
        action.y = cursor.readU8()
        record.plan.actions.add(action)
      record.plan.say = cursor.readText()
      record.plan.notes = cursor.readText()
    of rkChat:
      record.chat = cursor.readText()
    of rkStop:
      record.stop.tick = record.tick
      let reason = cursor.readText()
      var parsedReason = endComplete
      for value in EndReason:
        if $value == reason:
          parsedReason = value
      record.stop.reason = parsedReason
      let rule = cursor.readText()
      var parsedRule = erLadderComplete
      for value in EndRule:
        if $value == rule:
          parsedRule = value
      record.stop.endRule = parsedRule
      record.stop.detail = cursor.readText()
    result.records.add(record)
  cursor.offset = bodyEnd
  let hashCount = cursor.readU32()
  for _ in 0 ..< hashCount:
    result.hashes.add(cursor.readU64())

proc levelFromPayload*(payload: LevelPayload): Level =
  ## Rebuilds a `Level` from the recorded rows. NO GENERATOR CALL AND NO FETCH:
  ## this is what the wasm viewer re-simulates from.
  result.state = parseXsb(payload.rows)
  result.tier = payload.tier
  result.optPushes = payload.optPushes
  result.tierRelaxed = payload.tierRelaxed
  for cell in payload.dead:
    if cell >= 0 and cell < GridCells:
      result.dead[cell] = true

proc chatRecords*(replay: ReplayData): seq[JsonNode] =
  for record in replay.records:
    if record.kind != rkChat:
      continue
    try:
      result.add(parseJson(record.chat))
    except CatchableError:
      discard
