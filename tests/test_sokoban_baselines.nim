## Bounded orders and legality on the scripted baselines, the driver, the
## fallback identity, the reply validator and the shipped baseline strength.

import std/[json, strutils, unicode, unittest]
import sokoban/sim
import sokoban/policy_view
import helpers

proc statesFor(count: int): seq[Level] =
  ## Pseudo-random states across all three tiers, fresh and mid-level, with
  ## crates parked and loose.
  let cfg = defaultConfig()
  var made = 0
  var s = 0
  while made < count:
    for i, tier in cfg.tierLadder:
      if made >= count:
        break
      var level = generateLevel(int64(s) * 6551 + 17, i, tier,
                                cfg.genNodeCap, cfg.genAttemptCap)
      if made mod 2 == 1:
        # Walk the position forward a few legal pushes so the sample is not all
        # opening positions.
        for step in 0 ..< 3:
          let pushes = level.state.legalPushes()
          if pushes.len == 0:
            break
          let pick = pushes[(made + step) mod pushes.len]
          if level.state.isDeadlocked(level.dead).dead:
            break
          level.state.applyPush(pick)
      result.add(level)
      inc made
    inc s

suite "baselines are bounded":
  test "every action of both baselines is inside the schema":
    let cfg = defaultConfig()
    for level in statesFor(SampleStates):
      for kind in [blPusher, blNudger]:
        let plan = scriptedPlan(kind, level.state, level.dead,
                                DefaultSearchParams, cfg.turnMoves)
        check plan.actions.len <= cfg.maxActionsPerTurn
        check plan.say.len == 0
        check plan.notes.len == 0
        for action in plan.actions:
          case action.kind
          of akPush:
            check action.box >= 0 and action.box < BoxCount
            check action.times >= 1 and action.times <= 8
          of akMoves:
            check action.seq.len <= MaxActionSeqRunes
            for ch in action.seq:
              check ch in {'U', 'D', 'L', 'R'}
          of akGoto:
            check action.x >= 0 and action.x < GridSize
            check action.y >= 0 and action.y < GridSize
          of akWait:
            discard
        check ($plan.actionsJson()).len <= 1024

suite "baselines never deadlock on purpose":
  test "neither emits a suicidal push while a safe one exists":
    let cfg = defaultConfig()
    for level in statesFor(SampleStates):
      let pushes = level.state.legalPushes()
      var safeExists = false
      for push in pushes:
        if not pushCreatesDeadlock(level.state, push, level.dead):
          safeExists = true
      if not safeExists:
        continue
      for kind in [blPusher, blNudger]:
        let plan = scriptedPlan(kind, level.state, level.dead,
                                DefaultSearchParams, cfg.turnMoves)
        for action in plan.actions:
          if action.kind != akPush:
            continue
          for push in pushes:
            if push.box == action.box and push.dir == action.dir:
              check not pushCreatesDeadlock(level.state, push, level.dead)
          break        # only the FIRST push of the plan is checked against
                       # this snapshot; the rest are planned from later states

suite "the driver never produces an illegal primitive":
  test "every queue is bounded, legal, and never empty in effect":
    let cfg = defaultConfig()
    for level in statesFor(SampleStates div 2):
      for kind in [blPusher, blNudger]:
        let plan = scriptedPlan(kind, level.state, level.dead,
                                DefaultSearchParams, cfg.turnMoves)
        let expansion = expandDirective(
          level.state, plan, cfg.turnMoves, cfg.macroPrimitiveCap)
        check expansion.queue.len <= cfg.turnMoves
        for primitive in expansion.queue:
          check primitive.isWait or primitive.dir in Dirs
        # An empty queue yields `wait`, never nothing.
        check queueOrWait(expansion, expansion.queue.len).isWait

  test "a macro never expands past macroPrimitiveCap":
    let level = levelOf(OpenRoom)
    let plan = Directive(actions: @[Action(kind: akMoves,
      seq: "UDLRUDLRUDLRUDLRUDLR")])
    let expansion = expandDirective(level.state, plan, 20, 4)
    check expansion.queue.len == 4

suite "fallback is the pusher proc":
  test "the engine's fallback plan equals the pusher baseline's plan":
    let cfg = defaultConfig()
    for level in statesFor(max(4, SampleStates div 5)):
      let sim = newSimServer(cfg)
      sim.phase = phPlaying
      sim.startLevel(level)
      let viaEngine = sim.scriptedDirective(blPusher)
      let viaBaseline = pusherPlan(level.state, level.dead,
                                   sim.searchParams(), cfg.turnMoves)
      check $viaEngine.actionsJson() == $viaBaseline.actionsJson()

suite "scripted player observation":
  test "both baselines preserve turn-start box IDs from the public view":
    let cfg = defaultConfig()
    for level in statesFor(SampleStates):
      let sim = newSimServer(cfg)
      sim.phase = phPlaying
      sim.startLevel(level)
      for reordered in [false, true]:
        if reordered:
          swap(sim.state.boxes[0], sim.state.boxes[1])
        let view = sim.observationJson(0)
        for kind in [blPusher, blNudger]:
          let expected = sim.scriptedDirective(kind)
          let actual = scriptedPlanForView(view, kind)
          check $actual.actionsJson() == $expected.actionsJson()

suite "reply validation":
  test "the schema is accepted":
    let payload = parseJson("""{"actions":[
      {"do":"push","box":1,"dir":"R","times":2},
      {"do":"goto","x":5,"y":3},
      {"do":"moves","seq":"LLU"},
      {"do":"wait"}],
      "say":"parking the right-hand pair first","notes":"order 1 3 2 0"}""")
    let directive = parseDirective(payload, 8)
    check directive.actions.len == 4
    check directive.dropped == 0
    check directive.actions[0].kind == akPush
    check directive.actions[0].times == 2
    check directive.say == "parking the right-hand pair first"

  test "an invalid action is DROPPED, never rewritten":
    let payload = parseJson("""{"actions":[
      {"do":"push","box":9,"dir":"R"},
      {"do":"push","box":2,"dir":"sideways"},
      {"do":"moves","seq":"UDLQ"},
      {"do":"goto","x":"north"},
      {"do":"push","box":0,"dir":"U"}]}""")
    let directive = parseDirective(payload, 8)
    check directive.actions.len == 1
    check directive.actions[0].box == 0
    check directive.dropped == 4

  test "`do` is exactly the four declared verbs, and an absent one DROPS":
    let payload = parseJson("""{"actions":[
      {"do":"move","seq":"UU"},
      {"do":"go","x":1,"y":1},
      {"do":"seq","seq":"UU"},
      {"seq":"UU"},
      {"do":"","x":1,"y":1},
      {"do":"moves","seq":"UU"}]}""")
    let directive = parseDirective(payload, 8)
    check directive.actions.len == 1
    check directive.actions[0].kind == akMoves
    check directive.dropped == 5

  test "goto coordinates and times are clamped, do and dir are case-folded":
    let payload = parseJson("""{"actions":[
      {"do":"GOTO","x":99,"y":-5},
      {"do":"Push","box":0,"dir":"right","times":99},
      {"do":"moves","seq":"udlr"}]}""")
    let directive = parseDirective(payload, 8)
    check directive.actions[0].x == GridSize - 1
    check directive.actions[0].y == 0
    check directive.actions[1].times == 8
    check directive.actions[1].dir == dirRight
    check directive.actions[2].seq == "UDLR"

  test "a say-only reply is usable and a non-object is a parse failure":
    let directive = parseDirective(parseJson("""{"say":"thinking"}"""), 8)
    check directive.actions.len == 0
    check directive.say == "thinking"
    expect DirectiveError:
      discard parseDirective(parseJson("[1,2,3]"), 8)

  test "actions past the cap are dropped and counted":
    var text = "{\"actions\":["
    for i in 0 ..< 20:
      if i > 0: text.add(",")
      text.add("{\"do\":\"wait\"}")
    text.add("]}")
    let directive = parseDirective(parseJson(text), 8)
    check directive.actions.len == 8
    check directive.overCap == 12

  test "say and notes truncate on RUNE boundaries with 4-byte emoji on the cap":
    # A 4-byte emoji sitting exactly ON the boundary is the case a byte slice
    # gets wrong: it renders in a browser and then fails a strict UTF-8 parser.
    var say = ""
    for i in 0 ..< 400:
      say.add("\u{1F9CA}")
    let directive = parseDirective(
      %*{"say": say, "notes": say}, 8)
    check directive.say.runeLen == MaxSayRunes
    check directive.notes.runeLen == MaxNoteRunes
    check directive.say.validateUtf8() == -1
    check directive.notes.validateUtf8() == -1

  test "the 4096-byte provider cap cuts on a rune boundary, not a byte":
    # The reply cap is a BYTE cap (the design note's reply schema), and
    # `std/json` does not validate UTF-8, so a plain byte slice that lands
    # mid-codepoint parses happily and rides the broken byte into `say` and
    # into the replay. `truncateRunes` downstream only SHORTENS — it cannot
    # repair a codepoint that was already split — so the cut itself has to be
    # rune-safe. Build a reply whose 4-byte emoji straddles byte 4096.
    var text = "{\"say\":\""
    while text.len < MaxReplyBytes - 2:
      text.add("x")
    check text.len == MaxReplyBytes - 2   # the emoji now spans 4094 .. 4097
    text.add("\u{1F9CA}")
    text.add("\"}")
    check text.len > MaxReplyBytes
    # What the old byte slice did, for contrast: it splits the codepoint.
    check text[0 ..< MaxReplyBytes].validateUtf8() != -1
    let cut = text.truncateUtf8Bytes(MaxReplyBytes)
    check cut.len <= MaxReplyBytes
    check cut.validateUtf8() == -1
    # And the whole path: what survives the cut still parses and every string
    # that reaches the replay is valid UTF-8.
    let directive = parseDirective(extractJsonObject(cut & "\"}"), 8)
    check directive.say.runeLen == MaxSayRunes
    check directive.say.validateUtf8() == -1
    # The provider path uses it — both the envelope read and the text cap.
    let source = readFile("src/sokoban/player_llm.nim")
    check source.count("truncateUtf8Bytes") == 2
    check "MaxReplyBytes]" notin source

  test "extractJsonObject tolerates fences and trailing prose":
    let text = "Here you go:\n```json\n{\"actions\":[{\"do\":\"wait\"}]}\n```\n" &
      "Hope that helps."
    let node = extractJsonObject(text)
    check node.kind == JObject
    check node["actions"].len == 1

suite "baseline strength is in range":
  test "pusher is inside the band and nudger is no stronger on any tier":
    let cfg = defaultConfig()
    var
      solvedP: array[Tier, int]
      solvedN: array[Tier, int]
      total: array[Tier, int]
    for s in 0 ..< SweepSeeds:
      let levels = levelsFor(int64(s) * 1013 + 7, cfg)
      let p = runEpisode(cfg, blPusher, levels)
      let n = runEpisode(cfg, blNudger, levels)
      for i, tier in cfg.tierLadder:
        inc total[tier]
        if p.sim.levels[i].outcome == loSolved: inc solvedP[tier]
        if n.sim.levels[i].outcome == loSolved: inc solvedN[tier]
    # The design note's band is unfiltered 0.60-0.95, medium 0.15-0.55, hard
    # 0.00-0.20; `tools/tune_baselines.nim` swept the tunables to land inside
    # it over 40 seeds (0.69 / 0.38 / 0.06). The gate here is that band widened
    # for the much smaller CI sample. Neither a zero floor nor a superhuman
    # filler can ship.
    let low: array[Tier, int] = [45, 10, 0]
    let high: array[Tier, int] = [100, 65, 30]
    var anyNudger = 0
    for tier in Tier:
      check total[tier] > 0
      let rate = solvedP[tier] * 100 div total[tier]
      check rate >= low[tier]
      check rate <= high[tier]
      check solvedN[tier] <= solvedP[tier]
      anyNudger += solvedN[tier]
    check anyNudger >= 1
