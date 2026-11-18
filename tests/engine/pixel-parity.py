#!/usr/bin/env python3
"""Pixel-parity check for the optional Windows ARM64 decoders.

The pins in zig/src/core/picture/jpeg.zig and webp.zig exist for one reason: the
pixels must be what Pillow produced when TensorFold 0.6.6 was qualified (Pillow
12.3.0 for JPEG, Pillow 13.0.0's bundled libwebp for WebP). A locally built DLL
that loads is not enough -- it has to decode identically.

This calls the built DLLs through ctypes using the same TurboJPEG 3 call
sequence and parameter constants that jpeg.zig uses (tj3Init/tj3Set/
tj3DecompressHeader/tj3Decompress8, STOP_ON_WARNING, PF_RGB), and the same
libwebp entry points webp.zig binds (WebPGetInfo, WebPDecodeRGBAInto), then
compares every byte against Pillow's own decode of the same file.

Usage:  python pixel-parity.py [--libdir <dir>] [--fixtures <dir>] [-v]
Exit 0 when every check passes.
"""
import argparse
import ctypes
import os
import sys

import numpy as np
from PIL import Image

# TurboJPEG 3 constants, copied from zig/src/core/picture/jpeg.zig lines 23-32.
INIT_DECOMPRESS = 1
PF_RGB = 0
PARAM_STOP_ON_WARNING = 0
PARAM_WIDTH = 5
PARAM_HEIGHT = 6
ERR_WARNING = 0

HERE = os.path.dirname(os.path.abspath(__file__))
FAILURES = []


def check(name, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + (("  " + detail) if detail else ""))
    if not ok:
        FAILURES.append(name)
    return ok


def load_dll(libdir, name):
    path = os.path.join(libdir, name)
    if not os.path.exists(path):
        return None, None
    try:
        return ctypes.CDLL(path), path
    except OSError as exc:
        return None, f"{path}: {exc}"


def decode_jpeg(dll, blob):
    """Decode with the TurboJPEG 3 API exactly as jpeg.zig drives it."""
    dll.tj3Init.restype = ctypes.c_void_p
    dll.tj3Init.argtypes = [ctypes.c_int]
    dll.tj3Set.restype = ctypes.c_int
    dll.tj3Set.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    dll.tj3Get.restype = ctypes.c_int
    dll.tj3Get.argtypes = [ctypes.c_void_p, ctypes.c_int]
    dll.tj3DecompressHeader.restype = ctypes.c_int
    dll.tj3DecompressHeader.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    dll.tj3Decompress8.restype = ctypes.c_int
    # jpeg.zig:40 types the 4th argument as [*]u8, NOT [*]*u8: TurboJPEG 3 does not
    # allocate, the caller owns the output buffer. Passing a pointer-to-pointer makes
    # the library scribble over a ctypes object and fault the process, so this mirrors
    # the Zig signature exactly rather than the older tjDecompress2 habit.
    dll.tj3Decompress8.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                                   ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int, ctypes.c_int]
    dll.tj3GetErrorCode.restype = ctypes.c_int
    dll.tj3GetErrorCode.argtypes = [ctypes.c_void_p]
    dll.tj3Destroy.restype = None
    dll.tj3Destroy.argtypes = [ctypes.c_void_p]

    h = dll.tj3Init(INIT_DECOMPRESS)
    if not h:
        raise RuntimeError("tj3Init returned NULL")
    try:
        dll.tj3Set(h, PARAM_STOP_ON_WARNING, 1)
        if dll.tj3DecompressHeader(h, blob, len(blob)) != 0:
            raise RuntimeError(f"tj3DecompressHeader failed code={dll.tj3GetErrorCode(h)}")
        w, hh = dll.tj3Get(h, PARAM_WIDTH), dll.tj3Get(h, PARAM_HEIGHT)
        if w <= 0 or hh <= 0:
            raise RuntimeError(f"bogus header size {w}x{hh}")
        # Caller-allocated, exactly like jpeg.zig: no tj3Free, nothing shared across
        # the DLL heap. Size from the header we just read, so a bad header faults here
        # rather than silently comparing the wrong rectangle.
        storage = (ctypes.c_ubyte * (w * 3 * hh))()
        if dll.tj3Decompress8(h, blob, len(blob), storage, PF_RGB, 0) != 0:
            raise RuntimeError(f"tj3Decompress8 failed code={dll.tj3GetErrorCode(h)}")
        return np.frombuffer(bytes(memoryview(storage)), dtype=np.uint8).reshape(hh, w, 3)
    finally:
        dll.tj3Destroy(h)


def decode_webp(dll, blob):
    """Decode with the three libwebp entry points webp.zig binds (Fns, line 22-26)."""
    dll.WebPGetInfo.restype = ctypes.c_int
    dll.WebPGetInfo.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
    dll.WebPDecodeRGBAInto.restype = ctypes.POINTER(ctypes.c_ubyte)
    dll.WebPDecodeRGBAInto.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                       ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    dll.WebPGetDecoderVersion.restype = ctypes.c_int
    dll.WebPGetDecoderVersion.argtypes = []

    w, h = ctypes.c_int(), ctypes.c_int()
    if not dll.WebPGetInfo(blob, len(blob), ctypes.byref(w), ctypes.byref(h)):
        raise RuntimeError("WebPGetInfo rejected the data")
    stride = w.value * 4
    storage = (ctypes.c_ubyte * (stride * h.value))()
    got = dll.WebPDecodeRGBAInto(blob, len(blob), ctypes.addressof(storage),
                                 ctypes.sizeof(storage), stride)
    if not got:
        raise RuntimeError("WebPDecodeRGBAInto failed")
    return np.ctypeslib.as_array(got, shape=(h.value, w.value, 4)).copy()


def pil_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)


def pil_rgba(path):
    return np.asarray(Image.open(path).convert("RGBA"), dtype=np.uint8)


def compare(label, ours, theirs):
    if ours.shape != theirs.shape:
        return check(label, False, f"shape {ours.shape} != Pillow {theirs.shape}")
    diff = int(np.abs(ours.astype(int) - theirs.astype(int)).max())
    return check(label, diff == 0, f"max channel diff {diff}, {ours.shape[1]}x{ours.shape[0]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--libdir", default=r"C:\Projects\tensorfold-win-arm64\tensorfold\zig-out-v126\native\lib")
    ap.add_argument("--fixtures", default=os.path.join(HERE, "fixtures"))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    print(f"libdir   {args.libdir}")
    print(f"fixtures {args.fixtures}\n")

    # ---- JPEG ---------------------------------------------------------------
    print("JPEG (turbojpeg.dll vs Pillow)")
    from PIL import features
    print(f"  Pillow {Image.__version__}  webp={features.check('webp')}  jpg={features.check('jpg')}")
    dll, info = load_dll(args.libdir, "turbojpeg.dll")
    if dll is None:
        check("turbojpeg.dll loads", False, str(info))
    else:
        check("turbojpeg.dll loads", True, os.path.basename(info))
        for fname in ("gradient.jpg", "photo.jpg", "photo_444.jpg"):
            # gradient: clean low-frequency; photo.jpg: 4:2:0 chroma subsampling;
            # photo_444.jpg: no subsampling, so the upsample path is not exercised
            # and any divergence there is the decoder's, not the resampler's.
            p = os.path.join(args.fixtures, fname)
            if not os.path.exists(p):
                check(f"{fname} fixture present", False)
                continue
            blob = open(p, "rb").read()
            try:
                compare(f"{fname} pixels match Pillow", decode_jpeg(dll, blob), pil_rgb(p))
            except Exception as exc:  # noqa: BLE001
                check(f"{fname} decodes", False, str(exc))

    # ---- WebP ---------------------------------------------------------------
    print("\nWebP (libwebpdecoder.dll vs Pillow)")
    dll, info = load_dll(args.libdir, "libwebpdecoder.dll")
    if dll is None:
        check("libwebpdecoder.dll loads", False, str(info))
    else:
        check("libwebpdecoder.dll loads", True, os.path.basename(info))
        ver = dll.WebPGetDecoderVersion()
        # webp.zig refuses anything but 0x010600 (1.6.0); see pinned_code, line 11.
        check("WebPGetDecoderVersion == 0x010600 (1.6.0)", ver == 0x010600,
              f"got 0x{ver:06x}")
        for fname in ("photo.webp", "photo_lossless.webp"):
            p = os.path.join(args.fixtures, fname)
            if not os.path.exists(p):
                check(f"{fname} fixture present", False)
                continue
            blob = open(p, "rb").read()
            try:
                compare(f"{fname} pixels match Pillow", decode_webp(dll, blob), pil_rgba(p))
            except Exception as exc:  # noqa: BLE001
                check(f"{fname} decodes", False, str(exc))

    print("\n%d check(s) failed" % len(FAILURES))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
