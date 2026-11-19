#!/usr/bin/env python3
"""PDF path symbol gate: check pdfium.dll and turbojpeg.dll export every function
TensorFold's server/pdf.zig binds (PdfiumFns required + optional, JpegFns).

Complements `capabilities --json` (which only proves the DLL opens — PDFium reports
usable:null, like grammar) without a GPU or a model load. Stdlib only; parses the PE
export table directly so no pefile/dumpbin dependency.

Usage:
    python tests/engine/pdfium-exports.py <pdfium.dll> [turbojpeg.dll]

turbojpeg.dll defaults to tensorfold/zig-out-v126/native/lib/turbojpeg.dll relative to
the repo root. Exit code 0 = every required symbol present, 1 = something missing.
See MIA-V127-REVIEW.md for the sourcing receipt (pypdfium2 5.14.0 win_arm64 wheel).
"""
import struct
import sys
from pathlib import Path

# server/pdf.zig PdfiumFns — required (loadDynLib returns null if any is absent)
PDF_REQUIRED = [
    "FPDF_InitLibrary", "FPDF_LoadMemDocument", "FPDF_CloseDocument",
    "FPDF_GetPageCount", "FPDF_LoadPage", "FPDF_ClosePage",
    "FPDF_GetPageWidthF", "FPDF_GetPageHeightF",
    "FPDFBitmap_Create", "FPDFBitmap_Destroy", "FPDFBitmap_GetBuffer",
    "FPDFBitmap_GetStride", "FPDF_RenderPageBitmap",
]
# optional in PdfiumFns (progressive render; null is tolerated)
PDF_OPTIONAL = [
    "FPDF_RenderPageBitmap_Start", "FPDF_RenderPage_Continue", "FPDF_RenderPage_Close",
]
# server/pdf.zig JpegFns — the encoder side (PDF pages render to JPEG)
JPEG_REQUIRED = ["tj3Init", "tj3Destroy", "tj3Set", "tj3Compress8", "tj3Free"]


def exports(path):
    d = Path(path).read_bytes()
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"{path}: not a PE image")
    machine = struct.unpack_from("<H", d, pe + 4)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    ohsz = struct.unpack_from("<H", d, pe + 20)[0]  # SizeOfOptionalHeader (pe+16 is NumberOfSymbols)
    opt = pe + 24
    magic = struct.unpack_from("<H", d, opt)[0]
    if magic not in (0x10B, 0x20B):
        raise ValueError(f"{path}: bad optional-header magic {magic:#x}")
    dd = opt + (112 if magic == 0x20B else 96)
    exp_rva, _ = struct.unpack_from("<II", d, dd)
    if exp_rva == 0:
        raise ValueError(f"{path}: no export directory")
    secs = []
    st = opt + ohsz
    for i in range(nsec):
        off = st + i * 40
        vsz, va, rsz, rp = struct.unpack_from("<IIII", d, off + 8)
        secs.append((va, vsz, rp, rsz))

    def r2o(rva):
        for va, vsz, rp, rsz in secs:
            if va <= rva < va + max(vsz, rsz):
                return rp + (rva - va)
        raise ValueError(f"{path}: export RVA {rva:#x} outside any section")

    e = r2o(exp_rva)
    nnames = struct.unpack_from("<I", d, e + 24)[0]
    no = r2o(struct.unpack_from("<I", d, e + 32)[0])
    out = set()
    for i in range(nnames):
        o = r2o(struct.unpack_from("<I", d, no + i * 4)[0])
        out.add(d[o:d.index(b"\0", o)].decode())
    return machine, out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = Path(__file__).resolve().parents[2]
    jpg = sys.argv[2] if len(sys.argv) > 2 else root / "tensorfold/zig-out-v126/native/lib/turbojpeg.dll"
    fails = 0
    for path, required, optional, label in (
        (sys.argv[1], PDF_REQUIRED, PDF_OPTIONAL, "pdfium"),
        (jpg, JPEG_REQUIRED, [], "turbojpeg"),
    ):
        machine, syms = exports(path)
        arch = {0xAA64: "ARM64", 0x8664: "x64", 0x14C: "x86"}.get(machine, f"{machine:#x}")
        print(f"{label}: {Path(path).name}  machine={arch}  exports={len(syms)}")
        if machine != 0xAA64:
            print(f"  FAIL: expected ARM64 (0xAA64) on this box")
            fails += 1
        missing = [s for s in required if s not in syms]
        if missing:
            print(f"  FAIL: missing required symbols: {missing}")
            fails += 1
        else:
            print(f"  ok: all {len(required)} required symbols present")
        if optional:
            print(f"  optional progressive-render: { {s: (s in syms) for s in optional} }")
    print("PASS" if fails == 0 else f"FAIL ({fails})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
