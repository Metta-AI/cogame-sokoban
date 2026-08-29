# Actions and the reply format

A policy is just a prompt. The **game server** composes the seat's board view
plus that seat's `PLAYER_PROMPT` and asks Claude what the cog does for the next
twenty moves; the player container only registers. There is exactly **one**
request per turn, plus at most **one** retry.

## What the seat gets each turn

```json
{
  "you": "Alpha",
  "level": {"index": 3, "of": 6, "tier": "medium", "opt_pushes": 17,
            "moves_left": 162, "turns_left": 8, "pushes_made": 5,
            "boxes_on_targets": 1},
  "turn": 23, "tick": 421,
  "world": {"size": 10,
            "legend": {"#": "wall", " ": "floor", ".": "target",
                       "$": "box", "*": "box on target",
                       "@": "you", "+": "you on a target"},
            "dirs": ["U", "D", "L", "R"],
            "moves_per_turn": 20, "step_budget": 200},
  "board": ["##########", "#        #", "…"],
  "player": {"x": 4, "y": 4},
  "boxes":   [{"i": 0, "x": 4, "y": 3, "on_target": false}, …],
  "targets": [{"x": 3, "y": 3, "filled": false}, …],
  "dead_squares": [[1,1],[8,1], …],
  "pushes_available": [{"box": 0, "dir": "U", "to": [4, 2]}, …],
  "last_turn": {"executed": "RRUULLLDD", "pushes": 2, "blocked": 3,
                "truncated": false, "dropped": 0, "unreachable": 1},
  "levels_solved": 1,
  "solved_weight": 1,
  "history": [{"tier": "unfiltered", "outcome": "solved"}, …],
  "notes": "…the seat's own note from last turn…"
}
```

Sokoban is **perfect information** and this game keeps it that way: the cog sees
the entire board. `board` and the structured lists say the same thing twice and
must always agree — a test re-parses `board` and asserts it reconstructs
`player`, `boxes` and `targets` exactly.

`dead_squares` and `pushes_available` are pure functions of the board that any
policy could compute itself. Handing them over deliberately moves the
measurement off "can the model write a corner-detection subroutine" and onto
**push ordering and freeze deadlocks**. `pushes_available` carries **no**
deadlock annotation: cross-referencing `to` against `dead_squares` is the
policy's job.

**Hidden:** the episode seed, any level not yet started, the level's solution,
the agent's own score, and its own real policy name.

## What the seat sends

```json
{"actions": [{"do": "push", "box": 1, "dir": "R", "times": 1},
             {"do": "goto", "x": 5, "y": 3},
             {"do": "moves", "seq": "LLU"},
             {"do": "wait"}],
 "say": "parking the two right-hand crates first",
 "notes": "order: box1, box3, box2, box0. never push box0 down."}
```

| Field | Cap / domain |
|---|---|
| `actions` | ≤ **8** entries. Entries past the cap are dropped and counted. Absent or empty = the turn is twenty `wait` ticks, and the reply is still **usable** |
| `actions[].do` | ≤ 6 runes; `moves` \| `push` \| `goto` \| `wait`, lower-cased before matching |
| `actions[].seq` | required for `moves`; ≤ 20 runes from `UDLRudlr` only. Any other character **drops the entry** |
| `actions[].box` | required for `push`; **0 … 3**, indexing the **turn-start** `boxes` order; out of range drops the entry |
| `actions[].dir` | required for `push`; matched case-insensitively against `U`,`D`,`L`,`R`,`up`,`down`,`left`,`right` |
| `actions[].times` | optional for `push`; clamped to 1 … 8; absent = 1 |
| `actions[].x`, `.y` | required for `goto`; clamped to 0 … 9 |
| `say` | ≤ **140** runes — drawn in the spectator feed, never fed back to the seat |
| `notes` | ≤ **320** runes — private scratchpad, echoed to this seat only next turn |
| whole reply | ≤ 4096 bytes read from the provider before parsing |
| `PLAYER_PROMPT` | ≤ 4000 runes at registration |

**Invalid actions are dropped, never rewritten.** In a game where one wrong push
is fatal, repairing a malformed push into a different push would let the *game*
lose the level on the policy's behalf. The entry is removed, counted, and
reported back as `dropped`.

Every string that lands in the replay — `say`, `notes`, the policy label, the
stop detail, recorded error text — is truncated on **rune** boundaries. Byte
truncation is what makes a replay that renders in a browser fail a strict UTF-8
parser.

## How a plan becomes moves

`src/sokoban/driver.nim` is the only producer of primitives and contains no
randomness. Every macro is expanded against the **turn-start snapshot**;
execution is always the literal primitive sequence, and a primitive that turns
out to be blocked at execution time is a no-op that still costs a move.

| Action | Expands to |
|---|---|
| `moves seq` | the literal `seq`, one primitive per character |
| `goto x y` | the walk BFS path; **zero** primitives if the square is not free floor or not reachable (`unreachable`) |
| `push box dir times` | the walk to the approach square, then `times` primitives in `dir`; **zero** primitives if the approach or the landing square is blocked (`unreachable`) |
| `wait` | itself |

The walk BFS runs against the turn-start board over 4-adjacency in the fixed
order **U, D, L, R**, so the path is unique for a given board. Each macro yields
at most 32 primitives; the whole turn's queue is then truncated to 20 and
**nothing carries over to the next turn**.

## Fielding your own policy

```bash
coworld upload-policy coworld-sokoban --name my-sokoban \
  --run /bin/sokoban-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

Or run one of the two shipped scripted baselines from the same image:
`PLAYER_SCRIPTED=pusher` (a bounded best-first search over push space) or
`PLAYER_SCRIPTED=nudger` (one-ply, no lookahead).
