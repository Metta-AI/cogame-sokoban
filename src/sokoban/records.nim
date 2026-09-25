## Replay records for player plans and episode results.

import std/json
import sim_types, sim, directives

proc fallbackRecord*(turn, attempt: int, cause, detail: string): string =
  $(%*{"k": "fallback", "turn": turn, "attempt": attempt,
        "cause": cause, "detail": detail.truncateRunes(MaxFallbackDetailRunes)})

proc registerRecord*(
  slot: int, alias, name, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written: only
  ## the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register", "slot": slot, "alias": alias, "name": name,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind, "baseline": baseline
  })

proc directiveRecord*(
  sim: SimServer, directive: Directive, turn, slot: int, view: JsonNode
): string =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## `tools/replay_summary.py` and can never affect the simulation.
  var record = %*{
    "k": "directive",
    "turn": turn,
    "level": sim.levelIndex,
    "slot": slot,
    "alias": seatAlias(slot),
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "actions": directive.actionsJson(),
    "executed": sim.lastReport.executed,
    "pushes": sim.lastReport.pushes,
    "blocked": sim.lastReport.blocked,
    "truncated": sim.lastReport.truncated,
    "dropped": sim.lastReport.dropped,
    "unreachable": sim.lastReport.unreachable,
    "say": directive.say
  }
  if not view.isNil:
    # The observation MINUS `notes`, so the replay explains every decision.
    var mirrored = view.copy()
    if mirrored.hasKey("notes"):
      mirrored.delete("notes")
    record["view"] = mirrored
  boundedRecord(record, "say", "detail")

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what makes
  ## the replay SELF-SUFFICIENT: without it the outcome exists only at
  ## `COGAME_RESULTS_URI`.
  "{\"k\":\"result\",\"results\":" & $sim.ladderResultsJson() & "}"
