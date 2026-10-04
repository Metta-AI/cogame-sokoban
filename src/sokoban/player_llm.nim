## Native sidecar transport for the canonical private Sokoban prompt.
## The request owner keeps its control alive until the synchronous reader joins.

import std/[base64, json, math, monotimes, options, os, sets, strutils, tables]
import bitworld/[decision_trajectory, native_http]
from std/unicode import validateUtf8

const AnthropicVersion = "2023-06-01"

type
  LlmError* = object of ValueError
  LlmClient* = ref object
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    temperature*: float
    disabled*: bool
    lastAttempt*: DecisionAttempt
    attempts*: seq[DecisionAttempt]

proc newLlmClient*(): LlmClient =
  result = LlmClient(
    model: getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5"),
    temperature: getEnv("COWORLD_LLM_TEMPERATURE", "1").parseFloat(),
    maxOutputTokens: getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900").parseInt())
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(LlmError, "COWORLD_LLM_TEMPERATURE must be finite and in 0..1")
  if result.maxOutputTokens <= 0:
    raise newException(LlmError, "PLAYER_MAX_OUTPUT_TOKENS must be positive")
  result.sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip().strip(
    chars = {'/'}, leading = false)
  result.disabled = result.sidecarEndpoint.len == 0

proc requestFor*(client: LlmClient, system, user: string,
    slot: int): tuple[url: string, headers: HttpHeaders, body: string] =
  if slot < 0:
    raise newException(LlmError, "native inference requires the issued player slot")
  if client.disabled:
    raise newException(LlmError, "native inference endpoint is not configured")
  result.url = client.sidecarEndpoint & "/v1/messages"
  result.headers["content-type"] = "application/json"
  result.headers["anthropic-version"] = AnthropicVersion
  result.headers["X-Coworld-Player-Slot"] = $slot
  result.body = $(%*{"model": client.model,
    "max_tokens": client.maxOutputTokens, "temperature": client.temperature,
    "system": system, "messages": [{"role": "user", "content": user}]})

proc textOf*(client: LlmClient, response: NativeHttpResponse): string =
  client.lastAttempt.latencyMs = response.latencyMs
  client.lastAttempt.responseReaderJoined = response.responseReaderJoined
  let observedResponse = response.httpStatus.isSome or response.headerBytes.len > 0 or response.bodyBytes.len > 0
  if observedResponse:
    client.lastAttempt.responseBodyB64 = some(encode(response.bodyBytes))
    client.lastAttempt.responseHeadersB64 = some(encode(response.headerBytes))
    client.lastAttempt.responseComplete = some(response.transferComplete)
    client.lastAttempt.httpStatus = response.httpStatus
    if validateUtf8(response.bodyBytes) == -1:
      client.lastAttempt.rawResponse = %response.bodyBytes
  if validateUtf8(response.headerBytes) != -1:
    raise newException(LlmError, "received HTTP headers are not valid UTF-8")
  var responseHeaders: HttpHeaders
  var receivedHeaders = initTable[string, string]()
  var identityHeaders = initHashSet[string]()
  for line in response.headerBytes.splitLines():
    if line.startsWith("HTTP/"):
      responseHeaders.setLen(0)
      receivedHeaders.clear()
      identityHeaders.clear()
    elif line.len > 0:
      let colon = line.find(':')
      if colon <= 0:
        raise newException(LlmError, "invalid received HTTP header")
      let name = line[0 ..< colon]
      let value = line[colon + 1 .. ^1].strip()
      let normalized = name.toLowerAscii()
      if normalized in ["request-id", "x-request-id", "x-softmax-llm-call-id",
          "x-coworld-checkpoint-sha256", "x-coworld-tokenizer-sha256",
          "x-coworld-chat-template-sha256"]:
        if normalized in identityHeaders:
          raise newException(LlmError, "duplicate received identity header")
        identityHeaders.incl(normalized)
      responseHeaders.add((name, value))
      receivedHeaders[name] = value
  if observedResponse:
    client.lastAttempt.responseHeaders = some(receivedHeaders)
  if responseHeaders.contains("request-id") and responseHeaders.contains("x-request-id") and
      responseHeaders["request-id"] != responseHeaders["x-request-id"]:
    raise newException(LlmError, "conflicting received request identity headers")
  for key in ["request-id", "x-request-id"]:
    if responseHeaders.contains(key):
      client.lastAttempt.providerRequestId = some(responseHeaders[key])
      break
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    if responseHeaders[header].len > 0:
      case field
      of "call":
        let identity = responseHeaders[header]
        if identity.len != 36:
          raise newException(LlmError, "received platform call identity is not a UUID")
        for index, character in identity:
          if index in [8, 13, 18, 23]:
            if character != '-':
              raise newException(LlmError, "received platform call identity is not a UUID")
          elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            raise newException(LlmError, "received platform call identity is not a UUID")
        client.lastAttempt.platformCallId = some(identity)
      of "model": client.lastAttempt.modelIdentity = some(responseHeaders[header])
      of "tokenizer": client.lastAttempt.tokenizerIdentity = some(responseHeaders[header])
      else: client.lastAttempt.chatTemplateSha256 = some(responseHeaders[header])
  if response.kind != nhComplete:
    raise newException(LlmError, "native transport " & $response.kind)
  let status = response.httpStatus.get()
  if status == 401 or status == 403:
    client.disabled = true
    raise newException(LlmError, "native inference auth failed (" & $status & ")")
  if status == 429:
    raise newException(LlmError, "native inference throttled (429)")
  if status < 200 or status >= 300:
    raise newException(LlmError, "native inference error " & $status)
  let payload = parseJson(response.bodyBytes)
  if payload.kind != JObject or payload["model"].kind != JString or
      payload["content"].kind != JArray:
    raise newException(LlmError, "native response violates the completion schema")
  client.lastAttempt.model = some(payload["model"].getStr())
  case payload["stop_reason"].kind
  of JString: client.lastAttempt.stopReason = some(payload["stop_reason"].getStr())
  of JNull: discard
  else: raise newException(LlmError, "native stop reason must be text or null")
  if payload.hasKey("usage") and payload["usage"].kind != JNull:
    let usage = payload["usage"]
    if usage.kind != JObject or usage["input_tokens"].kind != JInt or
        usage["output_tokens"].kind != JInt or usage["input_tokens"].getInt() < 0 or
        usage["output_tokens"].getInt() < 0:
      raise newException(LlmError, "native usage must contain nonnegative integer counts")
    client.lastAttempt.inputTokens = some(usage["input_tokens"].getInt())
    client.lastAttempt.outputTokens = some(usage["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    if sampling.kind != JObject or sampling["prompt_token_ids"].kind != JArray or
        sampling["completion_token_ids"].kind != JArray or sampling["stop_reason"].kind != JString:
      raise newException(LlmError, "native sampling evidence violates the token schema")
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(LlmError, "native prompt token IDs must be nonnegative integers")
      promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(LlmError, "native sampled token IDs must be nonnegative integers")
      sampledIds.add(token.getInt())
    if sampling["behavior_log_probs"].kind != JNull:
      if sampling["behavior_log_probs"].kind != JArray:
        raise newException(LlmError, "native draw probabilities must be an array or null")
      for probability in sampling["behavior_log_probs"]:
        if probability.kind notin {JInt, JFloat} or
            classify(probability.getFloat()) in {fcNan, fcInf, fcNegInf} or probability.getFloat() > 0:
          raise newException(LlmError, "native draw probabilities must be finite nonpositive numbers")
        probabilities.add(probability.getFloat())
      if probabilities.len != sampledIds.len:
        raise newException(LlmError, "native draw probabilities must match sampled token IDs")
    client.lastAttempt.promptTokenIds = some(promptIds)
    client.lastAttempt.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      client.lastAttempt.behaviorLogprobs = some(probabilities)
    client.lastAttempt.stopReason = some(sampling["stop_reason"].getStr())
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock.kind != JObject or contentBlock["type"].kind != JString:
      raise newException(LlmError, "native content block violates the completion schema")
    if contentBlock["type"].getStr() == "text":
      if contentBlock["text"].kind != JString:
        raise newException(LlmError, "native text content must be text")
      result.add(contentBlock["text"].getStr())
  client.lastAttempt.response = %result
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "native reply ended before a JSON action")

proc call*(client: LlmClient, system, user: string, deadline: MonoTime,
    slot: int, attemptId, policy: string, control: var NativeRequestControl,
    beforeCall: proc(attempt: DecisionAttempt) {.closure, gcsafe.}): string =
  let request = client.requestFor(system, user, slot)
  client.lastAttempt = newDecisionAttempt(attemptId, policy, aoModel)
  client.lastAttempt.prompt = %*[{"role": "system", "content": system},
    {"role": "user", "content": user}]
  client.lastAttempt.request = parseJson(request.body)
  client.lastAttempt.model = some(client.model)
  client.lastAttempt.decoder = %*{"temperature": client.temperature,
    "max_tokens": client.maxOutputTokens}
  beforeCall(client.lastAttempt)
  let response = performNativePost(request.url, request.headers, request.body,
    deadline, control)
  client.textOf(response)
