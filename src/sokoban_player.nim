## Sokoban player: a policy is just a prompt.
##
## The player container is deliberately thin. It connects, sends ONE
## registration blob carrying its prompt (or its baseline name), and thereafter
## only acknowledges frames: every decision is made inside the GAME server,
## which sends this seat's prompt plus its board view to Claude once per turn.
## The `anthropic_api_key` coworld secret is injected into the game pod, so no
## `USE_BEDROCK` flag is needed on the policy.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy coworld-sokoban --name my-sokoban \
##     --run /bin/sokoban-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils, times]
import bitworld/spriteprotocol
import whisky
import sokoban/sim_types

const
  ConnectAttempts = 6
  ConnectBackoffMs = 250
  ReRegisterSeconds = 10.0
    ## The registration blob is RE-SENT for the first ~10 s of received frames:
    ## a first send can race the server's slot bookkeeping and the seat then
    ## plays the default baseline for the whole episode with no error anywhere
    ## (the paintball 2026-08-25 slot-sequential-join scar).

when isMainModule:
  var url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    url = getEnv("COGAMES_ENGINE_WS_URL")   ## the legacy alias
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT").truncateRunes(MaxPromptRunes)
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  let label = getEnv("PLAYER_POLICY_LABEL").truncateRunes(MaxPolicyLabelRunes)

  let registration = $(%*{
    "policy": (if label.len > 0: label
               elif prompt.strip().len > 0: "llm"
               elif scripted.len > 0: scripted
               else: "pusher"),
    "prompt": prompt,
    "scripted": (if scripted.len > 0: %scripted else: newJNull())
  })

  var socket: WebSocket = nil
  for attempt in 1 .. ConnectAttempts:
    try:
      socket = newWebSocket(url)
      break
    except CatchableError as error:
      echo "sokoban player: connect attempt ", attempt, " failed: ", error.msg
      if attempt == ConnectAttempts:
        ## A bounded retry, then leave quietly: the game declares the no-show
        ## itself and plays the seat on the pusher baseline.
        echo "sokoban player: giving up on ", url
        quit(0)
      sleep(ConnectBackoffMs * attempt)

  proc sendRegistration() =
    try:
      socket.send(blobFromSpriteChat(registration), BinaryMessage)
    except CatchableError as error:
      echo "sokoban player: registration send failed: ", error.msg

  sendRegistration()
  echo "sokoban player: registered (", prompt.len, " prompt chars",
    (if scripted.len > 0: ", scripted " & scripted else: ", llm"), ")"

  let started = epochTime()
  while true:
    ## whisky's `receiveMessage` RAISES rather than returning none on both a
    ## close frame and a half-read one, and mummy's `send` only queues: the
    ## game writes its artifacts and exits, so a seat can lose the socket
    ## before its `done` frame is flushed. EXIT 0 on a dead socket — a player
    ## that dies here fails certification with `player_error` (the raid 0.1.3
    ## close-frame race).
    var received: Option[Message]
    try:
      received = socket.receiveMessage()
    except CatchableError as error:
      echo "sokoban player: connection ended (", error.msg, "), exiting"
      break
    if received.isNone:
      echo "sokoban player: connection closed, exiting"
      break
    if epochTime() - started < ReRegisterSeconds:
      sendRegistration()
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      if payload{"done"}.getBool():
        echo "sokoban player: final score ", payload{"result"}{"scores"}
        break
      case payload{"type"}.getStr()
      of "welcome":
        echo "sokoban player: seated at slot ", payload{"slot"}.getInt(),
          " as ", payload{"alias"}.getStr()
        sendRegistration()
      else:
        discard
    except CatchableError as error:
      echo "sokoban player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
