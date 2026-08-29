## Sweeps the scripted baselines' tunables and records the pick.
##
## Like the starter's `DefaultBaselineParams`, `pusher`'s tunables are a
## parameter object CHOSEN BY A SWEEP, not guessed: the node cap, the `h`
## matching rule and the `f` tie-break. The sweep's pick is written to
## `tools/ci/baseline_tuning.json` and `tests/test_sokoban_tuning.nim` asserts
## the shipped defaults still equal it.
##
##   nim r --path:src tools/tune_baselines.nim            # sweep and write
##   nim r --path:src tools/tune_baselines.nim --check    # assert, do not write
##
## The objective is the design note's own band (§Tests, test 25): `pusher`
## inside unfiltered 0.60-0.95, medium 0.15-0.55, hard 0.00-0.20, and `nudger`
## strictly lower on every tier while still solving at least one level. A
## configuration that makes the floor superhuman is exactly what this sweep
## exists to keep out of the image.

import std/[json, os, strformat, strutils, tables]
import sokoban/sim

const
  TuningPath = "tools/ci/baseline_tuning.json"
  BandLow: array[Tier, float] = [0.60, 0.15, 0.00]
  BandHigh: array[Tier, float] = [0.95, 0.55, 0.20]

proc levelsFor(seed: int64, cfg: GameConfig): seq[Level] =
  for i, tier in cfg.tierLadder:
    result.add(generateLevel(seed, i, tier, cfg.genNodeCap, cfg.genAttemptCap))

proc play(
  levels: seq[Level], kind: Baseline, params: SearchParams
): seq[LevelOutcome] =
  var cfg = defaultConfig()
  cfg.baselineNodeCap = params.nodeCap
  let sim = newSimServer(cfg)
  sim.phase = phPlaying
  while not sim.episodeOver():
    if sim.needsLevel():
      sim.startLevel(levels[sim.levelIndex + 1])
    if not sim.levelActive:
      break
    sim.beginTurn(scriptedPlan(
      kind, sim.state, sim.level.dead, params, cfg.turnMoves))
    while not sim.turnComplete():
      sim.stepTick()
    sim.endTurn("")
    discard sim.drainEvents()
  for record in sim.levels:
    result.add(record.outcome)

type Rates = array[Tier, float]

proc rates(
  cache: seq[seq[Level]], kind: Baseline, params: SearchParams,
  ladder: seq[Tier]
): Rates =
  var
    solved: array[Tier, int]
    total: array[Tier, int]
  for levels in cache:
    let outcomes = play(levels, kind, params)
    for i, tier in ladder:
      inc total[tier]
      if outcomes[i] == loSolved:
        inc solved[tier]
  for tier in Tier:
    result[tier] =
      if total[tier] == 0: 0.0 else: solved[tier] / total[tier]

proc inBand(r: Rates): bool =
  for tier in Tier:
    if r[tier] < BandLow[tier] or r[tier] > BandHigh[tier]:
      return false
  true

proc distanceToCentre(r: Rates): float =
  for tier in Tier:
    let centre = (BandLow[tier] + BandHigh[tier]) / 2.0
    result += abs(r[tier] - centre)

proc main() =
  let check = "--check" in commandLineParams()
  let seeds = if check: 24 else: 40
  let cfg = defaultConfig()
  var cache: seq[seq[Level]] = @[]
  for s in 0 ..< seeds:
    cache.add(levelsFor(int64(s) * 1013 + 7, cfg))

  if check:
    let recorded = parseFile(TuningPath)
    let params = SearchParams(
      nodeCap: recorded["nodeCap"].getInt(),
      greedyMatch: recorded["greedyMatch"].getBool(),
      tieOnH: recorded["tieOnH"].getBool())
    doAssert params == DefaultSearchParams,
      "tools/ci/baseline_tuning.json disagrees with DefaultSearchParams"
    let
      pusher = rates(cache, blPusher, params, cfg.tierLadder)
      nudger = rates(cache, blNudger, params, cfg.tierLadder)
    echo &"pusher {pusher}  nudger {nudger}"
    doAssert pusher.inBand(),
      "the shipped pusher is outside the design's strength band: " & $pusher
    var anySolved = false
    for tier in Tier:
      doAssert nudger[tier] <= pusher[tier],
        "nudger must be no stronger than pusher on every tier"
      if nudger[tier] > 0.0:
        anySolved = true
    doAssert anySolved, "nudger solved nothing across the sweep"
    echo "baseline tuning: shipped defaults still hold"
    return

  var
    best: SearchParams
    bestRates: Rates
    bestDistance = 1.0e9
    found = false
  for nodeCap in [8, 16, 24, 40, 80, 150, 300, 600, 1200, 20000]:
    for greedyMatch in [false, true]:
      for tieOnH in [false, true]:
        let params = SearchParams(
          nodeCap: nodeCap, greedyMatch: greedyMatch, tieOnH: tieOnH)
        let r = rates(cache, blPusher, params, cfg.tierLadder)
        let distance = r.distanceToCentre()
        echo &"nodeCap={nodeCap} greedyMatch={greedyMatch} tieOnH={tieOnH} " &
          &"rates={r} inBand={r.inBand()}"
        if r.inBand() and distance < bestDistance:
          best = params
          bestRates = r
          bestDistance = distance
          found = true
  doAssert found, "no swept configuration lands inside the strength band"
  let nudgerRates = rates(cache, blNudger, best, cfg.tierLadder)
  writeFile(TuningPath, (%*{
    "sweptAt": "tools/tune_baselines.nim",
    "seeds": seeds,
    "nodeCap": best.nodeCap,
    "greedyMatch": best.greedyMatch,
    "tieOnH": best.tieOnH,
    "pusherSolveRate": {
      "unfiltered": bestRates[tierUnfiltered],
      "medium": bestRates[tierMedium],
      "hard": bestRates[tierHard]
    },
    "nudgerSolveRate": {
      "unfiltered": nudgerRates[tierUnfiltered],
      "medium": nudgerRates[tierMedium],
      "hard": nudgerRates[tierHard]
    }
  }).pretty() & "\n")
  echo "wrote ", TuningPath

main()
