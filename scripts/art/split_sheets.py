#!/usr/bin/env python3
"""Keys, splits and pads the nano-banana sheets into the board sprites.

Input (committed, generated once by scripts/art/gen_sokoban_art.py):

    scripts/art/source/cog_sheet.png     four views of the one cog kit
    scripts/art/source/crate_sheet.png   loose crate | parked crate | target

Output (committed; CI never regenerates art):

    data/art/cog_down.png    cog_up.png    cog_left.png    cog_right.png
    data/art/cog_avatar.png  (the scorebug plate portrait)
    data/art/crate.png       crate_parked.png    target.png

The backdrop is keyed with an edge flood fill so a green accent INSIDE an
object survives (the parked crate's rim light is exactly that case), then each
run of non-empty columns is cropped to content and padded to a square.

    python3 scripts/art/split_sheets.py [outdir]

Default outdir is data/art.
"""

import os
import sys
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "source")
SIZE = 128
TOL = 52  # colour distance from the backdrop that still counts as backdrop


def key_background(path):
    img = Image.open(path).convert("RGBA")
    width, height = img.size
    px = img.load()
    border = ([px[x, y][:3] for x in range(width) for y in (0, height - 1)] +
              [px[x, y][:3] for y in range(height) for x in (0, width - 1)])
    bg = tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3))

    def near(pixel):
        return sum((a - b) ** 2 for a, b in zip(pixel[:3], bg)) ** 0.5 <= TOL

    seen = bytearray(width * height)
    queue = deque()
    for x in range(width):
        queue.append((x, 0))
        queue.append((x, height - 1))
    for y in range(height):
        queue.append((0, y))
        queue.append((width - 1, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= width or y >= height or seen[y * width + x]:
            continue
        seen[y * width + x] = 1
        if not near(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return img


def runs_of_content(img, min_width=24):
    alpha = img.getchannel("A")
    width, height = img.size
    columns = [any(alpha.getpixel((x, y)) > 8 for y in range(0, height, 2))
               for x in range(width)]
    runs, start = [], None
    for x, on in enumerate(columns + [False]):
        if on and start is None:
            start = x
        elif not on and start is not None:
            if x - start >= min_width:
                runs.append((start, x))
            start = None
    return runs


def square(part, size=SIZE, bottom_anchored=True):
    part = part.crop(part.getbbox())
    side = max(part.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    top = side - part.height if bottom_anchored else (side - part.height) // 2
    canvas.paste(part, ((side - part.width) // 2, top))
    return canvas.resize((size, size), Image.LANCZOS)


def split(path, names, bottom_anchored=True):
    img = key_background(path)
    height = img.size[1]
    runs = runs_of_content(img)
    if len(runs) < len(names):
        raise SystemExit("%s: found %d runs, need %d" %
                         (path, len(runs), len(names)))
    out = []
    for (x0, x1) in runs[:len(names)]:
        out.append(square(img.crop((x0, 0, x1, height)), SIZE, bottom_anchored))
    return dict(zip(names, out))


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join("data", "art")
    os.makedirs(outdir, exist_ok=True)

    cogs = split(os.path.join(SOURCE, "cog_sheet.png"),
                 ["cog_down.png", "cog_up.png", "cog_left.png", "spare.png"])
    # The sheet reliably renders three distinct views (front, back, one strict
    # profile); the fourth frame drifts back toward the rear view, so the
    # right-facing cog is the mirror of the left-facing one. Mirroring a
    # symmetric character is exactly what a hand-drawn sheet would do anyway.
    cogs["cog_right.png"] = cogs["cog_left.png"].transpose(
        Image.FLIP_LEFT_RIGHT)
    cogs.pop("spare.png")
    cogs["cog_avatar.png"] = cogs["cog_down.png"].copy()

    crates = split(os.path.join(SOURCE, "crate_sheet.png"),
                   ["crate.png", "crate_parked.png", "target.png"],
                   bottom_anchored=False)

    for name, sprite in list(cogs.items()) + list(crates.items()):
        sprite.save(os.path.join(outdir, name))
        print("wrote", os.path.join(outdir, name))


if __name__ == "__main__":
    main()
