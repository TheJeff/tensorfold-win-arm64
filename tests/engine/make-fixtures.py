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


def document_pdf():
    """A minimal one-page PDF whose facts exist only if PDFium rendered it: the
    printed word PDFIUM-OK plus a green and a magenta block. Hand-assembled (no
    PDF library dependency) with byte-exact xref offsets, so it is deterministic."""
    stream = (
        b"0 0.8 0 rg\n72 540 200 100 re f\n"
        b"0.9 0 0.9 rg\n320 540 200 100 re f\n"
        b"0 0 0 rg\nBT /F1 36 Tf 72 700 Td (PDFIUM-OK) Tj ET\n"
    )
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref}\n%%EOF\n").encode()
    return bytes(out)


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

    # PDF fixtures for the --vision-pdf path: the tower can only read the printed
    # word if PDFium really rendered the page; corrupt.pdf is a truncated copy.
    doc = document_pdf()
    p = os.path.join(args.fixtures, "document.pdf")
    open(p, "wb").write(doc)
    print(f"  {os.path.getsize(p):>8,}  document.pdf  (PDFIUM-OK text + green/magenta blocks)")
    p = os.path.join(args.fixtures, "corrupt.pdf")
    open(p, "wb").write(doc[: int(len(doc) * 0.6)])
    print(f"  {os.path.getsize(p):>8,}  corrupt.pdf  (truncated: PDFium must refuse)")
    print("done")


if __name__ == "__main__":
    main()
