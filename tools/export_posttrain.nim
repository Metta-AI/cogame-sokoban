## Export complete scripted-search games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [ladder|hard]

import std/[json, os, osproc, strutils]
import sokoban/[sim, llm]

const OperatorPrompt = "Plan crate pushes carefully. Check for dead squares before committing."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [ladder|hard]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 0
  let variant = if args.len == 4: args[3] else: "ladder"
  if episodes < 10 or firstSeed < 0:
    quit("at least ten episodes and a nonnegative first seed are required", 1)
  if variant notin ["ladder", "hard"]:
    quit("variant must be ladder or hard", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = configFromJson(variantConfig)
    config.seed = int64(seed)
    config.validate()
    let sim = newSimServer(config)
    sim.phase = phPlaying
    var rows: seq[string]
    while not sim.episodeOver():
      if sim.needsLevel():
        let index = sim.levelIndex + 1
        sim.startLevel(generateLevel(config.seed, index, sim.tierOf(index),
          config.genNodeCap, config.genAttemptCap))
      if not sim.levelActive:
        break
      let view = sim.observationJson(0)
      let directive = sim.scriptedDirective(blPusher)
      let completion = %*{
        "actions": directive.actionsJson(),
        "say": directive.say,
        "notes": directive.notes
      }
      let parsed = parseDirective(completion, config.maxActionsPerTurn)
      doAssert $parsed.actionsJson() == $directive.actionsJson()
      rows.add($(%*{
        "episode_id": "sokoban-" & variant & "-" & $seed,
        "seed": "sokoban-" & variant & "-" & $seed,
        "decision_id": sim.turnsPlayed,
        "prompt": [
          {"role": "system", "content": SystemPrompt},
          {"role": "user", "content": userMessage(OperatorPrompt, $view)}
        ],
        "completion": [{"role": "assistant", "content": $completion}],
        "game": "sokoban",
        "action_schema_revision": "sokoban-directive-v1"
      }))
      sim.beginTurn(directive)
      while not sim.turnComplete():
        sim.stepTick()
      sim.endTurn(directive.notes)
    sim.settle(endComplete,
      if sim.ladderComplete(): erLadderComplete else: erTurnCap)
    doAssert rows.len > 0
    doAssert sim.reason == endComplete
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "score": sim.episodeScore(), "levels_solved": sim.levelsSolved()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "sokoban",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-pusher-search",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
