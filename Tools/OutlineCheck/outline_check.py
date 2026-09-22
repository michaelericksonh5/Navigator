#!/usr/bin/env python3
"""Measure the cartoon-contour artefact on generated symbols.

The commonest complaint about generated slot art is a keyline: a dark ink stroke hugging
the silhouette, or a pale die-cut sticker band. Both are easy to argue about and easy to
measure, so this measures them.

Symbols are drawn on a flat chroma field, which gives an exact silhouette to sample
across. For each crossing from the field into the subject it compares the first few
pixels of the subject against the body a little further in:

    dark rim  = the rim is much DARKER than the body   -> inked contour
    light rim = the rim is much BRIGHTER than the body -> die-cut sticker border

Reported as the percentage of crossings showing each. Styles whose identity IS line work
(cel shading, pixel art, vector casino) are expected to score high — that is correct for
them; see SlotArtStyle.usesLineWork.

    python3 outline_check.py <folder-of-pngs>
"""
import os, sys, statistics
from PIL import Image

DARK_DELTA, LIGHT_DELTA, MIN_COVERAGE = 45, 60, 25


def lum(p):
    return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]


def is_backdrop(p):
    r, g, b = p[:3]
    return r > 150 and b > 150 and g < 110


def profile(path, samples=260):
    im = Image.open(path).convert("RGB")
    W, H = im.size
    px = im.load()
    dark = light = n = 0
    for i in range(samples):
        y = int(H * (i + 0.5) / samples)
        x = 0
        while x < W and is_backdrop(px[x, y]):
            x += 1
        if x == 0 or x >= W - 40:
            continue                       # no crossing on this row
        rim = [lum(px[x + k, y]) for k in range(0, 5)]
        body = [lum(px[x + k, y]) for k in range(9, 26)]
        b = statistics.median(body)
        if min(rim) < b - DARK_DELTA:
            dark += 1
        if max(rim) > b + LIGHT_DELTA:
            light += 1
        n += 1
    return (dark / n * 100, light / n * 100, n) if n else (0.0, 0.0, 0)


def main(folder):
    rows = []
    for f in sorted(os.listdir(folder)):
        if f.lower().endswith(".png"):
            d, l, n = profile(os.path.join(folder, f))
            rows.append((d, l, f[:-4]))
    if not rows:
        print("no PNGs in", folder)
        return 1
    rows.sort(reverse=True)
    for d, l, name in rows:
        flag = "  <-- outlined" if d >= MIN_COVERAGE else ""
        print(f"  dark {d:5.1f}%   light {l:5.1f}%   {name}{flag}")
    bad = sum(1 for d, _, _ in rows if d >= MIN_COVERAGE)
    print(f"\n{bad} of {len(rows)} images show a dark rim on {MIN_COVERAGE}%+ of the silhouette")
    print(f"median dark-rim coverage: {statistics.median([r[0] for r in rows]):.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
