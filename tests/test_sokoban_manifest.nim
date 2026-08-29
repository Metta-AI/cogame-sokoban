## Manifest pins, and every variant actually constructing a playable game.

import std/[json, os, strutils, unittest]
import sokoban/sim
import helpers

const ManifestPath = "coworld_manifest_template.json"

let manifest = parseFile(ManifestPath)

suite "manifest pins":
  test "num_agents is 1 in both variants AND in the certification fixture":
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == 1
      # `CoworldVariant` is additionalProperties: false and the platform reads
      # only game_config.num_agents, so a variant-level key is rejected.
      check not variant.hasKey("num_agents")
      var keys: seq[string] = @[]
      for key, _ in variant:
        keys.add(key)
      check keys.len == 4
      for key in ["id", "name", "description", "game_config"]:
        check key in keys
    check manifest["certification"]["game_config"]["num_agents"].getInt() == 1

  test "no game_config carries a literal tokens array":
    for variant in manifest["variants"]:
      check not variant["game_config"].hasKey("tokens")
    check not manifest["certification"]["game_config"].hasKey("tokens")
    # config_schema keeps REQUIRING tokens, because the runner injects them.
    var required: seq[string] = @[]
    for value in manifest["game"]["config_schema"]["required"]:
      required.add(value.getStr())
    check "tokens" in required
    check "players" in required

  test "exactly one declared player, and it occupies a certification slot":
    check manifest["player"].len == 1
    let declared = manifest["player"][0]["id"].getStr()
    var seated: seq[string] = @[]
    for entry in manifest["certification"]["players"]:
      seated.add(entry["player_id"].getStr())
    check declared in seated
    check manifest["certification"]["players"].len == 1
    check manifest["certification"]["game_config"]["players"].len == 1

  test "every array property in config_schema declares minItems and maxItems":
    for key, prop in manifest["game"]["config_schema"]["properties"]:
      if prop{"type"}.getStr() == "array":
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")

  test "episode_timeout_minutes is top level and game.tags does not exist":
    check manifest.hasKey("episode_timeout_minutes")
    check not manifest["game"].hasKey("episode_timeout_minutes")
    check not manifest["game"].hasKey("tags")
    check manifest["tags"].len >= 3
    check manifest["game"]["description"].getStr().len > 0
    check not manifest.hasKey("version")
    check not manifest["game"].hasKey("display_name")
    check manifest["game"]["owner"].getStr().len > 0

  test "protocols carry BOTH player and global as objects, and docs is complete":
    for key in ["player", "global"]:
      let node = manifest["game"]["protocols"][key]
      check node.kind == JObject
      check node.hasKey("type")
      check node.hasKey("value")
    let docs = manifest["game"]["docs"]
    check docs["readme"].kind == JObject
    check docs["pages"].len == 3
    for page in docs["pages"]:
      check page.hasKey("id")
      check page.hasKey("title")
      check page["content"].kind == JObject

  test "the replay viewer is the static bundle, declared under game":
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    check not manifest.hasKey("replay_viewer")
    check manifest["game"]["runnable"]["type"].getStr() == "game"
    check manifest["game"]["runnable"]["run"][0].getStr() == "/bin/sokoban"

  test "the declared player's cpu limit is at least 1":
    let limit = manifest["player"][0]["resources"]["limits"]["cpu"].getStr()
    check limit == "1" or limit == "2" or limit.endsWith("000m")

  test "game.name equals the slug and the secret URI's namespace":
    check manifest["game"]["name"].getStr() == GameName
    let uri = manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"]
      .getStr()
    check uri == "secret://coworld/" & GameName & "/anthropic_api_key"
    check "cogame-" & GameName in
      manifest["game"]["runnable"]["source_url"].getStr()

  test "every wallClockBudgetSeconds is inside 60 % of the episode timeout":
    let timeoutSeconds = manifest["episode_timeout_minutes"].getInt() * 60
    for variant in manifest["variants"]:
      let budget = variant["game_config"]["wallClockBudgetSeconds"].getInt()
      check budget <= 690
      check budget * 100 <= timeoutSeconds * 60
    check manifest["certification"]["game_config"][
      "wallClockBudgetSeconds"].getInt() <= 690

  test "the deadline arithmetic and the ladder identities hold in every config":
    var configs: seq[JsonNode] = @[]
    for variant in manifest["variants"]:
      configs.add(variant["game_config"])
    configs.add(manifest["certification"]["game_config"])
    for node in configs:
      let
        attempt1 = node["attempt1Ms"].getInt()
        retry = node["retryMs"].getInt()
        budget = node["turnBudgetMs"].getInt()
      check attempt1 mod 1000 == 0
      check retry mod 1000 == 0
      check attempt1 + retry <= budget
      check node["stepBudget"].getInt() ==
        node["levelTurnCap"].getInt() * node["turnMoves"].getInt()
      check node["maxTurns"].getInt() ==
        node["levelCount"].getInt() * node["levelTurnCap"].getInt()
      check node["maxTicks"].getInt() ==
        node["maxTurns"].getInt() * node["turnMoves"].getInt()
      check node["tierLadder"].len == node["levelCount"].getInt()

  test "every variant's game_config constructs, validates and really plays":
    # The collab-cooking 0.1.1 scar: test EVERY variant, not just the fixture.
    var configs: seq[JsonNode] = @[]
    for variant in manifest["variants"]:
      configs.add(variant["game_config"])
    configs.add(manifest["certification"]["game_config"])
    for node in configs:
      var cfg = defaultConfig()
      cfg.update(node)
      cfg.validate()
      check cfg.numAgents == 1
      let levels = levelsFor(cfg.seed, cfg)
      check levels.len == cfg.levelCount
      for i, level in levels:
        check level.tier == cfg.tierLadder[i]
        check level.state.renderXsb().len == GridSize
      let episode = runEpisode(cfg, blPusher, levels)
      check episode.sim.reason == endComplete
      check episode.sim.turnsPlayed <= cfg.maxTurns
      check episode.sim.tick <= cfg.maxTicks
      var weight = 0
      for tier in cfg.tierLadder:
        weight += TierWeights[tier]
      check episode.sim.ladderResultsJson()["maxWeight"].getInt() == weight

suite "the scaffold is present and substituted":
  test "no unsubstituted placeholder survives in the CI scaffold":
    for path in [".github/workflows/ci.yml",
                 ".github/workflows/coworld-release.yml",
                 ".github/workflows/coworld-submit.yml",
                 "tools/ci/docker_smoke.sh",
                 "tools/ci/policies.json"]:
      check fileExists(path)
      let source = readFile(path)
      check "<slug>" notin source
      check "<IMAGE>" notin source
      check "<SEATS>" notin source

  test "the policy set is two LLM champions plus two scripted baselines":
    let policies = parseFile("tools/ci/policies.json")
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    var champion2 = ""
    for policy in policies:
      check policy["run"].getStr() == "/bin/sokoban-player"
      check policy["name"].getStr().startsWith("sokoban-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
        if policy.hasKey("player"):
          champion2 = policy["player"].getStr()
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        let name = policy["env"]["PLAYER_SCRIPTED"].getStr()
        check name in ["pusher", "nudger"]
    check prompts == 2
    check scripted == 2
    check champion2 == "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"

  test "compose declares one service whose name derives the image placeholder":
    let compose = readFile("compose.yaml")
    check "sokoban:" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose
    check manifest["game"]["runnable"]["image"].getStr() == "{{SOKOBAN_IMAGE}}"
