## Player-owned request spacing for model policies.

import std/[monotimes, os, strutils, times]

type
  RateGuardError* = object of ValueError

  ModelPacer* = object
    spacingMs: int
    lastStart: MonoTime
    started: bool
    requestTimes: seq[MonoTime]

proc newModelPacer*(): ModelPacer =
  result.spacingMs = max(0,
    getEnv("PLAYER_MODEL_SPACING_MS", "2600").parseInt())

proc acquire*(pacer: var ModelPacer, remainingMs: int) =
  const RollingWindowSeconds = 60
  const RollingRequestCap = 28
  if remainingMs <= 500:
    raise newException(RateGuardError, "no time left for a model request")
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in pacer.requestTimes:
    if (now - stamp).inSeconds < RollingWindowSeconds:
      kept.add(stamp)
  pacer.requestTimes = kept
  if pacer.requestTimes.len >= RollingRequestCap:
    raise newException(RateGuardError, "rolling model request cap reached")
  if pacer.started:
    let since = (now - pacer.lastStart).inMilliseconds.int
    let waitMs = max(0, pacer.spacingMs - since)
    if waitMs + 500 >= remainingMs:
      raise newException(RateGuardError,
        "model request spacing exceeds this turn's deadline")
    if waitMs > 0:
      sleep(waitMs)
  pacer.lastStart = getMonoTime()
  pacer.started = true
  pacer.requestTimes.add(pacer.lastStart)
