## Export whole episodes using the ordinary private-view pusher policy.
## The shared reviewed importer owns dataset labels and seed-family splits.

import std/[json, options, os, osproc, strutils]
import sokoban/[sim, policy_view, prompt_render]
import bitworld/decision_trajectory

const OperatorPrompt = "Plan crate pushes carefully. Check for dead squares before committing."

when isMainModule:
  let args = commandLineParams()
  if args.len != 5:
    quit("usage: export_posttrain OUTPUT EPISODES FIRST_SEED VARIANT GAME_VERSION", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = parseInt(args[2])
  let variant = args[3]
  let gameVersion = args[4]
  if episodes < 10 or firstSeed < 0 or gameVersion.len == 0:
    quit("at least ten episodes, a nonnegative seed and game version are required", 1)
  if variant notin ["ladder", "hard"]:
    quit("variant must be ladder or hard", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  var trajectoryRows: seq[string]
  var runs = newJArray()
  var teacherDecisions = 0
  for seed in firstSeed ..< firstSeed + episodes:
    var config = configFromJson(variantConfig)
    config.seed = int64(seed)
    config.validate()
    let sim = newSimServer(config)
    sim.phase = phPlaying
    let episodeId = "sokoban-" & variant & "-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, "sokoban-" & $seed,
      "sokoban", gameVersion, sourceRevision)
    var decisions = 0
    while not sim.episodeOver():
      if sim.needsLevel():
        let index = sim.levelIndex + 1
        sim.startLevel(generateLevel(config.seed, index, sim.tierOf(index),
          config.genNodeCap, config.genAttemptCap))
      if not sim.levelActive:
        break
      let view = sim.observationJson(0)
      let proposal = scriptedPlanForView(view, blPusher)
      let offered = %*{"actions": proposal.actionsJson(),
        "say": proposal.say, "notes": proposal.notes}
      let directive = parseDirective(offered, config.maxActionsPerTurn)
      let completion = directive.directiveJson()
      let parsed = parseDirective(completion, config.maxActionsPerTurn)
      doAssert $parsed.actionsJson() == $directive.actionsJson()
      let decisionId = $sim.turnsPlayed
      var attempt = newDecisionAttempt(decisionId & "-teacher",
        "pusher-private-view", aoTeacher)
      attempt.prompt = %*[{"role": "system", "content": SystemPrompt},
        {"role": "user", "content": userMessage(OperatorPrompt, $view)}]
      attempt.response = %($completion)
      attempt.parsedAction = completion
      attempt.accepted = true
      sim.beginTurn(parsed)
      while not sim.turnComplete():
        sim.stepTick()
      sim.endTurn(parsed.notes)
      trajectory.recordDecision(decisionId, "0", view, @[attempt],
        some(attempt.attemptId), completion, asAccepted,
        terminal = sim.episodeOver())
      inc decisions
      inc teacherDecisions
    sim.settle(endComplete,
      if sim.ladderComplete(): erLadderComplete else: erTurnCap)
    doAssert decisions > 0 and sim.reason == endComplete
    let outcome = sim.ladderResultsJson()
    outcome["engine_rules_version"] = %GameVersion
    let participantOutcomes = %*{"0": outcome["scores"][0]}
    trajectory.finish(esCompleted, outcome, participantOutcomes)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
    runs.add(%*{"seed": seed, "decisions": decisions,
      "score": sim.episodeScore(), "levels_solved": sim.levelsSolved()})
  writePrivate(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "sokoban", "variant": variant,
    "source_revision": sourceRevision, "game_version": gameVersion,
    "teacher": "pusher-private-view", "operator_prompt": OperatorPrompt,
    "episodes": episodes, "decisions": teacherDecisions,
    "dataset_path": "canonical-trajectories-only; shared reviewed importer owns splits",
    "runs": runs
  }) & "\n")
  echo "complete_episodes=", episodes, " decisions=", teacherDecisions
