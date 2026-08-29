## The board-label vocabulary contract.
##
## The starter's `labels.nim` deliberately scopes itself to what is DRAWN on the
## board, so the two-name-space rule is enforceable by a test:
## `tests/label_manifest.txt` lists every string this game can draw on the
## board, and `tests/test_sokoban_labels.nim` asserts the emitted set equals it.
##
## `showPlayerLabels` is false, as in the starter's paintball variant, so
## NOTHING DRAWN ON THE BOARD LEAKS AN IDENTITY: the cog's own alias is the
## only name the board can carry, and the real policy name lives spectator-side
## only (the scorebug plate, the endcard, `results.names`).

import std/strutils
import sim_types

const
  BoardLabels* = [
    "ALPHA",          ## the seat's in-game alias, and the only name on the board
    "DEAD SQUARES",   ## the repurposed inset's caption
    "U", "D", "L", "R"
  ]

proc boardLabelVocabulary*(): seq[string] =
  for label in BoardLabels:
    result.add(label)

proc tierLabel*(tier: Tier): string = ($tier).toUpperAscii()

proc outcomeLabel*(outcome: LevelOutcome): string =
  case outcome
  of loSolved: "SOLVED"
  of loDeadlocked: "DEADLOCKED"
  of loOutOfSteps: "OUT OF STEPS"
  of loUnreached: "UNREACHED"
  of loRunning: "IN PLAY"

proc deadlockLabel*(kind: DeadlockKind, x, y: int): string =
  ## The feed and banner line for the idea's own "deadlock created" marker.
  case kind
  of dkDeadSquare: "DEADLOCK CREATED — CRATE CORNERED AT (" & $x & "," & $y & ")"
  of dkFrozenBlock: "DEADLOCK CREATED — CRATES FROZEN AT (" & $x & "," & $y & ")"
  of dkNoPush: "DEADLOCK CREATED — NO PUSH LEFT AT (" & $x & "," & $y & ")"
  of dkNone: ""
