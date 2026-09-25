## Claude transport for prompt policies in the player container.
##
## Forked from `coworld-ctf`'s `src/ctf/llm.nim` behaviour for behaviour — the
## credential ladder, the Bedrock model rotation, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all that file's, because they
## are all scar tissue from real hosted failures.
##
## Sokoban is a SINGLE-SEAT SEQUENTIAL game, so the starter's
## one-parallel-batch-per-turn machinery (`curly.makeRequests`) carries a BATCH
## OF ONE and is otherwise untouched: exactly one request per turn, plus at most
## one retry, and never more than one in flight.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to the
## scripted layer INSTANTLY, with no network wait — which is what lets offline
## certification finish in seconds.

import std/[json, os, strutils]
import bitworld/runtime
import curly
import sim_types

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  JsonPrefill = "{"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "sokoban llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; `BEDROCK_MODEL` pins
  ## one. `us.anthropic.claude-sonnet-4-6` is DELIBERATELY NOT A CANDIDATE: it
  ## times out on every sidecar call (cogame-raid round 2, 2026-08-23), and one
  ## throttle then cascades into a whole episode of scripted fallbacks.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "sokoban llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(): LlmClient =
  result = LlmClient(
    model: getEnv("PLAYER_MODEL", "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1,
      getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900").parseInt())
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "sokoban llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "sokoban llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The player logs missing credentials and falls back through its own
    ## ordinary action reply.
    echo "sokoban llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live. The
  ## assistant turn is PREFILLED with `{` — both Anthropic Messages and Bedrock
  ## invoke accept it — so the model cannot spend its whole budget on preamble
  ## before the JSON (the cogame-procgen 0.1.2 `cut off at max_tokens` fix,
  ## taken from day one rather than after the fact).
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [
      {"role": "user", "content": user},
      {"role": "assistant", "content": JsonPrefill}
    ]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc rePrefix*(text: string): string =
  ## The prefill is re-prefixed before parsing, and a provider that ECHOES the
  ## prefill is guarded: `extractJsonObject` would otherwise see `{{...}`.
  let head = text.strip()
  if head.startsWith(JsonPrefill):
    head
  else:
    JsonPrefill & text

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one reply, or an LlmError describing why there is none. Auth
  ## failure disables the client for the rest of the episode; model-access
  ## denial and throttling rotate the Bedrock model for the next call instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  ## <= 8 x MaxReplyBytes of provider envelope is read before parsing, and the
  ## cut lands on a RUNE boundary: a plain byte slice can split a codepoint,
  ## and `std/json` does not validate UTF-8, so half a codepoint parses
  ## happily and rides `say`/`notes` into the replay.
  let payload = parseJson(response.body.truncateUtf8Bytes(MaxReplyBytes * 8))
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  ## <= 4096 bytes read from the provider before parsing (the design note's
  ## reply-schema cap), cut on a RUNE boundary for the same reason: every
  ## string on this path reaches the replay through `say` and `notes`, and
  ## `truncateRunes` downstream only shortens — it cannot repair a codepoint a
  ## byte slice already broke.
  result = result.truncateUtf8Bytes(MaxReplyBytes)
  result = result.rePrefix()
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are one cog alone in a 10x10 Sokoban room. Four crates, four marked
squares. Push every crate onto a marked square.

THE ONE RULE THAT MATTERS
You can only PUSH. You walk into a crate and it slides one square away from
you. You can NEVER pull, never undo, never restart. A crate shoved into a
corner is lost forever, and the level ends the instant the position becomes
unwinnable. Think first. A push you cannot take back is worth ten seconds of
checking.

WHAT YOU GET EACH TURN
- "board": ten rows of ten characters, the WHOLE room, no fog.
    #  wall        (space) floor      .  marked square
    $  crate       *  crate already on a marked square
    @  you         +  you standing on a marked square
  x is the column 0-9 counting left to right, y is the row 0-9 counting top
  to bottom. board[y][x]. Row 0 is the top wall.
- "boxes": the four crates with their index, x and y. Index order is top row
  first, then left to right. It is RECOMPUTED EVERY TURN.
- "targets": the four marked squares.
- "dead_squares": squares from which NO crate can ever reach ANY marked
  square. Push a crate onto one of these and the level is over. This list is
  free; it is the easy half. The hard half is crates that block each other.
- "pushes_available": every push that is legal RIGHT NOW, with the square the
  crate would land on. Cross-check every one against dead_squares yourself.
- "opt_pushes": this level IS solvable in that many pushes. If your plan needs
  three times that, your plan is wrong.

WHAT YOU SEND
One JSON object with up to 8 actions. They run in order, one move per tick,
and everything past 20 moves in a turn is CUT OFF - re-issue it next turn.
  {"do":"push","box":1,"dir":"R","times":2}
        walk to the square you have to stand on and push crate 1 right twice.
        THIS IS YOUR MAIN ACTION. dir is U, D, L or R.
  {"do":"goto","x":5,"y":3}    walk to that floor square (crates block you)
  {"do":"moves","seq":"UULDR"} raw moves, up to 20, from U D L R
  {"do":"wait"}                waste a move

WHAT KILLS A LEVEL
1. A crate on a dead square.
2. Four cells in a 2x2 block that are all wall-or-crate, with any crate in it
   not yet on a marked square. Two crates side by side against a wall is the
   classic one.
3. No legal push left anywhere.
Any of those and the level ends immediately, scored on how many crates you had
parked.

HOW YOU ARE SCORED
Levels solved, weighted by tier: unfiltered 1, medium 2, hard 3. Crates parked
on marked squares is the tie-break, and finishing in fewer moves is the
tie-break after that. Time spent thinking costs nothing. A dead level costs
everything.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the
character { and end with }. No prose, no markdown, no code fences.
{"actions":[{"do":"push","box":1,"dir":"R","times":2}],"say":"<=140 chars","notes":"<=320 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how much
  ## weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  operatorBlock(operatorPrompt) & viewJson
