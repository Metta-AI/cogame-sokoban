## CPU transport fixture: calls the ordinary prompt/parser and preserves private attempts.
import std/[json, monotimes, os, strutils, times]
import bitworld/[decision_trajectory, native_http, native_stop]
import sokoban/[model_pacing, player_llm, prompt_policy]

when isMainModule:
  installNativeStopHandlers()
  let client = newLlmClient()
  var pacer = newModelPacer()
  var control: NativeRequestControl
  let deadline = getMonoTime() + initDuration(
    milliseconds = getEnv("PROBE_BUDGET_MS", "1000").parseInt())
  var progressCount = 0
  try:
    let action = choosePromptPlan(client, pacer, %*{"fixture": "private-view"},
      "private-operator", 4, deadline, 0, "probe-decision", "fixture-only",
      control, proc(attempt: DecisionAttempt) {.gcsafe.} = inc progressCount)
    doAssert action["actions"].kind == JArray
    echo "accepted_attempts=", client.attempts.len
  finally:
    var attempts = newJArray()
    for attempt in client.attempts:
      attempts.add(attempt.attemptEvidenceJson())
    writePrivate(getEnv("PROBE_PRIVATE_PATH"), $ %*{
      "fixture_only": true, "progress_count": progressCount,
      "attempts": attempts})
