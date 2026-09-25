import std/[os, unittest]
import sokoban/model_pacing

suite "player model pacing":
  test "a turn without time for the rate floor falls back before a call":
    putEnv("PLAYER_MODEL_SPACING_MS", "1000")
    var pacer = newModelPacer()
    pacer.acquire(2000)
    expect RateGuardError:
      pacer.acquire(500)

  test "the rolling request cap refuses a twenty-ninth call":
    putEnv("PLAYER_MODEL_SPACING_MS", "0")
    var pacer = newModelPacer()
    for _ in 0 ..< 28:
      pacer.acquire(2000)
    expect RateGuardError:
      pacer.acquire(2000)
