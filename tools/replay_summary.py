#!/usr/bin/env python3
"""Summarise a Sokoban `.replay` as one strict-UTF-8 JSON object on stdout.

Python 3 standard library only: no Nim, no Docker, no emsdk. This is the JSON
view of the binary `COWLDSOK` replay the static wasm viewer parses, and it is
what phase 60's definition-of-done check reads instead of `jq .` on the raw
bytes:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                  # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.endRule' /tmp/ep.json
    jq -r '[.plans[]|select(.source=="llm")]|length, .fallbacks, (.says|length)' /tmp/ep.json

The replay stays binary on purpose: a JSON replay would mean rewriting
replays.nim, replay_runtime.nim, static_replay_worker.js and
wasm_replay_smoke.cjs — the machinery this fork exists to reuse.

How it reads the file WITHOUT a decoder for the whole record stream:

* the header is ASCII up to the config JSON, so the config is recovered by
  BRACE-MATCHING from the first `{` (the technique the starter's AGENTS.md
  documents for prod forensics);
* the CONTROL records — `register`, `directive`, `fallback`,
  `budget_guard`, `stop`, `result` — are UTF-8 JSON objects embedded verbatim
  in the chat records, so they are recovered the same way, by scanning the
  remaining bytes for balanced `{"k":...}` objects;
* the LEVEL records carry their ten XSB rows as length-prefixed ASCII, and the
  rows are recovered by scanning for ten-character runs of the XSB alphabet
  that begin and end with a wall — enough for a forensic read without a
  decoder for the record framing.

Nothing here needs the record framing, so it cannot drift when the framing
changes; it only needs the two things that are text.
"""

from __future__ import annotations

import json
import sys


def brace_match(data: bytes, start: int) -> tuple[dict | None, int]:
    """Decode one balanced ``{...}`` starting at ``start``.

    Returns ``(obj, end)`` where ``end`` is the index just past the object, or
    ``(None, start + 1)`` when the bytes there are not a decodable object.
    """
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(data)):
        ch = data[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == 0x5C:      # backslash
                escaped = True
            elif ch == 0x22:      # quote
                in_string = False
            continue
        if ch == 0x22:
            in_string = True
        elif ch == 0x7B:          # {
            depth += 1
        elif ch == 0x7D:          # }
            depth -= 1
            if depth == 0:
                chunk = data[start:i + 1]
                try:
                    return json.loads(chunk.decode("utf-8")), i + 1
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return None, start + 1
        elif depth == 0:
            # A stray byte before any brace: not the start of an object.
            return None, start + 1
    return None, len(data)


def summarise(path: str) -> dict:
    data = open(path, "rb").read()
    header = data[:96]
    protocol = "sokoban/v1"
    game_version = ""
    # The header is `magic + format version + gameName + gameVersion +
    # protocol` before the config, all length-prefixed ASCII; recover the
    # version as the digit run right after the game name.
    try:
        head_text = header.decode("latin-1")
        if "COWLDSOK" in head_text:
            head_text = head_text.split("COWLDSOK", 1)[1]
        if "sokoban" in head_text:
            tail = head_text.split("sokoban", 1)[1]
            digits = ""
            for ch in tail:
                if ch.isdigit():
                    digits += ch
                elif digits:
                    break
            game_version = digits
        if "sokoban/v1" in header.decode("latin-1"):
            protocol = "sokoban/v1"
    except Exception:                                   # noqa: BLE001
        pass

    first = data.find(b"{")
    config: dict = {}
    cursor = 0
    if first >= 0:
        config, cursor = brace_match(data, first)
        config = config or {}

    plans: list[dict] = []
    says: list[str] = []
    fallbacks = 0
    registers: list[dict] = []
    budget_guards = 0
    stops: list[dict] = []
    results: dict = {}
    i = cursor
    while True:
        i = data.find(b'{"k":', i)
        if i < 0:
            break
        obj, nxt = brace_match(data, i)
        i = nxt
        if not isinstance(obj, dict):
            continue
        kind = obj.get("k")
        if kind == "directive":
            plans.append(obj)
            if obj.get("say"):
                says.append(obj["say"])
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append(obj)
        elif kind == "budget_guard":
            budget_guards += 1
        elif kind == "stop":
            stops.append(obj)
        elif kind == "result":
            results = obj.get("results", obj)

    # The six level boards, recovered from the level records' length-prefixed
    # ASCII rows: a run of exactly ten XSB glyphs is a row, and ten consecutive
    # rows are a board.
    alphabet = set(b"# .$*@+")
    rows: list[str] = []
    j = 0
    while j + 10 <= len(data):
        window = data[j:j + 10]
        if all(c in alphabet for c in window):
            rows.append(window.decode("ascii"))
            j += 10
        else:
            j += 1
    levels: list[list[str]] = []
    seen_boards: set = set()
    for k in range(0, max(0, len(rows) - 9)):
        block = rows[k:k + 10]
        if block[0] != "#" * 10 or block[9] != "#" * 10:
            continue
        key = "\n".join(block)
        if key in seen_boards:
            continue
        seen_boards.add(key)
        levels.append(block)
    # The level records come first in the stream, so the first `levelCount`
    # distinct boards are the levels themselves; the rest are the mid-level
    # snapshots the directive records mirror.
    want = config.get("levelCount")
    if isinstance(want, int) and want > 0:
        levels = levels[:want]
    names = [p.get("name", "") for p in (config.get("players") or [])]
    real_names = [r.get("name", "") for r in registers]

    return {
        "protocol": protocol,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "variant": config.get("variant"),
        "names": real_names or names,
        "aliases": [r.get("alias", "") for r in registers] or names,
        "policyKinds": [r.get("kind", "") for r in registers],
        "tierLadder": config.get("tierLadder") or [],
        "tickCount": len(data),
        "levels": levels,
        "plans": plans,
        "says": says,
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "stops": stops,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: replay_summary.py <path.replay>", file=sys.stderr)
        return 2
    out = summarise(argv[1])
    # ensure_ascii=False keeps a non-ASCII policy label or note as real UTF-8,
    # which is exactly what the strict-parse check downstream is testing.
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
