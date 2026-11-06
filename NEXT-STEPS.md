# What's still missing, and what to re-check upstream before building it

Status 2026-11-01. Text serving, structured output and tool calls work (see `README.md`). The three
gaps below are **images (JPEG), images (WebP) and video** — all of them are "the library isn't there
yet", not "the code can't do it".

Re-read this file before starting; the first section is the part that saves the most time.

## Pins this work was built against

| piece | pin | where it is recorded |
| --- | --- | --- |
| TensorFold | `eea9dc9c` (v1.1.6) | `bolt-recipe/scripts/config.sh` `TF_REF` |
| Bolt recipe | `646c947` (PR #7 merged) | `bolt-recipe/` |
| xgrammar | v0.2.8 | `zig/src/platform/grammar_library.zig` |
| libjpeg-turbo | **3.1.4.1** | `zig/src/core/picture/jpeg.zig` `pinned` |
| libwebp | **1.6.0** (`0x010600`) | `zig/src/core/picture/webp.zig` `pinned` |
| FFmpeg | **9.0.2** | `zig/build/video.zig` `pinned` |
| Zig | 0.17.0 aarch64-windows | `tools/` |
| CUDA | 13.4.59 | build env |

## Step 0 — check upstream before writing any code

Everything we hit was an unported path in an otherwise working tree, so the odds are good that
somebody fixed one of these in the meantime. Run these first; if a fix landed, drop our local patch
instead of carrying it.

**TensorFold** (`ashhart/TensorFold`, ours is at `eea9dc9c`):

```bash
git ls-remote https://github.com/ashhart/TensorFold.git HEAD          # is main past eea9dc9c?
git fetch --depth 50 https://github.com/ashhart/TensorFold.git main   # then diff the files below
git diff eea9dc9c FETCH_HEAD -- docs/WINDOWS.md \
    zig/src/platform/optional_libraries.zig zig/src/core/lanes/grammar.zig \
    zig/src/core/picture/webp.zig zig/build/video.zig zig/build/grammar.zig
```

What to look for, and what it would mean:

- a `win` branch on the **grammar** entry in `optional_libraries.zig` and a Windows name in
  `lanes/grammar.zig` → `local-patches/0001-grammar-dll-windows.patch` is obsolete; rebuild clean
  and delete it.
- a `win` branch on the **webp** entry and in `picture/webp.zig`'s `library` → skip the name patch
  in item 2.
- `docs/WINDOWS.md` mentioning jpeg, video or webp at all, or a `zig build video`/`jpeg` step with
  a Windows branch → read it before porting anything yourself; upstream may have chosen the same
  route (shared vs static FFmpeg) and its choice beats ours.
- release notes / a Windows-arm64 asset in a release → prefer the binary over a source build.

**Recipe repo** (`MiaAI-Lab/Nemotron-3.5-Bolt-TensorFold-DGX-Spark`):

```bash
curl -s "https://api.github.com/repos/MiaAI-Lab/Nemotron-3.5-Bolt-TensorFold-DGX-Spark/commits?since=2026-11-01T00:00:00Z" | \
  python -c "import json,sys; [print(c['sha'][:8], c['commit']['message'].splitlines()[0]) for c in json.load(sys.stdin)]"
```

Watch `docs/windows.md` and `engine/`: if the recipe starts building `libtfvideo`/`libturbojpeg`
for Windows, copy its flags rather than inventing ours.

**Dependencies:**

- libjpeg-turbo: `https://api.github.com/repos/libjpeg-turbo/libjpeg-turbo/releases` and the
  official-binaries page — the Windows section is currently "x86 and x64" only. An ARM64 Windows
  package would remove the whole of item 1. Anything newer than 3.1.4.1 is **not** usable without
  changing TF's pin, because the pixel output is pinned to Pillow 12.3's build.
- libwebp: same, pinned 1.6.0.
- FFmpeg/BtbN: `curl -s https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest` and grep
  asset names for `winarm64`. Assets rotate daily; the URLs used below are `latest`-relative and
  will keep working, but re-check that a `-9.0` asset still exists once FFmpeg 10 lands.

## Item 1 — JPEG (turbojpeg.dll)

**Gap:** TensorFold loads `turbojpeg.dll` (name is already Windows-aware in `picture/jpeg.zig`, and
`TENSORFOLD_LIBTURBOJPEG` overrides the path), but the libjpeg-turbo project ships **no ARM64
Windows binary** — official packages are x86/x64 only. So this is the one component that has to be
compiled here.

**Plan:**

1. Build libjpeg-turbo **3.1.4.1** from source for `aarch64-windows` with CMake + MSVC ARM64
   (vcvarsall arm64) or clang-cl: `-DENABLE_SHARED=ON -DWITH_TURBOJPEG=ON -DWITH_SIMD=ON`
   (Arm64 NEON paths exist in 3.1.x).
2. Put `turbojpeg.dll` in `tensorfold/zig-out/native/lib` (the loader tries `../lib` first), or set
   `TENSORFOLD_LIBTURBOJPEG` to its absolute path in `serve-bolt.bat`.
3. Serve with `VISION=1` (already the default in `config.sh`, and the RADIO tower loads fine here).

**Verify:** POST a JPEG as a base64 data URL to `/v1/chat/completions` and require a 200 plus a
description that matches the picture. A version mismatch returns the `wrong_version` message naming
libjpeg-turbo 3.1.4.1 — if that appears, the build's version string is wrong, not the pixels.

**Trap:** exactly 3.1.4.1. TF refuses other releases on purpose.

## Item 2 — WebP (libwebpdecoder)

**Gap:** two spots have no Windows name — `optional_libraries.zig` line 36 (mac/else only) and
`picture/webp.zig` `library` (`libwebpdecoder.3.dylib` / `libwebpdecoder.so.3`). Pinned 1.6.0, and
the decoder version must pack to `0x010600`.

**Plan:**

1. Build libwebp 1.6.0 decoder-only for `aarch64-windows` (CMake, `-DWEBP_BUILD_*` off except the
   decoder; output `webpdecoder.dll` or `libwebp.dll` depending on flags).
2. Cheapest path needs **no patch**: `TENSORFOLD_LIBWEBP=<path to the DLL>` is checked before the
   name list. If you want it to work without the env var, add `webpdecoder.dll` to
   `optional_libraries.zig` and a `win` branch in `webp.zig`'s `library` (same two-line shape as
   `local-patches/0001`).

**Verify:** WebP data URL, same test as JPEG.

## Item 3 — Video (tfvideo.dll)

**Gap, and it is bigger than the loader.** The loader is already fine on Windows (`tfvideo.zig`
tries a bare `tfvideo.dll`, and `optional_libraries.zig` names it), so no code change is needed
there. What's missing is the **build**:

- `zig build video -Dffmpeg=PREFIX` wants a *static* prefix: `PREFIX/include` plus
  `PREFIX/lib/libavformat.a`, `libavcodec.a`, `libswscale.a`, `libavutil.a`, and it links `m`.
- The only documented way to make that prefix is `tools/zig/build_ffmpeg.sh` — bash, Linux-only.
- Verified against BtbN's winarm64 9.0 assets on 2026-11-01: the **static** zip
  (`ffmpeg-n9.0-latest-winarm64-lgpl-9.0.zip`) contains only `bin/*.exe`, `doc/` and `presets/` —
  **no `lib/`, no `include/`**, so it cannot serve as the prefix. The **shared** zip
  (`…-lgpl-shared-9.0.zip`) does ship `include/` and import libraries (`avformat.lib`,
  `avcodec.lib`, `avutil.lib`, `swscale.lib`, plus `libav*.dll.a`) and `bin/avcodec-63.dll`,
  `avformat-63.dll`, `avutil-61.dll`, `swscale-10.dll`.

**Two routes:**

- **(a) quick:** patch `zig/build/video.zig` with a Windows branch that links the import libraries
  (`avformat.lib` etc.) instead of the `.a` files, drops `-lm`, and copies the four FFmpeg DLLs
  beside `tfvideo.dll`. Uses BtbN's shared build. Note its configure is not TF's: it has many more
  decoders and networking enabled, so the DLL set is bigger than the Linux build's.
- **(b) faithful:** build FFmpeg 9.0.2 for `aarch64-windows` from source with the same configure
  flags as `tools/zig/build_ffmpeg.sh` (static, PIC, `--disable-network --disable-autodetect
  --disable-everything`, decoders h264/hevc/vp8/vp9/mpeg4, demuxers mov/matroska), using
  llvm-mingw or MSYS2 clangarm64. Then the existing step is close to working unchanged (still check
  the `-lm` line and the `.a` names). This keeps the decoder set identical to the Linux build,
  which is what TF's pixel comparisons assume.

Pick (b) if video output ever needs to match the Linux receipts; (a) if it just has to decode.

**Verify:** a short mp4 data URL through `/v1/chat/completions`; the reply's `tf_video_version`
should read FFmpeg 9.0.2, and the frame description should match the clip.

## Suggested order

1. Step 0 (30 min).
2. JPEG — the smallest gap, and it unlocks pictures, which is the common case.
3. WebP — an hour once the libwebp build pattern exists; may need no patch at all.
4. Video — the only one with a real toolchain decision.

## Keep the receipt

Whatever gets done, append to `README.md`: the library version, how it was built, the DLL hash, and
one verified request. The numbers and paths are what make the next session cheap.
