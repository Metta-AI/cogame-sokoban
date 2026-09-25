## Scripted player plans from the same public observation as any other policy.

import std/json
import baselines, deadlock, directives, grid, search

proc scriptedPlanForView*(view: JsonNode, kind: Baseline): Directive =
  var rows: seq[string]
  for row in view["board"]:
    rows.add(row.getStr())
  var state = parseXsb(rows)
  for box in view["boxes"]:
    let i = box["i"].getInt()
    state.boxes[i] = cellIndex(box["x"].getInt(), box["y"].getInt())
  scriptedPlan(kind, state, deadSquares(state.board), DefaultSearchParams,
               view["world"]["moves_per_turn"].getInt())
