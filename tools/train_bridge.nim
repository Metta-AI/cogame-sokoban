## Persistent JSONL bridge for single-seat Metta RL and native PufferLib.
## nim c -d:release --path:src -o:sokoban-train-bridge tools/train_bridge.nim

import std/[json, os]
import sokoban/[sim, player_llm]

const OperatorPrompt = "Plan crate pushes carefully. Check for dead squares before committing."

proc seedOf(value: string): int64 =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int64(hash and 0x7fffffff'u32)

proc actionChoices(): JsonNode =
  result = %*["stop", {"do": "wait"}]
  for box in 0 ..< BoxCount:
    for dir in Dirs:
      result.add(%*{"do": "push", "box": box, "dir": $dir, "times": 1})

proc decision(game: SimServer, id: int): JsonNode =
  var required = newJArray()
  var properties = newJObject()
  for slot in 0 ..< game.config.maxActionsPerTurn:
    let name = "action" & $slot
    required.add(%name)
    properties[name] = %*{"oneOf": [
      {"type": "string", "enum": ["stop"]},
      {"type": "object", "required": ["do"]}
    ]}
  let view = game.observationJson(0)
  %*{
    "kind": "decision", "game": "sokoban", "decision_id": id,
    "seat": 0, "engine_seat": 0, "turn": game.turnsPlayed,
    "semantic_view": view,
    "inbox": [],
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(OperatorPrompt, $view)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": required,
      "properties": properties},
    "typed_question": newJNull()
  }

proc encoding(game: SimServer, id: int): JsonNode =
  let view = game.observationJson(0)
  let level = view["level"]
  var values = newJArray()
  for variant in ["ladder", "hard"]:
    values.add(%(if game.config.variant == variant: 1 else: 0))
  for key in ["index", "of", "opt_pushes", "moves_left", "turns_left",
      "pushes_made", "boxes_on_targets"]:
    values.add(level[key])
  values.add(%ord(level["tier"].getStr()[0]))
  for key in ["turn", "tick", "levels_solved", "solved_weight"]:
    values.add(view[key])
  values.add(view["player"]["x"])
  values.add(view["player"]["y"])
  doAssert view["board"].len == GridSize
  for row in view["board"]:
    let cells = row.getStr()
    doAssert cells.len == GridSize
    for cell in cells:
      values.add(%ord(cell))
  var dead: array[GridCells, bool]
  for cell in view["dead_squares"]:
    dead[cell[1].getInt() * GridSize + cell[0].getInt()] = true
  for cell in dead:
    values.add(%(if cell: 1 else: 0))
  doAssert view["boxes"].len == BoxCount and view["targets"].len == BoxCount
  for box in view["boxes"]:
    values.add(box["x"])
    values.add(box["y"])
    values.add(%(if box["on_target"].getBool(): 1 else: 0))
  for target in view["targets"]:
    values.add(target["x"])
    values.add(target["y"])
    values.add(%(if target["filled"].getBool(): 1 else: 0))
  var available: array[BoxCount * 4, bool]
  for push in view["pushes_available"]:
    let dir = parseDir(push["dir"].getStr())
    doAssert dir.ok
    available[push["box"].getInt() * 4 + ord(dir.dir)] = true
  for choice in available:
    values.add(%(if choice: 1 else: 0))
  for index in 0 ..< game.config.levelCount:
    if index < view["history"].len:
      let record = view["history"][index]
      values.add(%ord(record["tier"].getStr()[0]))
      values.add(%ord(record["outcome"].getStr()[0]))
    else:
      values.add(%0)
      values.add(%0)
  if view["last_turn"].kind == JNull:
    for field in 0 ..< 6:
      values.add(%0)
  else:
    let report = view["last_turn"]
    values.add(%report["executed"].getStr().len)
    for key in ["pushes", "blocked", "truncated", "dropped", "unreachable"]:
      values.add(report[key])
  var heads = newJArray()
  for slot in 0 ..< game.config.maxActionsPerTurn:
    heads.add(%*{"name": "action" & $slot, "choices": actionChoices()})
  %*{"decision_id": id, "values": values, "action_heads": heads}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: sokoban-train-bridge MANIFEST [ladder|hard]", 1)
  let variant = if args.len == 2: args[1] else: "ladder"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: SimServer
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 1
      var config = configFromJson(variantConfig)
      config.seed = seedOf(request["seed"].getStr())
      config.validate()
      game = newSimServer(config)
      game.phase = phPlaying
      let index = game.levelIndex + 1
      game.startLevel(generateLevel(config.seed, index,
        game.tierOf(index), config.genNodeCap, config.genAttemptCap))
      id = 0
      response = game.decision(id)
    of "encode":
      doAssert not game.episodeOver()
      response = game.encoding(id)
    of "teacher":
      doAssert not game.episodeOver()
      let directive = game.scriptedDirective(blPusher)
      doAssert directive.actions.len <= game.config.maxActionsPerTurn
      var action = newJObject()
      for slot in 0 ..< game.config.maxActionsPerTurn:
        action["action" & $slot] =
          if slot < directive.actions.len:
            directive.actions[slot].actionJson()
          else:
            %"stop"
      response = %*{"response": $action}
    of "step":
      doAssert not game.episodeOver() and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      var actions = newJArray()
      for slot in 0 ..< game.config.maxActionsPerTurn:
        let choice = action["action" & $slot]
        if choice.kind != JString:
          actions.add(choice)
        else:
          doAssert choice.getStr() == "stop"
      let directive = parseDirective(%*{"actions": actions}, game.config.maxActionsPerTurn)
      doAssert directive.dropped == 0 and directive.overCap == 0
      game.beginTurn(directive)
      while not game.turnComplete():
        game.stepTick()
      game.endTurn("")
      inc id
      var observation: JsonNode
      if game.episodeOver():
        game.settle(endComplete,
          if game.ladderComplete(): erLadderComplete else: erTurnCap)
        var maxWeight = 0
        for tier in game.config.tierLadder:
          maxWeight += TierWeights[tier]
        let score = game.episodeScore()
        let maxScore = 1_000_000 * maxWeight +
          10_000 * BoxCount * game.config.levelCount +
          game.config.stepBudget * game.config.levelCount
        let utility = 2.0 * float(score) / float(maxScore) - 1.0
        observation = %*{"kind": "terminal", "scores": {"0": score},
          "utilities": {"0": utility}}
      else:
        if game.needsLevel():
          let index = game.levelIndex + 1
          game.startLevel(generateLevel(game.config.seed, index,
            game.tierOf(index), game.config.genNodeCap,
            game.config.genAttemptCap))
        observation = game.decision(id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
