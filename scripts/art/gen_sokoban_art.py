#!/usr/bin/env python3
"""Generates the Sokoban board art with nano-banana (Gemini image generation).

Two sheets, two calls, both anchored on the canonical Softmax cog so the
character is the fleet's cog and not a generic robot:

  1. scripts/art/source/cog_sheet.png    the ONE cog kit (single role: this is
                                         a solitaire puzzle) in its four board
                                         facings - down, up, left, right.
  2. scripts/art/source/crate_sheet.png  the crate in its two states (loose,
                                         parked on a marked square) and the
                                         marked square itself.

The key is passed as the `x-goog-api-key` header and never written anywhere.
Run from the repo root:

    GEMINI_API_KEY=... python3 scripts/art/gen_sokoban_art.py

Then split with scripts/art/split_sheets.py. CI never regenerates art; both
the source sheets and the split sprites are committed.
"""

import base64
import json
import os
import sys
import urllib.request

ENDPOINT = ("https://generativelanguage.googleapis.com/v1beta/models/"
            "gemini-2.5-flash-image:generateContent")

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "source")
REFERENCE = os.path.join(SOURCE, "cog_reference.png")

COG_PROMPT = """Using this robot character ("cog") as the exact character design
reference, draw FOUR of these cogs in one horizontal row, evenly spaced, same
size, same clean cartoon rendering, each one a different VIEW of the SAME robot:
1st (leftmost) FRONT view, facing the viewer;
2nd BACK view, seen from directly behind;
3rd SIDE view facing LEFT;
4th SIDE view facing RIGHT.
It is a warehouse worker cog: orange safety plating (#E8A33D) on the shoulders,
chunky rubber treads, a small amber lamp on top of the head. No shield, no
weapon, no tools in the hands - the hands are flat pusher paddles held forward.
Background: perfectly flat, solid, uniform pure bright green (#00FF00), no
shadows, no gradients, no floor - it will be chroma-keyed out.
No text, no labels, no numbers."""

CRATE_PROMPT = """Draw THREE objects in one horizontal row, evenly spaced, same
size, same clean cartoon game-art rendering, viewed from a slightly raised
three-quarter top-down angle as top-down game tiles:
1st (leftmost): a wooden shipping CRATE, square, warm brown planks with an X of
cross-bracing on the face and dark iron corner brackets. Loose, unsecured.
2nd: the SAME wooden crate, but locked down and finished - a bright green rim
light around its whole edge, a green glow beneath it, and a small green check
mark burnt into the top plank.
3rd: an empty MARKED SQUARE recessed into a stone floor - a square amber
(#E8A33D) diamond inlay with a chamfered lip and a faint amber glow, nothing
standing on it.
Background: perfectly flat, solid, uniform pure bright green (#00FF00), no
shadows outside the objects, no gradients, no floor plane - it will be
chroma-keyed out. No text, no labels, no numbers."""


def generate(prompt, out_name, with_reference):
    parts = []
    if with_reference:
        with open(REFERENCE, "rb") as handle:
            parts.append({"inline_data": {
                "mime_type": "image/png",
                "data": base64.b64encode(handle.read()).decode()}})
    parts.append({"text": prompt})
    body = {"contents": [{"parts": parts}],
            "generationConfig": {"responseModalities": ["IMAGE"]}}
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"],
                 "content-type": "application/json"})
    try:
        payload = json.load(urllib.request.urlopen(request, timeout=180))
    except urllib.error.HTTPError as error:
        sys.stderr.write("gemini %s: %s\n" % (error.code, error.read()[:800]))
        raise
    part = next(p for p in payload["candidates"][0]["content"]["parts"]
                if "inlineData" in p)
    os.makedirs(SOURCE, exist_ok=True)
    target = os.path.join(SOURCE, out_name)
    with open(target, "wb") as handle:
        handle.write(base64.b64decode(part["inlineData"]["data"]))
    print("wrote", target)


def main():
    generate(COG_PROMPT, "cog_sheet.png", with_reference=True)
    generate(CRATE_PROMPT, "crate_sheet.png", with_reference=False)


if __name__ == "__main__":
    main()
