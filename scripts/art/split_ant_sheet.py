#!/usr/bin/env python3
"""Splits the nano-banana ant sheet into the two ant sprites.

scripts/art/source/ants_sheet.png is a single Gemini ("nano-banana") render
of the Softmax cog reimagined as a six-legged robot ant — screen face,
riveted thorax, antennae — in two variants on a flat green backdrop: an
empty forager and a laden one hoisting a big golden food crumb. The plating
is neutral off-white on purpose: the board tints the sprite to the colony
hue at draw time (see drawAnts in client/broadcast_core.js). This script
keys the backdrop out with an edge flood fill (so the green never touches
the crumb or the face), splits the row into two, crops each to content,
pads to a square and writes 128 px RGBA sprites:

    python3 scripts/art/split_ant_sheet.py [outdir]

Default outdir is client/art (the only art dir this repo uses).
"""

import os
import sys
from collections import deque

from PIL import Image

SRC = os.path.join(os.path.dirname(__file__), "source", "ants_sheet.png")
ROLES = ["ant.png", "ant_laden.png"]
SIZE = 128
TOL = 60  # colour distance from the backdrop that still counts as backdrop


def key_background(img):
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    # median of the border is robust to corner smudges in the render
    border = [px[x, y][:3] for x in range(w) for y in (0, h - 1)] + \
        [px[x, y][:3] for y in range(h) for x in (0, w - 1)]
    bg = tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3))

    def near(p):
        if p[0] > 165:          # the yellow crumb's highlights are never backdrop
            return False
        return sum((a - b) ** 2 for a, b in zip(p[:3], bg)) ** 0.5 <= TOL

    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            q.append((x, y))
    while q:
        x, y = q.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        if not near(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    # soften the keyed edge: nothing on the ant itself is green (grey
    # plating, blue face, yellow crumb), so any green-dominant pixel that
    # survived the flood is backdrop bleed or shadow and goes transparent;
    # a mildly green-tinted edge pixel is faded instead.
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if not a:
                continue
            if r > 165:          # the yellow crumb is never backdrop
                continue
            if g > r + 35 and g > b + 35:
                px[x, y] = (r, g, b, 0)
            elif g > r + 12 and g > b + 12:
                px[x, y] = (r, g, b, a // 3)
    return img


def split(img):
    alpha = img.getchannel("A")
    w, h = img.size
    cols = [any(alpha.getpixel((x, y)) for y in range(h)) for x in range(w)]
    runs, start = [], None
    for x, on in enumerate(cols + [False]):
        if on and start is None:
            start = x
        elif not on and start is not None:
            if x - start > 20:
                runs.append((start, x))
            start = None
    assert len(runs) == len(ROLES), runs
    out = []
    for x0, x1 in runs:
        part = img.crop((x0, 0, x1, h))
        part = part.crop(part.getbbox())
        side = max(part.size)
        sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        sq.paste(part, ((side - part.width) // 2, side - part.height))
        out.append(sq.resize((SIZE, SIZE), Image.LANCZOS))
    return out


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join("client", "art")
    os.makedirs(outdir, exist_ok=True)
    for name, sprite in zip(ROLES, split(key_background(Image.open(SRC)))):
        sprite.save(os.path.join(outdir, name))
    print("ant sprites written to", outdir)


if __name__ == "__main__":
    main()
