## Prompt decisions run in the player against the ordinary observation.

import std/[json, monotimes, options, times]
import bitworld/[decision_trajectory, native_http, native_stop]
import directives, model_pacing, player_llm, prompt_render

proc choosePromptPlan*(client: LlmClient, pacer: var ModelPacer,
    view: JsonNode, prompt: string, maxActions: int, deadline: MonoTime,
    slot: int, decisionId, policy: string, control: var NativeRequestControl,
    progress: proc(attempt: DecisionAttempt) {.closure, gcsafe.}): JsonNode =
  client.attempts.setLen(0)
  if client.disabled:
    raise newException(LlmError, "native inference endpoint is not configured")
  for attempt in 0 .. 1:
    if interruptionRequested() or control.nativeRequestCanceled() or
        (deadline - getMonoTime()).inMilliseconds <= 500:
      break
    pacer.acquire(deadline, control)
    let requestDeadline = min(deadline - initDuration(milliseconds = 500),
      getMonoTime() + initDuration(seconds = if attempt == 0: 6 else: 3))
    try:
      let reply = client.call(SystemPrompt, userMessage(prompt, $view),
        requestDeadline, slot, decisionId & "-" & $attempt, policy,
        control, progress)
      let parsedReply = parseReplyObject(reply)
      if parsedReply.kind == rokRejected:
        raise newException(DirectiveError, parsedReply.reason)
      let directive = parseDirective(parsedReply.payload, maxActions)
      let action = directive.directiveJson()
      client.lastAttempt.parsedAction = action
      client.lastAttempt.accepted = true
      client.attempts.add(client.lastAttempt)
      progress(client.lastAttempt)
      return parsedReply.payload
    except CatchableError:
      # This existing parse-to-result boundary retains private bytes separately.
      client.lastAttempt.rejectionReason = some("native_or_directive_rejected")
      client.attempts.add(client.lastAttempt)
      progress(client.lastAttempt)
      if client.disabled or client.throttled or interruptionRequested() or
          control.nativeRequestCanceled():
        break
  raise newException(LlmError, "no usable native directive before the turn deadline")
