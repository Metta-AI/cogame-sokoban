# Rules

One cog, alone, in a **10 × 10** walled room with **four crates** and **four
marked squares**. It can walk, and when it walks into a crate the crate slides
one square ahead of it.

**It can never pull.** A crate shoved into a corner is there forever; a crate
shoved against a wall in a row with no marked square on it is there forever;
four crates shoved into a 2 × 2 clump are there forever. The level is over the
instant the position becomes unwinnable — that is the whole game, and the
replay says so out loud with a **DEADLOCK CREATED** marker on the scrubber.

## The board and its notation

The board is always 10 × 10, indexed `(x, y)` with `x` the column `0 … 9`
(west → east) and `y` the row `0 … 9` (north → south). `(0, 0)` is the
north-west corner. **The entire border ring is wall**, so the playable interior
is 8 × 8 = 64 cells.

Boards are written in canonical **XSB** notation — the format every published
Sokoban level and every Sokoban solver uses:

| Glyph | Means |
|---|---|
| `#` | wall |
| (space) | empty floor |
| `.` | marked square, empty |
| `$` | crate, not on a marked square |
| `*` | crate, on a marked square |
| `@` | the cog, on plain floor |
| `+` | the cog, standing on a marked square |

Rows are always exactly 10 characters and there are always exactly 10 of them;
leading and trailing spaces are significant and are never trimmed.

## Directions and the four primitives

`U` (y−1), `D` (y+1), `L` (x−1), `R` (x+1) — indices 0, 1, 2, 3, and the fixed
order every tie-break in the game uses.

There are exactly four primitives, one per direction, plus `wait`. A primitive
is one **tick** and one **move** against the step budget, whether or not it
changes anything.

## Tiers

Three tiers, distinguished only by the level's *exact* optimal push count
`optPushes` — known exactly because of how levels are generated (see
[LEVELS.md](LEVELS.md)):

| Tier | `optPushes` | Weight |
|---|---|---|
| `unfiltered` | 6 … 12 | 1 |
| `medium` | 13 … 22 | 2 |
| `hard` | 23 … 34 | 3 |

`optPushes` is recorded per level, and it is **shown to the cog**: knowing
"this is solvable in 17 pushes" is a legitimate part of a Sokoban statement.

## The ladder and the clock

- **Tick** = one primitive. **`turnMoves = 20`**: every command turn executes at
  most twenty primitives.
- **`levelTurnCap = 10`** turns per level ⇒ **`stepBudget = 200`** moves per
  level.
- **`levelCount = 6`** levels per episode ⇒ **`maxTurns = 60`**,
  **`maxTicks = 1200`**.
- Levels run strictly in the variant's declared tier order and are generated
  lazily.
- A level that finishes (solved, deadlocked, out of steps) ends its turn
  immediately; the remaining primitives are discarded and the next level begins
  on the next turn. Turns saved this way are **not** transferable.

## Resolution order, per tick

1. `tick += 1`; `levelMove += 1`.
2. Pop the next primitive. An empty queue is a `wait` — a real cost.
3. Apply it. With `A` the adjacent cell in `d` and `B` the cell beyond:
   - `A` is wall → nothing happens, `blockedMoves += 1`;
   - `A` holds a crate and `B` is wall or crate → nothing happens,
     `blockedMoves += 1`. **This is the only place a push can fail, and crates
     are never moved by anything else — there is no pull, no undo and no
     restart;**
   - `A` holds a crate and `B` is free floor → the crate moves `A → B`, the cog
     moves into `A`, `pushes += 1`;
   - otherwise the cog moves into `A`.
4. `boxesOnTargets` is recomputed; `levelBoxesPlaced` is its running maximum.
5. **Level termination**, only when a crate moved, in this order:
   `boxesOnTargets == 4` → **solved**; else `isDeadlocked(state)` →
   **deadlocked**.
6. `levelMove == stepBudget` → **out of steps** (checked every tick).
7. The tick is mixed into `gameHash`.
8. A finished level breaks the tick loop; the turn ends early.

## Deadlock detection

Sound and deliberately incomplete: it never flags a position that is still
winnable, and some unwinnable positions are simply left to burn out on the step
budget. The disjunction of exactly three tests, in this order:

1. **`dead_square`** — a crate that is not on a marked square stands on a cell
   of the level's static dead-square set `D`. `D` is computed once per level
   from **walls and marked squares only** (never from crate positions, which is
   what makes it sound): mark every marked square alive; then to a fixpoint,
   for every alive `c` and direction `d`, mark `c − d` alive if `c − d` is floor
   and `c − 2d` is floor. `D` is every floor cell not marked alive.
2. **`frozen_block`** — a 2 × 2 block whose four cells are all wall-or-crate and
   at least one is a crate not on a marked square.
3. **`no_push`** — a crate is off its marked square and the legal-push set is
   empty.

## Scoring

```
weight(unfiltered) = 1,  weight(medium) = 2,  weight(hard) = 3

solvedWeight     = sum of weight(tier) over solved levels
boxCredit        = sum of the per-level MAXIMUM crates on marked squares
movesSavedTotal  = sum of (200 - levelMoves) over solved levels

scores[0]        = 1_000_000 * solvedWeight
                 +    10_000 * boxCredit
                 +         1 * movesSavedTotal
```

Higher is better and **every term only ever adds**: the minimum, 0, is the
honest score of a cog that solved nothing and never parked a crate. There is no
penalty for deadlocking — creating one already costs the level.

The ordering is strictly lexicographic by construction: one more unit of tier
weight is worth 1 000 000 and the largest possible total of the other two terms
is 10 000 × 24 + 1 194 = 241 194.

`results.win[0]` is `solvedWeight >= parWeight`, and `results.winner` is `0`
when that is true and `null` otherwise — there is no opponent, so the only
honest winner is the seat itself or nobody.

**Measured but never scored:** `pushesTotal`, `blockedMoves`, `deadlocks`,
`outOfSteps`, `levelPushes`, `levelMoves`, `actionsDropped`,
`macrosUnreachable`, `repliesRepaired`.

## End conditions

`results.reason` is a closed enum:

- **`complete`** — the ladder ran out of levels, or the turn cap fired.
  `results.endRule` says which: `ladderComplete` | `turnCap`.
- **`deadline`** — the engine's `wallClockBudgetSeconds` (690 s) was reached.
  The episode settles with the real levels solved so far and is still rankable.
  `endRule = wallClock`.
- **`fault`** — an unexpected exception; artifacts are still written.
  `endRule = fault`.

`results.levelOutcome[i]` is `solved | deadlocked | outofsteps | unreached`.
