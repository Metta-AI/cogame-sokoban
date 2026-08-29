# Where the levels come from

**No dataset is downloaded, ever, at build time or at runtime.**

Boxoban's 1.5 M levels are a ~1 GB text corpus in another repo, and a coworld
that fetched it would be neither hermetic nor "held out" — a published corpus is
exactly what a language model may have memorised. Instead
`src/sokoban/levelgen.nim` **generates every level by reverse play from the
solved position**, which is gym-sokoban's own generation method and which yields,
as a free by-product, the **exact** optimal push count that the tiers are defined
by.

## The generator

`generateLevel(seed, levelIndex, tier)`, with
`h(k) = mix64(seed, levelIndex, attempt, k)` — splitmix64 over the mixed words, a
pure **hash**, never a consumed stream:

1. For `attempt = 0 ..< genAttemptCap` (8):
2. Build the room: 10 × 10, the border ring wall, the 8 × 8 interior all floor.
   Draw `8 + (h(1) mod 5)` interior cells and set each to wall. Repeats simply
   re-set the same cell, so the realised wall count may be lower —
   deterministic, no retry loop.
3. **Reject** the attempt if the floor is not 4-connected or has fewer than 44
   cells.
4. Place the 4 marked squares by rejection sampling over the floor list.
5. Compute the static dead-square set `D` (see [RULES.md](RULES.md)).
6. **Backward BFS over push space.** The goal states are crates on the four
   marked squares with the cog anywhere on free floor, normalised to the lowest
   cell of its reachable region. The successor relation is the **pull**: for a
   crate at `q` and direction `d`, the pull is legal iff `q − d` and `q − 2d` are
   free floor and `q − d` is in the cog's reachable region. Because a pull is
   exactly a push run backwards, **BFS depth in this graph IS the minimum number
   of pushes** needed to solve the resulting position.
7. Draw `targetDepth` inside the tier's band. Run the BFS until that depth is
   completed, the queue empties, or `genNodeCap` (200 000) states are dequeued.
8. If `targetDepth` was reached, pick one of the states first discovered at
   exactly that depth. `optPushes = targetDepth`, **exactly**.
9. **Reject** a state with more than one crate already parked. A crate can never
   start on a dead square: every BFS state is reachable from the solved
   position, so every crate in it can reach a marked square by construction —
   an invariant asserted by a test, not assumed.
10. The cog starts at a cell of its own reachable region.
11. If no attempt hit the band, take the attempt whose reached depth is closest,
    set `optPushes` to it and mark `levelTierRelaxed[i]`. The level is still
    solvable and still played; the tier weight is still the declared one,
    because the ladder's shape must not depend on the seed.
12. If no attempt produced a state at depth ≥ 4 — a degenerate room, never
    observed in the sweeps — the generator falls back to the tier's committed
    hand-authored level, `data/levels/fallback_<tier>.xsb`.

Every level is therefore a **pure function of `(seed, levelIndex, tier)`**, needs
no network, and is reproducible from a clone of this repo plus the seed.

**Held out:** the seed is randomised by the runner, never disclosed to the seat,
and spans 2⁶³. Level *k*'s grid is identical no matter what happened in level
*k − 1*, which is what makes per-tier solve rates comparable across policies.

## The committed fallbacks

Three files, one per tier, at the bottom of each band. They are the only fixed
levels in the repo and are also the fixtures the unit tests use.

    data/levels/fallback_unfiltered.xsb
    data/levels/fallback_medium.xsb
    data/levels/fallback_hard.xsb

## Documented divergences from gym-sokoban and Boxoban

1. **No gym-sokoban dependency, no Boxoban levels, and no bit-exactness with
   either.** gym-sokoban is a Python gym package and Boxoban is a downloaded
   corpus; embedding either means a simulator that cannot compile to wasm, so
   the static replay viewer — a non-optional pin — would be impossible, and a
   public corpus is the opposite of "held out". **No score from this coworld is
   comparable to a published Boxoban number.** What is reproduced is the
   *problem*: 10 × 10, four crates, push-only, tiered by difficulty.
2. **Tiers are defined by exact optimal push count**, not by Boxoban's filtering
   procedure (which came from which levels a trained agent could solve, and is
   not reproducible here).
3. **The level ends the instant a deadlock is detected**, rather than letting the
   agent flail until the step cap. The detector is sound, so this never
   truncates a winnable position.
4. **Moves are batched under a driver**, not stepped one per call. One LLM call
   per move would be up to 1 200 calls in a 720 s budget — impossible.
5. **`dead_squares` and `pushes_available` are given to the policy.** Both are
   pure functions of the board; handing them over moves the measurement onto
   push ordering and freeze deadlocks.
6. **Reward shape.** gym-sokoban's reward is a per-step penalty plus a per-crate
   bonus plus a completion bonus. The league needs one rankable integer, so
   tier-weighted solves dominate, crates parked is second and moves saved third.
   All three underlying quantities are in `results`.
7. **No undo, no restart, no pull-mode.** Irreversibility is the entire point.
8. **`maxGames = 1`** — a ladder has no side to swap.
