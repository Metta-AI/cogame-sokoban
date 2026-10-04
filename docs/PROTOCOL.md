# Protocol

Replay protocol: **`sokoban/v1`**. Player socket protocol:
**`sokoban-player/v3`**.

## The Coworld game contract

In: `COGAME_CONFIG_URI`.
Out: `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI`. Private checkpoint:
`COGAME_SAVE_TRAJECTORY_URI` with trusted runtime episode, package version,
source revision and registered game identity.
Replay mode: `COGAME_LOAD_REPLAY_URI` + `/client/replay`.
Bind: `COGAME_HOST` / `COGAME_PORT`.

| Route | Purpose |
|---|---|
| `GET /healthz` | liveness |
| `GET /client/player?slot=&token=` | the seat page. Token-checked, and it does **not** open the player socket |
| `GET /client/global` | the spectator page |
| `GET /client/replay` | the broadcast replay page (developer convenience; the hosted viewer is the static wasm bundle) |
| `GET /client/<asset>` | `chrome_common.js`, `broadcast_core.js`, art |
| `GET /replay-data` | the recorded replay bytes, in replay mode |
| `WS /player?slot=N&token=T` | the player protocol. **Closes unless the token matches the seat** |
| `WS /global` | spectator sprite-protocol packets |

`/healthz` and `/global` keep answering for a bounded grace after the artifacts
are written, then the process exits.

`websocketHandler` answers a `Ping` with `socket.send(message.data, Pong)` and
guards **nothing else**: a `kind != TextMessage` guard would drop the player's
binary registration frames.

## The player protocol

After `welcome`, the seat sends one registration as a Sprite v1 binary chat
frame (`0x81`). Registration freezes when the game starts:

```json
{"type":"register","policy":"label","kind":"llm","prompt":"operator instructions","scripted":null}
```

`policy` is rune-truncated at 64; the private operator prompt at 4000. The
prompt reaches the authenticated game solely for exact private request joins.
Public replay records only the policy label and kind. Native inference stays
in the platform-hosted player container, through `COWORLD_LLM_ENDPOINT` and
`COWORLD_LLM_MODEL` with the authenticated welcome slot.

Each command turn has an engine-issued string identity and a separate
transport budget. The observation contains no transport metadata:

```json
{"type":"decision","decision_id":"sokoban-23","observation":{"board":["…"]},
 "max_actions":8,"transport":{"budget_ms":9000,"cleanup_budget_ms":5000}}
```

Before native HTTP begins, the player sends `attempt_started` with the issued
`decision_id` and singular `training_attempt`. The private attempt includes
its exact prompt/request and no observed response facts. Later progress keeps
request identity fixed and preserves received byte prefixes. Finished facts
cannot change after reader join.

```json
{"type":"action","decision_id":"sokoban-23","source":"llm",
 "action":{"actions":[{"do":"push","box":1,"dir":"R"}],"say":"right crate first","notes":"keep box 0 parked"},
 "training_attempt":{"attempt_id":"sokoban-23-0"}}
```

The example abbreviates the required private attempt envelope. Native actions
require actual complete, joined transport evidence. The engine independently
checks raw response text, normal parser output and applied directive. Scripted
and fallback actions use `training_attempt:null`; submitted teacher assertions
never gain source-controlled teacher authority.

`source` is `llm`, `scripted`, or `fallback` for replay attribution. Missing,
invalid or late actions use the ordinary private-view pusher fallback. Repaired
or over-cap native proposals keep their actual applied gameplay but cannot
be accepted model labels.

At termination, `stop` supplies the latest `decision_id`, a random `stop_id`
and bounded `cleanup_budget_ms`. Every registered seat must stop and join its
owned request worker. It returns `stopped` with both IDs, `worker_status`
(`joined` or `no_active_call`) and all actual attempts. The game retains private
facts before returning `evidence_received` with the same IDs; the player waits
for that receipt before closing.

Disconnected or unacknowledged registered owners produce private truncation,
without normal public result or replay. Private sealing/upload finishes before
completed `done` and public artifacts. A failed private upload propagates and
does not reopen sealing or permit later public writes.

A seat that never connects or fails a decision is driven by `pusher`; the
ladder still reaches its natural end. A no-show sets `deadSeats[0] = true` and
is reported once to
`COGAME_PLAYER_FAILURE_URI` with the platform's **closed** payload — exactly
`{"message", "failed_policy_index"}`.

## The replay

Binary, magic **`COWLDSOK`**. Everything the viewer needs is in the bytes; no
server is contacted except S3 for the file.

| Content | Carries |
|---|---|
| header | magic, format version, `gameName` `sokoban`, `gameVersion`, protocol |
| config JSON | `seed`, `variant`, `num_agents`, every rule constant, the tier ladder, `players[].name`, `slots[]`, `fastMode` |
| levels | per level: ten XSB rows, `tier`, `optPushes`, the dead-square list, `tierRelaxed` |
| plans | per turn: the accepted action list — this game's entire input log |
| chats | `register` / `directive` / `fallback` / `stop` / `result` |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

**The level grids are recorded, not regenerated**: the generator is a bounded
BFS costing hundreds of milliseconds per level, and paying that on viewer load
would delay the first drawn frame for no benefit.

**The wall-clock stop is a load-bearing record, not an inference.** A wall-clock
fact cannot be re-derived from sim state, so the stop is written as one record
applied by the *same proc* on record and on playback.

`gameHash` mixes, in this fixed order: `levelIndex`, `levelMove`; the cog's
`(x, y)`; every cell in ascending `(y, x)` as `(isWall, isTarget, hasBox)`;
`boxesOnTargets`, `levelBoxesPlaced`, `pushes`, `blockedMoves`; the six
`levelOutcome` codes and six `levelBoxesPlaced` values; then `tick`.

`tools/replay_summary.py` (Python 3 stdlib only) prints one strict-UTF-8 JSON
object summarising a `.replay`, which is what phase 60's definition-of-done
check reads.

## The tier-2 analysis stream

`COGAME_EVENTS_URI` gets JSON lines with `SimEventKind` in
`{LevelStart, TurnStart, Directive, Fallback, Move, Push, BoxOn, BoxOff,
Deadlock, Solved, Failed}` plus a mandatory trailing summary row (`type`,
`ticks`, `events`, `gameVersion`). `Move` is the per-tick row that makes this
stream a full action trace.

## Results

A closed schema; `game.results_schema` in the manifest lists exactly these keys.
See [RULES.md](RULES.md) for the scoring formula and the end conditions.
