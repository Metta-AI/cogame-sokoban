## Hosted calls must reach the native sidecar without provider credentials.
import std/unittest
include "../src/sokoban/player_llm"

block:
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:9100/")
  putEnv("COWORLD_LLM_MODEL", "anthropic/claude-sonnet-4.6")
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://retired.invalid")
  putEnv("ANTHROPIC_API_KEY", "local-key-must-not-be-used")
  let client = newLlmClient()
  for slot in 0 .. 1:
    let request = client.requestFor("rules", "private view", slot)
    doAssert request.url == "http://127.0.0.1:9100/v1/messages"
    doAssert request.headers["X-Coworld-Player-Slot"] == $slot
    let body = parseJson(request.body)
    doAssert body["model"].getStr() == "anthropic/claude-sonnet-4.6"
    doAssert not body.hasKey("anthropic_version")
    doAssert not body.hasKey("output_config")
  echo "hosted sidecar routing and seat attribution passed"

suite "sampling mode binds the original request temperature":
  test "unit and explicit tempered modes stay distinct; malformed modes preserve raw evidence":
    # Synthetic transport values exercise the parser, without platform receipt authority.
    for scenario in [
        ("full_softmax_temperature_one", 1.0, none(float), true),
        ("full_softmax", 0.4, some(0.4), true),
        ("full_softmax", 1.0, some(1.0), true),
        ("full_softmax_temperature_one", 0.4, none(float), false),
        ("full_softmax_temperature_one", 1.0, some(1.0), false),
        ("full_softmax", 0.4, some(1.0), false),
        ("full_softmax", 1.0, none(float), false),
        ("full_softmax", 1.0, some(0.0), false),
        ("unknown", 1.0, none(float), false)]:
      let client = newLlmClient()
      client.temperature = scenario[1]
      client.maxOutputTokens = 2
      client.lastAttempt = newDecisionAttempt("test-sampler", "synthetic-test", aoModel)
      client.lastAttempt.request = parseJson(client.requestFor("rules", "view", 0).body)
      var sampling = %*{"sampling": scenario[0], "prompt_token_ids": [1],
        "completion_token_ids": [2], "behavior_log_probs": [-0.4], "stop_reason": "eos",
        "policy_revision": "synthetic-test", "tokenizer_revision": "synthetic-test",
        "chat_template": "synthetic-test", "enable_thinking": false,
        "max_new_tokens": 2, "max_sequence_length": 4, "sampling_seed": 0,
        "eos_token_ids": [2], "response": "reply"}
      if scenario[2].isSome: sampling["temperature"] = %scenario[2].get()
      let raw = $(%*{"model": "fixture-model", "content": [{"type": "text", "text": "reply"}],
        "stop_reason": "end_turn", "sampling_evidence": sampling})
      let response = NativeHttpResponse(kind: nhComplete, httpStatus: some(200),
        headerBytes: "HTTP/1.1 200 OK\r\n\r\n", bodyBytes: raw,
        transferComplete: true, responseReaderJoined: some(true))
      if scenario[3]:
        check client.textOf(response) == "reply"
        check client.lastAttempt.behaviorLogprobs == some(@[-0.4])
      else:
        expect LlmError:
          discard client.textOf(response)
        check client.lastAttempt.behaviorLogprobs.isNone
      check client.lastAttempt.rawResponse == %raw
      check client.lastAttempt.platformCallId.isNone

  test "greedy response carries no sampled probabilities":
    let client = newLlmClient()
    client.temperature = 0
    client.lastAttempt = newDecisionAttempt("test-greedy", "synthetic-test", aoModel)
    client.lastAttempt.request = parseJson(client.requestFor("rules", "view", 0).body)
    let response = NativeHttpResponse(kind: nhComplete, httpStatus: some(200),
      headerBytes: "HTTP/1.1 200 OK\r\n\r\n", transferComplete: true,
      responseReaderJoined: some(true), bodyBytes: $(%*{"model": "fixture-model",
        "content": [{"type": "text", "text": "reply"}], "stop_reason": "end_turn",
        "sampling_evidence": newJNull()}))
    check client.textOf(response) == "reply"
    check client.lastAttempt.behaviorLogprobs.isNone
    check client.lastAttempt.promptTokenIds.isNone
