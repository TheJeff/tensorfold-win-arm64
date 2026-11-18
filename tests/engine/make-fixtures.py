#!/usr/bin/env python3
"""Write the decoder fixtures used by pixel-parity.py and verify-engine.ps1.

Deterministic: no RNG seeding from the clock, so a regenerated fixture set is
byte-identical and diffs stay quiet. Images are deliberately awkward -- odd
dimensions, both chroma subsampling ratios, lossless and lossy WebP -- because
the failure mode worth catching is an edge or upsample bug in a locally built
decoder, not a clean 64x64.

Usage:  python make-fixtures.py [--fixtures <dir>]
"""
import argparse
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
RNG = np.random.default_rng(20261117)


def gradient(w, h):
    xs = np.linspace(0, 255, w, dtype=np.uint8)[None, :]
    ys = np.linspace(0, 255, h, dtype=np.uint8)[:, None]
    r = np.broadcast_to(xs, (h, w)).copy()
    g = np.broadcast_to(ys, (h, w)).copy()
    b = ((r.astype(int) + g.astype(int)) // 2).astype(np.uint8)
    return np.dstack([r, g, b])


def photo(w, h):
    """Structured detail plus noise: blocks, circles and a hard edge, so colour
    conversion and upsample bugs show up instead of averaging away."""
    base = gradient(w, h).astype(np.int16)
    yy, xx = np.mgrid[0:h, 0:w]
    # hard vertical edge and a few solid blocks
    base[:, w // 2 :, 0] = np.clip(base[:, w // 2 :, 0] - 120, 0, 255)
    base[10:26, 8:24, 1] = 250
    base[h - 24 : h - 8, w - 30 : w - 6, 2] = 240
    # a disc
    disc = ((xx - w // 4) ** 2 + (yy - int(h * 0.7)) ** 2) < (min(w, h) // 6) ** 2
    base[disc] = (255, 0, 255)
    # fine high-frequency detail
    noise = RNG.integers(-18, 19, size=(h, w, 1))
    return np.clip(base + noise, 0, 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=os.path.join(HERE, "fixtures"))
    args = ap.parse_args()
    os.makedirs(args.fixtures, exist_ok=True)

    def save(arr, name, **kw):
        p = os.path.join(args.fixtures, name)
        Image.fromarray(arr, "RGB").save(p, **kw)
        print(f"  {os.path.getsize(p):>8,}  {name}")

    print("fixtures ->", args.fixtures)
    # Odd dimensions on purpose: even sizes hide rounding in the upsample paths.
    save(gradient(64, 48), "gradient.jpg", quality=90, subsampling=0)
    save(photo(97, 61), "photo.jpg", quality=85, subsampling=2)   # 4:2:0
    save(photo(97, 61), "photo_444.jpg", quality=85, subsampling=0)
    save(photo(97, 61), "photo.webp", quality=80)
    save(photo(97, 61), "photo_lossless.webp", lossless=True)

    # Negative fixtures, used by verify-engine.ps1's serve tier.
    blob = open(os.path.join(args.fixtures, "photo.jpg"), "rb").read()
    trunc = blob[: int(len(blob) * 0.6)]
    p = os.path.join(args.fixtures, "truncated.jpg")
    open(p, "wb").write(trunc)
    print(f"  {os.path.getsize(p):>8,}  truncated.jpg  (no EOI: jpeg.zig:158 must refuse)")

    cmyk = Image.fromarray(photo(48, 32), "RGB").convert("CMYK")
    p = os.path.join(args.fixtures, "cmyk.jpg")
    cmyk.save(p)
    print(f"  {os.path.getsize(p):>8,}  cmyk.jpg  (4 components: jpeg.zig:157 -> CmykJpeg)")

    p = os.path.join(args.fixtures, "corrupt.webp")
    open(p, "wb").write(b"RIFF\x00\x00\x00\x00WEBPVP8 ")
    print(f"  {os.path.getsize(p):>8,}  corrupt.webp  (WebPGetInfo must reject)")
    print("done")


if __name__ == "__main__":
    main()
