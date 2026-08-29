# cogame-sokoban

**SA Sokoban — push every crate onto a marked square; one wrong push and the
level is dead.**

One cog, alone, in a 10 × 10 walled room with four crates and four marked
squares. It can walk, and when it walks into a crate the crate slides one square
ahead of it. **It can never pull.** A crate shoved into a corner is there
forever; two crates shoved side by side against a wall are there forever; the
level is over the instant the position becomes unwinnable — and the replay says
so out loud with a **DEADLOCK CREATED** marker on the scrubber.

An episode is a ladder of **six levels**, each generated fresh from the
episode's secret seed by reverse play from the solved position, each labelled
with the tier it was built to (`unfiltered`, `medium`, `hard`) and its **exact**
optimal push count, each with a hard budget of **200 moves**. The league reads
one number: the tier-weighted count of levels solved.

Sokoban is PSPACE-complete and has no useful local signal: there is no gradient
toward the goal, and the difference between a solved level and a dead one is
usually a single push made in the wrong order. That is exactly what this coworld
exists to measure.

**A policy is just a prompt.** The game server composes the seat's board view
plus that seat's `PLAYER_PROMPT` and asks Claude what the cog does for the next
twenty moves.

- [docs/RULES.md](docs/RULES.md) — the board, the primitives, deadlock
  detection, scoring, the end conditions.
- [docs/ACTIONS.md](docs/ACTIONS.md) — the observation, the reply schema and its
  caps, and how a plan becomes moves.
- [docs/LEVELS.md](docs/LEVELS.md) — the reverse-play generator, and every
  documented divergence from gym-sokoban and Boxoban.
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — the Coworld contract, the player
  protocol and the replay format.
- [docs/plans/](docs/plans/) — the accepted design note this repo implements.

## Field your own policy

```bash
coworld upload-policy coworld-sokoban --name my-sokoban \
  --run /bin/sokoban-player \
  --secret-env PLAYER_PROMPT="Simulate before you commit. Never push a crate
you have not first checked three ways. …"
```

The same image also ships two scripted baselines, selected by env — no prompt,
no LLM call:

```bash
PLAYER_SCRIPTED=pusher    # a bounded best-first search over push space
PLAYER_SCRIPTED=nudger    # one ply, no lookahead: the floor
```

`tools/ci/policies.json` is the shipped set: two `PLAYER_PROMPT` champions
(`sokoban-lookahead`, `sokoban-orderfirst`) and those two baselines as league
fillers — one image, env-switched, so a champion and a filler are byte-identical
apart from their environment.

## Layout

| Path | What |
|---|---|
| `src/sokoban/` | the sim: `grid`, `deadlock`, `levelgen`, `search`, `driver`, `baselines`, `sim`, plus the server, the decision layer and the LLM client |
| `src/sokoban.nim` | the game entrypoint (`/bin/sokoban`) |
| `src/sokoban_player.nim` | the thin seat registrar (`/bin/sokoban-player`) |
| `client/` | the broadcast chrome, inherited from `coworld-ctf` |
| `replay-viewer/` | the wasm entry, the emscripten flags and the static shell |
| `tools/` | the build hook, the baseline sweep, the forensics scripts |
| `tests/` | the Nim suite CI runs in debug **and** release |
| `scripts/art/` | the nano-banana source sheets and the split script |

## Building and testing

The image builds two binaries from one tree:

```bash
docker build -t coworld-sokoban:ci .
tools/ci/docker_smoke.sh coworld-sokoban:ci      # one real episode in raw docker
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

Tests run from the repo **root**:

```bash
nim r --path:src tests/test_sokoban_sim.nim
```

`ci.yml` runs every `tests/*.nim` twice, debug and release. The generator is a
bounded backward BFS, so the sweeps are sized from `SweepSeeds` in
`tests/helpers.nim`: eight seeds in a release run, two in a debug one.

## The viewer

The replay is a **static wasm bundle, never a pod**. `tools/build_replay_viewer.sh`
compiles `replay-viewer/sokoban_replay.nim` — which imports the **same**
`src/sokoban/sim.nim` the server runs — through the pinned
`emscripten/emsdk:4.0.15` container, and the browser re-derives every frame from
the recorded boards and plans, checking `gameHash` at every tick.

The chrome is `coworld-ctf`'s, not a lookalike: `client/chrome_common.js` is
byte-for-byte the starter's (its sha256 is pinned as a literal in
`tests/test_sokoban_viewer.nim`), and `client/replay_broadcast.html` is the
starter's page with this game's block appended under a banner comment.
`scripts/build_broadcast_page.py` derives it from a fresh checkout of the
starter, so the provenance is mechanical and checkable.

## Board art

The cog is a **nano-banana render of the Softmax cog** — one kit, because this
is a solitaire puzzle — in its four board facings, plus the crate in its two
states and the marked square. The source sheets and the split script are
committed under `scripts/art/`; CI never regenerates art.

    python3 scripts/art/gen_sokoban_art.py     # needs GEMINI_API_KEY
    python3 scripts/art/split_sheets.py

## License

MIT — see [LICENSE](LICENSE).
