## Player-owned request spacing for model policies.

import std/[monotimes, os, strutils, times]
import bitworld/[native_http, native_stop]

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

proc acquire*(pacer: var ModelPacer, deadline: MonoTime,
    control: var NativeRequestControl) =
  let remainingMs = (deadline - getMonoTime()).inMilliseconds.int
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
      let readyAt = now + initDuration(milliseconds = waitMs)
      while getMonoTime() < readyAt:
        if interruptionRequested() or control.nativeRequestCanceled():
          raise newException(RateGuardError, "model request pacing interrupted")
        sleep(min(10, max(1, (readyAt - getMonoTime()).inMilliseconds.int)))
  if interruptionRequested() or control.nativeRequestCanceled() or getMonoTime() >= deadline:
    raise newException(RateGuardError, "model request cannot start after stop or deadline")
  pacer.lastStart = getMonoTime()
  pacer.started = true
  pacer.requestTimes.add(pacer.lastStart)
