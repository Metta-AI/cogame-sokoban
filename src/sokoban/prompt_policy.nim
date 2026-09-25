## Prompt decisions run in the player against the ordinary observation.

import std/[json, monotimes, times]
import curly
import directives, model_pacing, player_llm

proc choosePromptPlan*(
  client: LlmClient, pacer: var ModelPacer, view: JsonNode, prompt: string,
  maxActions, budgetMs: int
): JsonNode =
  if client.disabled:
    raise newException(LlmError, "LLM provider is unavailable")
  let started = getMonoTime()
  var lastError = "no usable reply"
  for attempt in 0 .. 1:
    var remaining = budgetMs - (getMonoTime() - started).inMilliseconds.int
    if remaining <= 500:
      break
    pacer.acquire(remaining)
    remaining = budgetMs - (getMonoTime() - started).inMilliseconds.int
    let request = client.requestFor(SystemPrompt,
      userMessage(prompt, $view))
    var batch: RequestBatch
    batch.post(request.url, request.headers, request.body, "0")
    let timeout = max(1, min(
      if attempt == 0: 6 else: 3, (remaining - 500) div 1000))
    let responses = client.curl.makeRequests(batch, timeout)
    try:
      let reply = client.textOf(
        responses[0].response, responses[0].error, batch[0].url)
      let directive = parseDirective(extractJsonObject(reply), maxActions)
      return %*{"actions": directive.actionsJson(), "say": directive.say,
                "notes": directive.notes}
    except CatchableError as error:
      lastError = error.msg
      echo "sokoban prompt player: attempt ", attempt + 1,
        " failed: ", lastError
      if client.disabled or client.throttled:
        break
  raise newException(LlmError, lastError)
