import std/[monotimes, os, times, unittest]
import bitworld/native_http
import sokoban/model_pacing

suite "player model pacing":
  test "a turn without time for the rate floor falls back before a call":
    putEnv("PLAYER_MODEL_SPACING_MS", "1000")
    var pacer = newModelPacer()
    var control: NativeRequestControl
    pacer.acquire(getMonoTime() + initDuration(milliseconds = 2000), control)
    expect RateGuardError:
      pacer.acquire(getMonoTime() + initDuration(milliseconds = 500), control)

  test "the rolling request cap refuses a twenty-ninth call":
    putEnv("PLAYER_MODEL_SPACING_MS", "0")
    var pacer = newModelPacer()
    var control: NativeRequestControl
    for _ in 0 ..< 28:
      pacer.acquire(getMonoTime() + initDuration(milliseconds = 2000), control)
    expect RateGuardError:
      pacer.acquire(getMonoTime() + initDuration(milliseconds = 2000), control)

  test "canceled owner cannot start a model request":
    putEnv("PLAYER_MODEL_SPACING_MS", "0")
    var pacer = newModelPacer()
    var control: NativeRequestControl
    control.cancelNativeRequest()
    expect RateGuardError:
      pacer.acquire(getMonoTime() + initDuration(milliseconds = 2000), control)
