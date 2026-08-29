## The broadcast chrome frame: the JSON object the viewer's `onText` parses.
##
## Forked from the starter's `src/ctf/broadcast.nim`, retargeted field for
## field. The classic half (`t`/`mt`/`ph`/`sp`/`mx`/`st`/`en`/`teams`/`roster`)
## is kept EXACTLY as the starter shapes it, because `client/chrome_common.js`
## is inherited byte-for-byte and reads those names; everything this game adds
## rides under one namespaced key, `sok`, so it can never collide with a name
## the inherited chrome owns.

import std/[json, strutils]
import sim_types, sim, replay_runtime, labels

proc rosterJson*(sim: SimServer): JsonNode =
  ## One entry per seat, keyed by stable join slot. `name` is the SPECTATOR
  ## side — the real policy name — and `alias` is the in-game name.
  result = newJArray()
  for slot, seat in sim.seats:
    result.add(%*{
      "s": slot,
      "team": "red",
      "name": (if seat.name.len > 0: seat.name else: seat.policyLabel),
      "pol": (if seat.name.len > 0: seat.name else: seat.policyLabel),
      "col": 0,
      "alive": true,
      "lives": 0,
      "hp": 1,
      "carry": false,
      "k": 0, "d": 0, "cap": 0, "mk2": 0, "mk3": 0, "tk": 0,
      "alias": seat.alias,
      "seat": slot,
      "kind": seat.kind
    })

proc teamsJson*(sim: SimServer): JsonNode =
  ## ONE team, `red`, so the inherited scorebug builds exactly one plate — in
  ## `#plates-l`. `#plates-r` stays present but empty: it is one of the
  ## scorebug's three flex columns and removing it would un-centre `#clock`.
  var policies = newJArray()
  for seat in sim.seats:
    policies.add(%(if seat.name.len > 0: seat.name else: seat.policyLabel))
  %*{
    "red": {
      "lives": sim.levelsSolved(),
      "flag": "home",
      "carrier": -1,
      "prog": 0,
      "policies": policies
    }
  }

proc levelsJson(sim: SimServer): JsonNode =
  result = newJArray()
  for i, record in sim.levels:
    result.add(%*{
      "i": i,
      "tier": $record.tier,
      "opt": record.optPushes,
      "outcome": $(if record.outcome == loRunning: loRunning
                   else: record.outcome),
      "placed": record.boxesPlaced,
      "moves": record.moves,
      "turns": record.turns,
      "pushes": record.pushes,
      "relaxed": record.tierRelaxed
    })

proc boardJson(sim: SimServer): JsonNode =
  ## The board as the game block draws it: the ten XSB rows plus the dead-square
  ## list, so the inset can hatch the trap the cog is walking into.
  var rows = newJArray()
  if sim.levelActive:
    for row in sim.state.renderXsb():
      rows.add(%row)
  var dead = newJArray()
  if sim.levelActive:
    for cell in sim.level.dead.deadSquareList():
      dead.add(%[cellX(cell), cellY(cell)])
  %*{"rows": rows, "dead": dead}

proc feedJson(sim: SimServer): JsonNode =
  result = newJArray()
  for record in sim.feed:
    result.add(record)

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  startTick = 0,
  endHoldSeconds = 0,
  skipLulls = false,
  fastForwarding = false,
  lullSpans: seq[array[2, int]] = @[],
  parkedSeries: seq[array[2, int]] = @[],
  beats: seq[Beat] = @[],
  sendLead = false
): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE is always
  ## present, so even a frame reached by a seek hydrates the scorebug and the
  ## endcard with no events.
  var maxWeight = 0
  for tier in sim.config.tierLadder:
    maxWeight += TierWeights[tier]
  var state = %*{
    "t": sim.tick,
    "mt": sim.config.maxTicks,
    "ph": $sim.phase,
    "lob": sim.lobbyTicks div TargetFps,
    "pl": playing,
    "sp": speed,
    "mx": max(1, maxTick),
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": -1,
    "hold": endHoldSeconds,
    "teams": sim.teamsJson(),
    "roster": sim.rosterJson(),
    "events": (if events.isNil: newJArray() else: events)
  }
  state["sok"] = %*{
    "level": {
      "index": sim.levelIndex + 1,
      "of": sim.config.levelCount,
      "tier": (if sim.levelActive: $sim.level.tier else: ""),
      "tierLabel": (if sim.levelActive: tierLabel(sim.level.tier) else: ""),
      "opt": (if sim.levelActive: sim.level.optPushes else: 0),
      "move": sim.levelMove,
      "budget": sim.config.stepBudget,
      "pushes": sim.levelPushes,
      "placed": (if sim.levelActive: sim.state.boxesOnTargets() else: 0),
      "active": sim.levelActive
    },
    "levels": sim.levelsJson(),
    "board": sim.boardJson(),
    "solved": sim.levelsSolved(),
    "weight": sim.solvedWeight(),
    "maxWeight": maxWeight,
    "parWeight": sim.config.parWeight,
    "score": sim.episodeScore(),
    "boxCredit": sim.boxCredit(),
    "pushesTotal": sim.pushesTotal,
    "blockedMoves": sim.blockedMoves,
    "deadlocks": sim.deadlocks,
    "outOfSteps": sim.outOfSteps,
    "fallbackTurns": (block:
      var total = 0
      for seat in sim.seats: total += seat.fallbackTurns
      total),
    "alias": sim.seats[0].alias,
    "name": (if sim.seats[0].name.len > 0: sim.seats[0].name
             else: sim.seats[0].policyLabel),
    "kind": sim.seats[0].kind,
    "reason": $sim.reason,
    "endRule": $sim.endRule,
    "win": sim.episodeWin(),
    "feed": sim.feedJson()
  }
  if sendLead:
    # The full-episode series ships ONCE, on the first frame after the load-time
    # pre-scan: the progress sparkline, the scrubber beats and the lull shading
    # all draw at FULL WIDTH on the first frame instead of growing in.
    var points = newJArray()
    for point in parkedSeries:
      points.add(%[point[0], point[1]])
    state["lead"] = %*{"teams": ["red"], "pts": points}
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%[span[0], span[1]])
    state["lulls"] = spans
    var beatRows = newJArray()
    for beat in beats:
      beatRows.add(%*{"t": beat.tick, "k": beat.kind, "label": beat.label})
    # NOT `beats`: the inherited chrome's `ingestBeats` would turn that key into
    # unlabelled `<div>` markers. The game block reads `sok_beats` and draws
    # LABELLED, CLICKABLE BUTTONS instead.
    state["sok_beats"] = beatRows
  $state
