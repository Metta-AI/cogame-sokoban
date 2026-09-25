## Jev ranks ordinary Sokoban plans from the public turn observation.

import std/[json, monotimes, os, strutils, times]
import curly
import baselines, directives, model_pacing, policy_view

proc chooseJevPlan*(view: JsonNode, pacer: var ModelPacer,
    budgetMs: int): JsonNode =
  let started = getMonoTime()
  var candidates = newJObject()
  for kind in [blPusher, blNudger]:
    let plan = scriptedPlanForView(view, kind)
    candidates[$kind] = %*{"actions": plan.actionsJson()}
  for i in 0 ..< view["pushes_available"].len:
    let push = view["pushes_available"][i]
    candidates["push_" & $i] = %*{"actions": [{
      "do": "push", "box": push["box"], "dir": push["dir"]}]}
  var criteria = newJObject()
  for name, plan in candidates.pairs:
    criteria[name] = %($plan)

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Sokoban Jev policy has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = "0"
  let body = %*{
    "model": model,
    "state": "You are playing a 10x10 Sokoban level. Push all four boxes " &
      "onto targets without deadlocking. Boxes cannot be pulled. Choose " &
      "the plan most likely to solve the level while minimizing moves. " &
      "The observation is the complete information available to this seat:\n" &
      $view,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the best legal turn plan. The plan runs for at " &
        "most the moves_per_turn shown in the observation.",
      "criteria": criteria
    }}
  }
  pacer.acquire(budgetMs - (getMonoTime() - started).inMilliseconds.int)
  let remaining = budgetMs - (getMonoTime() - started).inMilliseconds.int
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body,
    max(1, (remaining - 500) div 1000))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "sokoban Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  candidates[selected]
