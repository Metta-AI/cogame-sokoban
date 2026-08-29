## The tier-2 analysis stream written to `COGAME_EVENTS_URI`.
##
## The starter's JSON-lines `eventsJsonl` contract, kept — including the
## MANDATORY trailing summary row. `Move` is the per-tick row that makes this
## stream a full action trace for `cogamer-rl`: up to 1 200 rows an episode,
## which the replay deliberately does not carry.

import std/[json, strutils]
import sim_types

type
  SimEventKind* = enum
    seLevelStart = "LevelStart"
    seTurnStart = "TurnStart"
    seDirective = "Directive"
    seFallback = "Fallback"
    seMove = "Move"
    sePush = "Push"
    seBoxOn = "BoxOn"
    seBoxOff = "BoxOff"
    seDeadlock = "Deadlock"
    seSolved = "Solved"
    seFailed = "Failed"

  EventLog* = ref object
    rows*: seq[string]
    enabled*: bool

proc newEventLog*(enabled = true): EventLog =
  EventLog(enabled: enabled)

proc add*(log: EventLog, kind: SimEventKind, tick: int, payload: JsonNode) =
  if not log.enabled:
    return
  var row = payload
  if row.isNil or row.kind != JObject:
    row = newJObject()
  row["type"] = %($kind)
  row["tick"] = %tick
  log.rows.add($row)

proc eventsJsonl*(log: EventLog, ticks: int): string =
  ## The stream plus the mandatory trailing summary row.
  for row in log.rows:
    result.add(row)
    result.add("\n")
  result.add($(%*{
    "type": "summary",
    "ticks": ticks,
    "events": log.rows.len,
    "gameVersion": GameVersion
  }))
  result.add("\n")

proc eventKindNames*(): seq[string] =
  for kind in SimEventKind:
    result.add($kind)

proc summaryRow*(text: string): bool =
  text.contains("\"type\":\"summary\"")
