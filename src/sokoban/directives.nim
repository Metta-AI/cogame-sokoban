## The reply schema: what a policy (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and what happens to an entry that does not validate.
##
## Both policy kinds emit the SAME object through the SAME validator, which is
## what makes the bounded-orders test in `tests/test_sokoban_baselines.nim`
## meaningful.
##
## INVALID ACTIONS ARE DROPPED, NEVER REWRITTEN. In a game where one wrong push
## is fatal, repairing a malformed push into a different push would let the
## GAME lose the level on the policy's behalf. The entry is removed, counted,
## and reported back to the seat as `dropped`.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES and every truncation
## lands on a rune boundary. Slicing a string by BYTE index anywhere on the path
## to the replay is forbidden: a byte-truncated multi-byte character renders
## fine in a browser and then fails a strict UTF-8 parser.

import std/[json, strutils, unicode]
import sim_types

type
  ActionKind* = enum
    akMoves = "moves"
    akPush = "push"
    akGoto = "goto"
    akWait = "wait"

  Action* = object
    kind*: ActionKind
    seq*: string          ## moves: UDLR, upper-cased, <= 20
    box*: int             ## push: 0 .. 3, indexing the turn-start box order
    dir*: Dir             ## push
    times*: int           ## push: clamped 1 .. 8
    x*, y*: int           ## goto: clamped 0 .. 9

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  Directive* = object
    ## One seat's whole plan for one turn.
    actions*: seq[Action]
    say*: string          ## <= MaxSayRunes; drawn in the spectator feed
    notes*: string        ## <= MaxNoteRunes; echoed back to this seat only
    source*: DirectiveSource
    latencyMs*: int
    dropped*: int         ## entries that failed validation
    overCap*: int         ## entries past maxActionsPerTurn

  DirectiveError* = object of ValueError

proc sanitizeSay*(text: string): string =
  ## Capped at MaxSayRunes on a RUNE boundary first, then filtered to printable
  ## characters. Braces are excluded deliberately: the replay chat stream tells
  ## a control record from a cog's line by a leading `{`.
  result = ""
  for rune in text.replace("\n", " ").replace("\r", " ")
      .truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value == ord('{') or value == ord('}'):
      continue
    if value >= 32 and value != 127:
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The private scratchpad, as it reaches the replay and next turn's
  ## observation. Newlines collapse so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is what
  ## recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readInt(node: JsonNode): tuple[ok: bool, value: int] =
  ## An int, a float, or a numeric string. Anything non-finite or unparseable
  ## reports `ok = false` so the caller DROPS the entry rather than inventing a
  ## move.
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt: (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0)
    else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else: (false, 0)

proc parseAction*(node: JsonNode): tuple[ok: bool, action: Action] =
  ## One entry, validated against the schema. `ok = false` means DROP.
  if node.isNil or node.kind != JObject:
    return (false, Action())
  let doText = node{"do"}.getStr().truncateRunes(MaxActionDoRunes)
    .strip().toLowerAscii()
  var kind: ActionKind
  ## The enum is exactly the four verbs the reply schema and `docs/ACTIONS.md`
  ## declare, lower-cased before matching. Nothing else is accepted: a wider
  ## domain than the contract is a domain a policy author is never told about,
  ## and an ABSENT `do` used to become a `wait` here — inventing an action out
  ## of an entry that does not validate, which is exactly what the "drop,
  ## never rewrite" rule exists to prevent.
  case doText
  of "moves": kind = akMoves
  of "push": kind = akPush
  of "goto": kind = akGoto
  of "wait": kind = akWait
  else: return (false, Action())
  var action = Action(kind: kind, times: 1)
  case kind
  of akMoves:
    let raw = node{"seq"}.getStr().truncateRunes(MaxActionSeqRunes)
    if raw.len == 0:
      return (false, Action())
    for ch in raw:
      case ch
      of 'U', 'u': action.seq.add('U')
      of 'D', 'd': action.seq.add('D')
      of 'L', 'l': action.seq.add('L')
      of 'R', 'r': action.seq.add('R')
      else: return (false, Action())
  of akPush:
    let box = readInt(node{"box"})
    if not box.ok or box.value < 0 or box.value >= BoxCount:
      return (false, Action())
    action.box = box.value
    let dir = parseDir(node{"dir"}.getStr().truncateRunes(MaxActionDirRunes))
    if not dir.ok:
      return (false, Action())
    action.dir = dir.dir
    let times = readInt(node{"times"})
    action.times = if times.ok: clamp(times.value, 1, 8) else: 1
  of akGoto:
    let
      x = readInt(node{"x"})
      y = readInt(node{"y"})
    if not x.ok or not y.ok:
      return (false, Action())
    action.x = clamp(x.value, 0, GridSize - 1)
    action.y = clamp(y.value, 0, GridSize - 1)
  of akWait:
    discard
  (true, action)

proc parseDirective*(payload: JsonNode, maxActions: int): Directive =
  ## Turns one parsed reply into a legal directive. A reply with a valid `say`
  ## but no `actions` is USABLE — the turn is spent waiting and the narration is
  ## delivered. A reply that is not a JSON object is a parse failure.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result.source = dsLlm
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeNote(payload{"notes"}.getStr())
  let node = payload{"actions"}
  if node.isNil or node.kind != JArray:
    return
  for item in node.items:
    if result.actions.len >= max(0, maxActions):
      inc result.overCap
      continue
    let parsed = parseAction(item)
    if not parsed.ok:
      inc result.dropped
      continue
    result.actions.add(parsed.action)

proc actionJson*(action: Action): JsonNode =
  case action.kind
  of akMoves: %*{"do": "moves", "seq": action.seq}
  of akPush: %*{"do": "push", "box": action.box, "dir": $action.dir,
                "times": action.times}
  of akGoto: %*{"do": "goto", "x": action.x, "y": action.y}
  of akWait: %*{"do": "wait"}

proc actionsJson*(directive: Directive): JsonNode =
  result = newJArray()
  for action in directive.actions:
    result.add(action.actionJson())

proc boundedRecord*(record: JsonNode, sayKey, notesKey: string): string =
  ## The serialized record, guaranteed <= MaxDirectiveRunes. The free text is
  ## what shrinks; the cut still lands on a rune boundary. NEVER cut the
  ## serialized string — that would emit broken JSON, which is the exact failure
  ## the rune rule exists to prevent.
  result = $record
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    for key in [sayKey, notesKey]:
      if record.hasKey(key):
        let current = record[key].getStr()
        record[key] = %current.truncateRunes(
          max(0, current.runeLen - max(8, current.runeLen div 2)))
    result = $record
