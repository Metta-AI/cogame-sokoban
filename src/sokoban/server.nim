## The Sokoban game server: the Coworld game contract over mummy.
##
## Forked from `coworld-ctf`'s `src/ctf/server.nim` with the three named edits
## of the design note:
##
## 1. TURN BOUNDARY — unchanged in shape, with a VARIABLE turn length (the tick
##    loop breaks early when a level finishes) and one seat in the batch.
## 2. REGISTRATION INTERCEPTION — the seat's Sprite v1 chat message (`0x81`,
##    surfaced by `parseSpriteClientMessages`) whose text parses as a
##    registration object is consumed as REGISTRATION, not applied as a line and
##    not written to the replay chat stream; the server writes a REDACTED
##    `register` record instead (policy label and kind, never the prompt). The
##    server LOGS LOUDLY and refuses to start the game when a joined seat has no
##    register record (the grf-football 2026-08-27 silent-default scar).
## 3. WALL-CLOCK STOP — the starter's `wallClockBudgetSeconds` check at the top
##    of every loop iteration, kept, forcing `reason = deadline`,
##    `endRule = wallClock`, and written as a LOAD-BEARING stop record.
##
## Endpoints:
##   GET /healthz                 liveness
##   GET /client/player           the seat page (view-only; policies are prompts)
##   GET /client/global           the spectator page
##   GET /client/replay           the broadcast replay page
##   GET /client/<asset>          chrome_common.js, broadcast_core.js, art
##   GET /replay-data             the recorded replay bytes (replay mode)
##   WS  /player?slot=N&token=T   the player protocol
##   WS  /global                  spectator sprite packets
##
## The certifier's browser probes are served for real and registered BEFORE any
## catch-all asset route, `/client/player` must NOT open the player socket, the
## player websocket CLOSES unless the token matches the seat (the certifier
## probes with a bad token), and `websocketHandler` keeps the
## `Ping -> socket.send(message.data, Pong)` branch with NO additional `kind`
## guard: a `kind != TextMessage` guard drops the player's BINARY registration
## frames (lux-ai 0.1.0, snake-royale 0.1.0).

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
import bitworld/spriteprotocol
import curly
import mummy
import mummy/routers
import sim_types, sim, sim_config, broadcast, decide, events, global,
  replays, replay_runtime, wire_constants

const
  ShutdownGraceSeconds = 20
    ## `/healthz` and `/global` keep answering for a bounded grace AFTER the
    ## artifacts are written, then the process exits: the runner pings `/global`
    ## with a 2 s deadline after the player pods start, and a short episode may
    ## already have exited (the lantern 0.1.3 scar).

type
  ServerState = object
    prompts: seq[string]
    scripted: seq[Baseline]
    isLlm: seq[bool]
    policies: seq[string]
    names: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewerStates: Table[WebSocket, GlobalViewerState]
    seats: int
    started: bool
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: SimServer
  gameServer: Server
  replayPayload: string
  eventsSinkPath: string
  runtimeCfg: RuntimeConfig

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload — exactly `{"message","failed_policy_index"}`
  ## and nothing else.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "sokoban: player-failure declaration failed: ", error.msg

proc requireFileUri(name: string): string =
  let uri = getEnv(name)
  if uri.len == 0:
    return ""
  if not uri.startsWith("file://"):
    return ""
  uri[7 .. ^1]

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc broadcastPacketLocked(chrome: string) =
  ## Global broadcasts are FIRE AND FORGET so a slow viewer can never stall the
  ## episode.
  for socket in shared.globalSockets:
    var next: GlobalViewerState
    let state = shared.viewerStates.getOrDefault(
      socket, initGlobalViewerState())
    let packet = gameSim.buildViewerPacket(state, next, chrome)
    shared.viewerStates[socket] = next
    try:
      socket.send(blobFromBytes(packet), BinaryMessage)
    except CatchableError:
      discard

proc liveChrome(): string =
  gameSim.buildStateJson(
    gameSim.drainEvents(), playing = true, speed = 1,
    maxTick = max(1, gameSim.config.maxTicks), looping = false,
    transportEnabled = false, mismatchTick = -1)

proc pushFrames() =
  ## Informational: the seat is not required to answer, decisions are
  ## server-side.
  let chrome = liveChrome()
  broadcastPacketLocked(chrome)
  for slot, socket in shared.playerSockets:
    try:
      socket.send($(%*{
        "type": "turn", "turn": gameSim.turnsPlayed, "tick": gameSim.tick,
        "level": gameSim.levelIndex + 1, "of": gameSim.config.levelCount,
        "alias": seatAlias(slot)
      }))
    except CatchableError:
      discard

proc broadcastDone(results: JsonNode) =
  let payload = $(%*{"done": true, "result": results})
  for slot, socket in shared.playerSockets:
    try:
      socket.send(payload)
    except CatchableError as error:
      echo "sokoban: done frame to slot ", slot, " failed: ", error.msg

proc finishEpisode(writer: ReplayWriter, log: EventLog) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    results = gameSim.ladderResultsJson()
    writer.writeChat(gameSim.tick, resultRecord(gameSim))
    replayData = writer.bytes()
    ## Final frames to the players BEFORE the artifacts: the hosted worker
    ## tears player pods down as soon as results.json exists.
    broadcastDone(results)
    broadcastPacketLocked(liveChrome())
  echo "sokoban: writing replay (", replayData.len, " bytes) and results"
  ## The REPLAY first, then the results: the hosted worker treats results.json
  ## as the end of the episode and tears the pods down when it appears, so a
  ## replay written after it can be lost.
  ##
  ## The two writes are INDEPENDENT. `writeArtifact` raises on a non-2xx POST,
  ## and a failed replay upload must not also cost the results document — the
  ## design note's `fault` rule is "artifacts are still written, exit 0", and
  ## `results.json` is what the platform scores the episode from.
  try:
    writeArtifact(runtimeCfg.replayUri, replayData, "application/octet-stream",
      "COGAME_SAVE_REPLAY_METHOD")
  except CatchableError as error:
    echo "sokoban: replay write FAILED — ", error.msg
  try:
    writeArtifact(runtimeCfg.resultsUri, $results, "application/json",
      "COGAME_RESULTS_METHOD")
  except CatchableError as error:
    echo "sokoban: results write FAILED — ", error.msg
  if eventsSinkPath.len > 0:
    try:
      writeFile(eventsSinkPath, log.eventsJsonl(gameSim.tick))
    except CatchableError as error:
      echo "sokoban: event sink write failed: ", error.msg
  echo "sokoban: episode complete (", $gameSim.reason, "/", $gameSim.endRule,
    ") after ", gameSim.tick, " ticks, ", gameSim.levelsSolved(), " of ",
    gameSim.config.levelCount, " levels solved, score ",
    gameSim.episodeScore()

proc runGame(unused: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    let gameStart = epochTime()
    let lobbySeconds = config.lobbyJoinTimeoutTicks / TargetFps
    let connectDeadline = gameStart + lobbySeconds
    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = shared.playerSockets.len >= shared.seats
      if allConnected:
        break
      gameSim.lobbyTicks = int(connectDeadline - epochTime()) * TargetFps
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its register frame.
    let registerDeadline = min(epochTime() + 4.0, connectDeadline + 4.0)
    while epochTime() < registerDeadline:
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var noShow = -1
    withLock stateLock:
      shared.started = true
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
          ## LOUD, and the design's rule: a joined seat with no register record
          ## is a defect, not a default. The episode still runs — nothing a
          ## player container does may stop the clock — but the log says so.
          if shared.playerSockets.hasKey(slot):
            echo "sokoban: ERROR seat ", slot, " connected but never sent a ",
              "register frame; refusing to treat it as a policy and seating ",
              "the pusher baseline"
          else:
            echo "sokoban: seat ", slot, " never connected; the seat plays ",
              "the pusher baseline"
          shared.isLlm[slot] = false
          shared.scripted[slot] = blPusher
        gameSim.seats[slot].kind =
          if shared.isLlm[slot]: "llm" else: "scripted"
        gameSim.seats[slot].policyLabel = shared.policies[slot]
        gameSim.seats[slot].baseline = $shared.scripted[slot]
        gameSim.seats[slot].name = shared.names[slot]
        gameSim.seats[slot].registered = shared.everRegistered[slot]
        gameSim.seats[slot].dead = not shared.everRegistered[slot]
      echo "sokoban: starting with ", shared.playerSockets.len, "/",
        shared.seats, " players connected"
    if noShow >= 0:
      declarePlayerFailure(noShow,
        "player slot " & $noShow & " never registered; the seat played the " &
        "pusher baseline")

    var engine = initDecisionEngine(gameSim)
    withLock stateLock:
      for slot in 0 ..< shared.seats:
        engine.seats[slot].isLlm = shared.isLlm[slot]
        engine.seats[slot].prompt = shared.prompts[slot]
        engine.seats[slot].baseline = shared.scripted[slot]
        engine.seats[slot].label = shared.policies[slot]
        engine.seats[slot].registered = shared.everRegistered[slot]

    let writer = newReplayWriter(configJson(config))
    let log = newEventLog(true)
    for slot in 0 ..< shared.seats:
      writer.writeChat(0, registerRecord(
        slot, seatAlias(slot), gameSim.seats[slot].name,
        gameSim.seats[slot].policyLabel, gameSim.seats[slot].kind,
        gameSim.seats[slot].baseline))

    gameSim.phase = phPlaying
    var
      reason = endComplete
      rule = erLadderComplete
      detail = ""
    try:
      while not gameSim.episodeOver():
        let elapsed = int(epochTime() - gameStart)
        # THE WALL-CLOCK STOP, checked at the top of every loop iteration.
        if elapsed >= config.wallClockBudgetSeconds:
          reason = endDeadline
          rule = erWallClock
          detail = "wall clock budget of " & $config.wallClockBudgetSeconds &
            "s reached at turn " & $gameSim.turnsPlayed
          echo "sokoban: ", detail
          break
        if gameSim.needsLevel():
          let index = gameSim.levelIndex + 1
          let level = generateLevel(
            config.seed, index, gameSim.tierOf(index),
            config.genNodeCap, config.genAttemptCap)
          gameSim.startLevel(level)
          var payload = LevelPayload(
            index: index, tier: level.tier, optPushes: level.optPushes,
            tierRelaxed: level.tierRelaxed,
            rows: gameSim.levels[index].rows,
            dead: gameSim.levels[index].deadList)
          writer.writeLevel(gameSim.tick, payload)
          log.add(seLevelStart, gameSim.tick, %*{
            "level": index, "tier": $level.tier,
            "optPushes": level.optPushes})
        if not gameSim.levelActive:
          break
        let outcome = engine.turn(gameSim, gameSim.turnsPlayed + 1, elapsed)
        var directive = outcome.directive
        for record in outcome.records:
          writer.writeChat(gameSim.tick, record)
          gameSim.noteChatRecord(parseJson(record))
        if directive.source == dsLlm:
          gameSim.seats[0].llmTurns.inc
        elif directive.source == dsFallback:
          gameSim.seats[0].fallbackTurns.inc
        writer.writePlan(gameSim.tick, PlanRecord(
          turn: gameSim.turnsPlayed + 1, level: gameSim.levelIndex,
          source: directive.source, actions: directive.actions,
          say: directive.say, notes: directive.notes))
        log.add(seTurnStart, gameSim.tick, %*{
          "turn": gameSim.turnsPlayed + 1, "source": $directive.source})
        log.add(seDirective, gameSim.tick, %*{
          "turn": gameSim.turnsPlayed + 1, "source": $directive.source,
          "actions": directive.actionsJson(), "latency_ms": directive.latencyMs,
          "dropped": directive.dropped + directive.overCap})
        if directive.source == dsFallback:
          log.add(seFallback, gameSim.tick, %*{
            "turn": gameSim.turnsPlayed + 1})
        gameSim.beginTurn(directive)
        while not gameSim.turnComplete():
          let before = gameSim.state.player
          let pushesBefore = gameSim.levelPushes
          ## The sim's own derived events accumulate until they are drained
          ## for the broadcast at the end of the turn, so the ones this tick
          ## produced are the entries past this mark. Mapping them here is
          ## what makes the tier-2 stream the FULL action trace the design
          ## note promises `cogamer-rl`, rather than three of its eleven
          ## kinds: nothing else knows a crate went on target, or which of
          ## the three deadlock rules fired.
          let eventMark = gameSim.events.len
          gameSim.stepTick()
          writer.writeHash(gameSim.gameHashValue)
          log.add(seMove, gameSim.tick, %*{
            "from": before, "to": gameSim.state.player,
            "push": gameSim.levelPushes > pushesBefore})
          if gameSim.levelPushes > pushesBefore:
            log.add(sePush, gameSim.tick, %*{
              "from": before, "to": gameSim.state.player,
              "pushes": gameSim.levelPushes})
          for i in eventMark ..< gameSim.events.len:
            let event = gameSim.events[i]
            case event{"k"}.getStr()
            of "boxon": log.add(seBoxOn, gameSim.tick, event.copy())
            of "boxoff": log.add(seBoxOff, gameSim.tick, event.copy())
            of "deadlock": log.add(seDeadlock, gameSim.tick, event.copy())
            of "solved": log.add(seSolved, gameSim.tick, event.copy())
            of "failed": log.add(seFailed, gameSim.tick, event.copy())
            else: discard
          if gameSim.turnEnded:
            break
        gameSim.endTurn(directive.notes)
        writer.writeChat(gameSim.tick, directiveRecord(
          gameSim, directive, gameSim.turnsPlayed, 0, outcome.view))
        gameSim.feed.add(parseJson(directiveRecord(
          gameSim, directive, gameSim.turnsPlayed, 0, nil)))
        if gameSim.feed.len > 40:
          gameSim.feed.delete(0)
        withLock stateLock:
          pushFrames()
      if reason == endComplete and not gameSim.ladderComplete():
        rule = erTurnCap
    except CatchableError as error:
      reason = endFault
      rule = erFault
      detail = error.msg
      echo "sokoban: FAULT — ", error.msg

    ## THE SETTLE AND THE ARTIFACT WRITE ARE INSIDE THE FAULT GUARD TOO. The
    ## design note's `fault` rule is "caught; the episode is settled from the
    ## last completed tick, artifacts are still written, exit 0" — and the
    ## stop record, `settle` and `finishEpisode` can all raise: `writeArtifact`
    ## raises `IOError` on a non-2xx POST. An exception here used to propagate
    ## out of `runGame` on the game thread with no results, no replay and no
    ## exit 0.
    try:
      if reason != endComplete:
        writer.writeStop(StopRecord(
          tick: gameSim.tick, reason: reason, endRule: rule, detail: detail))
      gameSim.settle(reason, rule, detail)
      finishEpisode(writer, log)
    except CatchableError as error:
      ## Nothing here may take the game thread down: the episode still exits 0
      ## after the shutdown grace, so `/healthz` and `/global` keep answering
      ## and the platform sees a finished pod rather than a crashed one.
      echo "sokoban: FAULT while settling — ", error.msg
    ## Keep /healthz and /global answering for a bounded grace after the
    ## artifacts are written, then exit.
    sleep(ShutdownGraceSeconds * 1000)
    quit(0)

var gameThread: Thread[RuntimeConfig]

proc serveText(request: Request, body, contentType: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  request.respond(200, headers, body)

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    serveText(request, readFile(path), contentType)
  else:
    request.respond(404)

proc servePage(request: Request, path: string) =
  if not fileExists(path):
    request.respond(404)
    return
  var page = readFile(path)
  page = page.spliceWireConstants()
  let chromeCommon = clientDir() / "chrome_common.js"
  if fileExists(chromeCommon):
    page = page.replace("<!-- CHROME_COMMON -->",
      "<script>" & readFile(chromeCommon) & "</script>")
  let core = clientDir() / "broadcast_core.js"
  if fileExists(core):
    page = page.replace("<!-- BROADCAST_CORE -->",
      "<script>" & readFile(core) & "</script>")
  serveText(request, page, "text/html; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  serveText(request, """{"ok":true}""", "application/json")

proc replayPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}: servePage(request, clientDir() / "replay_broadcast.html")

proc playerPageHandler(request: Request) {.gcsafe.} =
  ## Token-checked, and it MUST NOT open the player socket: the certifier
  ## fetches this page as a browser probe before the player pods start.
  {.gcsafe.}:
    let token = request.queryParams["token"]
    var ok = false
    withLock stateLock:
      for candidate in gameSim.config.tokens:
        if candidate == token:
          ok = true
    if not ok and gameSim.config.tokens.len > 0 and token.len > 0:
      request.respond(403)
      return
    serveText(request,
      "<!doctype html><meta charset=utf-8><title>Sokoban seat</title>" &
      "<body style=\"background:#16110d;color:#f2e8d8;font:14px system-ui;" &
      "padding:24px\"><h1>Sokoban</h1><p>A policy is just a prompt. This seat " &
      "is driven from the game server; there is nothing to control here.</p>" &
      "<p><a style=\"color:#e8a33d\" href=\"/client/replay\">Watch the " &
      "board</a></p>", "text/html; charset=utf-8")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}: servePage(request, clientDir() / "replay_broadcast.html")

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".js"): "application/javascript; charset=utf-8"
      elif name.endsWith(".css"): "text/css; charset=utf-8"
      elif name.endsWith(".html"): "text/html; charset=utf-8"
      elif name.endsWith(".png"): "image/png"
      elif name.endsWith(".jpg"): "image/jpeg"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, clientDir() / name, contentType)

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayload.len == 0:
      request.respond(404)
      return
    serveText(request, replayPayload, "application/octet-stream")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      ## The certifier probes with a WRONG token and requires a close
      ## (cogame-flatland 0.1.1).
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    ## The REAL player name, spectator side only. The platform names a seat on
    ## the player websocket URL (`/player?slot&token&name=`), which is the
    ## starter's own route (`coworld-ctf`'s `playerIdentity`,
    ## `src/ctf/server.nim:471-475`); the registration blob the shipped player
    ## sends carries no name at all, so without this `results.names` fell back
    ## to the POLICY LABEL for every episode.
    let declaredName = request.queryParams["name"]
      .strip().truncateRunes(MaxPolicyLabelRunes)
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      if declaredName.len > 0:
        shared.names[slot] = declaredName
      echo "sokoban: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      try:
        websocket.send($(%*{
          "type": "welcome", "protocol": ProtocolName, "slot": slot,
          "alias": seatAlias(slot),
          "turn_moves": gameSim.config.turnMoves}))
      except CatchableError:
        discard

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      shared.viewerStates[websocket] = initGlobalViewerState()
      var next: GlobalViewerState
      let packet = gameSim.buildViewerPacket(
        shared.viewerStates[websocket], next, liveChrome())
      shared.viewerStates[websocket] = next
      try:
        websocket.send(blobFromBytes(packet), BinaryMessage)
      except CatchableError:
        discard

proc applyRegistration(slot: int, text: string): bool =
  ## The seat's registration blob. Any OTHER chat text from the seat is dropped
  ## — the cog speaks through `say`, never through the socket.
  var payload: JsonNode
  try:
    payload = parseJson(text)
  except CatchableError:
    return false
  if payload.isNil or payload.kind != JObject:
    return false
  if not payload.hasKey("policy") and not payload.hasKey("prompt") and
      not payload.hasKey("scripted"):
    return false
  var prompt = payload{"prompt"}.getStr().truncateRunes(MaxPromptRunes)
  let scriptedNode = payload{"scripted"}
  var scriptedName = ""
  if not scriptedNode.isNil and scriptedNode.kind == JString:
    scriptedName = scriptedNode.getStr().strip()
  var isLlm = prompt.strip().len > 0
  if scriptedName.len > 0:
    isLlm = false
  withLock stateLock:
    shared.prompts[slot] = prompt
    shared.isLlm[slot] = isLlm
    shared.scripted[slot] =
      if scriptedName.len > 0: parseBaseline(scriptedName) else: blPusher
    shared.policies[slot] =
      payload{"policy"}.getStr().truncateRunes(MaxPolicyLabelRunes)
    if shared.policies[slot].len == 0:
      shared.policies[slot] =
        if isLlm: "llm" else: $shared.scripted[slot]
    ## Name resolution, in order: the registration blob, then the name the
    ## platform put on the socket URL, then — only when neither exists — the
    ## policy label, which is what a local run has. The alias (`Alpha`) is a
    ## different name space and never appears here.
    let registeredName =
      payload{"name"}.getStr().strip().truncateRunes(MaxPolicyLabelRunes)
    if registeredName.len > 0:
      shared.names[slot] = registeredName
    elif shared.names[slot].len == 0:
      shared.names[slot] = shared.policies[slot]
    shared.registered[slot] = true
    shared.everRegistered[slot] = true
  echo "sokoban: slot ", slot, " registered (", prompt.len, " prompt chars",
    (if isLlm: ", llm" else: ", scripted " & scriptedName), ")"
  true

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global AND /player to check the game is alive, so an unanswered ping
      ## fails certification. NOTHING else is guarded here: a
      ## `kind != TextMessage` guard drops the player's BINARY registration
      ## frames (lux-ai 0.1.0, snake-royale 0.1.0).
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        # A global viewer's transport command.
        withLock stateLock:
          if websocket in shared.viewerStates:
            var state = shared.viewerStates[websocket]
            state.applyGlobalViewerMessage(message.data)
            state.replayCommands.setLen(0)
            state.replaySeekTick = -1
            shared.viewerStates[websocket] = state
        return
      # The seat registers through the Sprite v1 chat channel (0x81) or, for a
      # plain text client, as a bare JSON frame.
      var handled = false
      for item in message.data.parseSpriteClientMessages():
        if item.kind == SpriteClientChatMessage:
          if applyRegistration(slot, item.text):
            handled = true
      if not handled:
        discard applyRegistration(slot, message.data)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let closing = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(closing) == websocket:
            shared.playerSockets.del(closing)
          ## A seat that drops keeps playing: nothing a player container does
          ## can stop the clock.
          shared.registered[closing] = shared.everRegistered[closing]
        shared.globalSockets.excl(websocket)
        shared.viewerStates.del(websocket)

proc buildRouter(replayMode: bool): Router =
  ## The certifier's probes are registered BEFORE the catch-all asset route.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/replay", replayPageHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  replayPayload = runtimeConfig.replay
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "sokoban: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc stopServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(SokobanError,
      "tokens must name exactly num_agents seats")
  runtimeCfg = runtimeConfig
  eventsSinkPath = requireFileUri("COGAME_EVENTS_URI")
  gameSim = newSimServer(config)
  shared.seats = config.numAgents
  shared.prompts = newSeq[string](shared.seats)
  shared.scripted = newSeq[Baseline](shared.seats)
  shared.isLlm = newSeq[bool](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.names = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  for slot in 0 ..< shared.seats:
    shared.policies[slot] = "pusher"
    shared.names[slot] = ""
  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, runtimeConfig)
  echo "sokoban: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
