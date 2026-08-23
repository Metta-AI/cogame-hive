#!/usr/bin/env python3
"""Generate every painted asset the hive board and its chrome use.

Nothing here is a placeholder rectangle. Each asset is painted procedurally
with layered noise, gradients and hand-placed strokes, then written to
`client/art/`. The generator is committed so the art is reproducible and
reviewable, exactly the way paintbot keeps its prop scripts under
`scripts/art/`.

Outputs (all under client/art/):
  meadow_floor.jpg      seamless 128px meadow tile: cool green, subtly noisy
                        so the additive pheromone glow reads against it
  rock.png              seamless 64px grey-lichen tile, masked to the baked
                        rock shape at draw time
  nest_{amber,teal,lime,magenta}.png
                        56px painted mound with a visible entrance, tinted to
                        its colony hue
  food_cache.png        64px painted seed pile
  (ant.png / ant_laden.png are NO LONGER written here: they are nano-banana
   renders of the Softmax cog as a six-legged robot ant, split out of
   scripts/art/source/ants_sheet.png by scripts/art/split_ant_sheet.py.
   The procedural `ant()` below is kept only as a reference rig.)
  lockerroom.jpg        the pre-load curtain plate

  usage: python3 scripts/art/build_art.py [output-dir]
"""
from __future__ import annotations

import math
import random
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "client/art")
RNG = np.random.default_rng(0xB17E)


def seamless_noise(size: int, octaves: int, seed: int) -> np.ndarray:
    """Tileable value noise in [0, 1]: low-frequency lattices wrapped with
    np.roll so opposite edges match exactly."""
    rng = np.random.default_rng(seed)
    out = np.zeros((size, size), dtype=np.float64)
    weight = 0.0
    for octave in range(octaves):
        cells = 2 ** (octave + 1)
        lattice = rng.random((cells, cells))
        # wrap by repeating the first row/column
        lattice = np.pad(lattice, ((0, 1), (0, 1)), mode="wrap")
        img = Image.fromarray((lattice * 255).astype(np.uint8), "L")
        img = img.resize((size + size // cells, size + size // cells),
                         Image.BICUBIC)
        layer = np.asarray(img, dtype=np.float64)[:size, :size] / 255.0
        amp = 0.5 ** octave
        out += layer * amp
        weight += amp
    out /= weight
    out -= out.min()
    if out.max() > 0:
        out /= out.max()
    return out


def meadow_floor(size: int = 128) -> Image.Image:
    base = seamless_noise(size, 5, 11)
    blades = seamless_noise(size, 6, 29)
    dark = np.array([28, 46, 30], dtype=np.float64)
    light = np.array([58, 84, 46], dtype=np.float64)
    mix = (0.55 * base + 0.45 * blades)[..., None]
    rgb = dark + (light - dark) * mix
    # a scatter of paler blade tips so the tile is not flat
    tips = seamless_noise(size, 7, 71)
    rgb += np.clip((tips - 0.82) * 5.0, 0, 1)[..., None] * np.array([34, 40, 20])
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")
    return img.filter(ImageFilter.SMOOTH)


def rock_tile(size: int = 64) -> Image.Image:
    grain = seamless_noise(size, 6, 5)
    cracks = seamless_noise(size, 3, 17)
    dark = np.array([56, 55, 52], dtype=np.float64)
    light = np.array([124, 122, 112], dtype=np.float64)
    rgb = dark + (light - dark) * grain[..., None]
    # lichen: a green wash in the low spots
    lichen = np.clip((0.42 - cracks) * 3.0, 0, 1)[..., None]
    rgb = rgb * (1 - 0.35 * lichen) + lichen * np.array([96, 118, 74]) * 0.35
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")
    return img.convert("RGBA")


def tint(rgb: tuple[int, int, int], factor: float) -> tuple[int, int, int]:
    return tuple(int(max(0, min(255, c * factor))) for c in rgb)


def nest(colour: str, size: int = 56) -> Image.Image:
    hexed = colour.lstrip("#")
    base = tuple(int(hexed[i:i + 2], 16) for i in (0, 2, 4))
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx = cy = size / 2
    # the mound: concentric rings from a dark rim to a bright crown
    rings = 22
    for i in range(rings):
        k = i / (rings - 1)
        r = (size / 2 - 2) * (1 - k)
        col = tint(base, 0.42 + 0.75 * k)
        draw.ellipse([cx - r, cy - r * 0.86, cx + r, cy + r * 0.86],
                     fill=col + (255,))
    # grain: scattered speckles of soil
    rnd = random.Random(hash(colour) & 0xffff)
    for _ in range(340):
        a = rnd.random() * math.tau
        rr = math.sqrt(rnd.random()) * (size / 2 - 4)
        x = cx + math.cos(a) * rr
        y = cy + math.sin(a) * rr * 0.86
        shade = tint(base, 0.5 + rnd.random() * 0.8)
        draw.point((x, y), fill=shade + (200,))
    # the entrance: a small dark hole with a raised lip, set low on the
    # mound so the dome still reads as a dome and not as a ring
    hx, hy, hr = cx, cy + size * 0.20, size * 0.085
    draw.ellipse([hx - hr * 1.6, hy - hr * 1.15, hx + hr * 1.6, hy + hr * 1.15],
                 fill=tint(base, 1.15) + (255,))
    draw.ellipse([hx - hr, hy - hr * 0.68, hx + hr, hy + hr * 0.68],
                 fill=(20, 15, 11, 255))
    return img.filter(ImageFilter.GaussianBlur(0.4))


def food_cache(size: int = 64) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    rnd = random.Random(4242)
    cx = cy = size / 2
    # a pile of seeds: many small ellipses, darker at the base
    for _ in range(150):
        a = rnd.random() * math.tau
        rr = math.sqrt(rnd.random()) * (size * 0.36)
        x = cx + math.cos(a) * rr
        y = cy + math.sin(a) * rr * 0.72 + rr * 0.16
        k = 1 - rr / (size * 0.36)
        base = (196, 158, 74)
        col = tint(base, 0.6 + 0.65 * k * rnd.random())
        w = rnd.uniform(2.4, 4.4)
        h = w * rnd.uniform(0.55, 0.8)
        draw.ellipse([x - w, y - h, x + w, y + h], fill=col + (255,),
                     outline=(96, 70, 26, 200))
    return img.filter(ImageFilter.GaussianBlur(0.3))


def ant(size: int = 16, laden: bool = False) -> Image.Image:
    """A top-down ant, painted in near-white so the board can tint it to the
    colony hue with a single multiply at draw time."""
    scale = 4
    big = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(big)
    s = size * scale
    body = (238, 232, 220, 255)
    dark = (60, 48, 38, 255)
    # three segments along the vertical axis (facing up)
    for (cy, r) in ((s * 0.30, s * 0.13), (s * 0.50, s * 0.10),
                    (s * 0.72, s * 0.17)):
        draw.ellipse([s / 2 - r, cy - r, s / 2 + r, cy + r], fill=body,
                     outline=dark, width=max(1, scale // 2))
    # six legs
    for side in (-1, 1):
        for i, cy in enumerate((s * 0.36, s * 0.50, s * 0.64)):
            dx = side * s * (0.22 + 0.04 * i)
            dy = (i - 1) * s * 0.10
            draw.line([s / 2, cy, s / 2 + dx, cy + dy], fill=dark,
                      width=max(1, scale // 2))
    # antennae
    for side in (-1, 1):
        draw.line([s / 2, s * 0.24, s / 2 + side * s * 0.14, s * 0.08],
                  fill=dark, width=max(1, scale // 2))
    if laden:
        draw.ellipse([s * 0.36, s * 0.02, s * 0.64, s * 0.26],
                     fill=(232, 208, 122, 255), outline=dark,
                     width=max(1, scale // 2))
    return big.resize((size, size), Image.LANCZOS)


def lockerroom(width: int = 640, height: int = 360) -> Image.Image:
    field = seamless_noise(256, 5, 91)
    img = Image.fromarray(
        np.clip(np.array([22, 34, 24]) + field[..., None] *
                np.array([26, 40, 22]), 0, 255).astype(np.uint8), "RGB")
    img = img.resize((width, height), Image.BICUBIC)
    draw = ImageDraw.Draw(img, "RGBA")
    hues = ["#f2c14e", "#4ecdc4", "#9fd356", "#e26db5"]
    for i, hexed in enumerate(hues):
        rgb = tuple(int(hexed.lstrip("#")[j:j + 2], 16) for j in (0, 2, 4))
        cx = width * (0.16 + 0.23 * i)
        cy = height * 0.68
        for r in range(70, 0, -3):
            k = 1 - r / 70
            draw.ellipse([cx - r, cy - r * 0.5, cx + r, cy + r * 0.5],
                         fill=tint(rgb, 0.35 + 0.7 * k) + (255,))
        rnd = random.Random(i)
        for _ in range(90):
            a = rnd.random() * math.tau
            rr = math.sqrt(rnd.random()) * 90
            draw.ellipse([cx + math.cos(a) * rr - 1.6,
                          cy + math.sin(a) * rr * 0.5 - 1.6,
                          cx + math.cos(a) * rr + 1.6,
                          cy + math.sin(a) * rr * 0.5 + 1.6],
                         fill=rgb + (200,))
    return img.filter(ImageFilter.GaussianBlur(0.6))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    meadow_floor().save(OUT / "meadow_floor.jpg", quality=92)
    rock_tile().save(OUT / "rock.png")
    for name, colour in (("amber", "#f2c14e"), ("teal", "#4ecdc4"),
                         ("lime", "#9fd356"), ("magenta", "#e26db5")):
        nest(colour).save(OUT / f"nest_{name}.png")
    food_cache().save(OUT / "food_cache.png")
    # ant.png / ant_laden.png: owned by split_ant_sheet.py (nano-banana).
    lockerroom().save(OUT / "lockerroom.jpg", quality=88)
    for path in sorted(OUT.iterdir()):
        print(f"{path}  {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
