# Optional Windows ARM64 multimedia dependencies

This is a development reference for adding JPEG, WebP, video and PDF decoding to the pinned Windows ARM64 TensorFold fork. It is **not required to build or serve text models**, including supported Qwen checkpoints. The missing pieces are optional native libraries and Windows build/link steps. These notes describe what was investigated in November 2026; check the pinned TensorFold source and current upstream implementation before relying on version or dependency assumptions.

## Pins this work was built against

| piece | pin | where it is recorded |
| --- | --- | --- |
| TensorFold | Repository's `tensorfold/` submodule (v1.2.6-based Windows branch, `win-arm64/v1.2.6`) | `.gitmodules` and the superproject's submodule gitlink; **not** the older recipe's `TF_REF` |
| Bolt recipe | Repository's pinned `bolt-recipe/` submodule | gitlink for `bolt-recipe/` |
| xgrammar | Repository's pinned `xgrammar/` submodule (v0.2.8 lineage) | gitlink for `xgrammar/` |
| libjpeg-turbo | **3.1.4.1** | `zig/src/core/picture/jpeg.zig` `pinned` |
| libwebp | **1.6.0** (`0x010600`) | `zig/src/core/picture/webp.zig` `pinned` |
| FFmpeg | **9.0.2** | `zig/build/video.zig` `pinned` |
| Zig | 0.17.0 aarch64-windows | `tools/` |
| CUDA | 13.4.59 | build env |

## Step 0 — check upstream before writing any code

Everything we hit was an unported path in an otherwise working tree, so the odds are good that
somebody fixed one of these in the meantime. Run these first; if a fix landed, drop our local patch
instead of carrying it.

**TensorFold** (compare the pinned `tensorfold/` checkout with upstream):

```bash
git ls-remote https://github.com/ashhart/TensorFold.git HEAD          # is main past eea9dc9c?
git fetch --depth 50 https://github.com/ashhart/TensorFold.git main   # then diff the files below
git diff HEAD FETCH_HEAD -- docs/WINDOWS.md \
    zig/src/platform/optional_libraries.zig zig/src/core/lanes/grammar.zig \
    zig/src/core/picture/webp.zig zig/build/video.zig zig/build/grammar.zig
```

What to look for, and what it would mean:

- **Grammar is already Windows-aware in the pinned v1.2.3-based fork**: both the optional library registry and lane loader name `tfgrammar.dll`. The historical `local-patches/0001-grammar-dll-windows.patch` should **not** be applied. Check for regressions when updating the submodule.
- a `win` branch on the **webp** entry and in `picture/webp.zig`'s `library` → skip the name patch
  in item 2.
- `docs/WINDOWS.md` mentioning jpeg, video or webp at all, or a `zig build video`/`jpeg` step with
  a Windows branch → read it before porting anything yourself; upstream may have chosen the same
  route (shared vs static FFmpeg) and its choice beats ours.
- release notes / a Windows-arm64 asset in a release → prefer the binary over a source build.

**Optional Bolt recipe** (`MiaAI-Lab/Nemotron-3.5-Bolt-TensorFold-DGX-Spark`):

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

**Gap:** TensorFold loads `turbojpeg.dll` (name is already Windows-aware in `picture/jpeg.zig` line 20,
and `TENSORFOLD_LIBTURBOJPEG` overrides the path), but **no ARM64 Windows binary exists for the pinned
3.1.4.1**. Upstream began shipping one later: 3.2.1 (2026-10-27) publishes
`libjpeg-turbo-3.2.1-vc-arm64.exe`, and 3.2.1 is the current Active/Stable release. The pin refuses it.
So this is still the one component that has to be compiled here.

**DONE — 2026-11-17**, by `build-jpeg.bat` at the repo root. `turbojpeg.dll` (783,360 bytes,
sha256 `e2496bb6b8dca3b34175f4a7ec418ed2f7772bc7fc42d8e7176428d6450431af`) is installed in
`tensorfold/zig-out-v126/native/lib`. What the build actually needed, versus what was assumed:

- **No extra tools.** CMake and Ninja both ship inside VS 2022 Build Tools
  (`Common7\IDE\CommonExtensions\Microsoft\CMake\{CMake\bin,Ninja}`) — there is no need to install
  either, and neither is on `PATH` by default. NASM is x86-only and is not used.
- **Neon SIMD builds under MSVC arm64 unchanged.** With `-DWITH_SIMD=1` CMake reports
  `Use full Neon SIMD intrinsics implementation (NEON_INTRINSICS = ON)` and
  `SIMD extensions: arm64`. No `-DWITH_SIMD=0` fallback and no clang-cl was needed.
- Working configure line: `-G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=ON
  -DENABLE_STATIC=OFF -DWITH_JPEG8=ON -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DWITH_SIMD=1
  -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64`. `WITH_TURBOJPEG` is already on by
  default, so the `-DWITH_TURBOJPEG=ON` this file used to recommend was redundant.
- The DLL is **self-contained**: it imports only `KERNEL32.dll` (CMake picked the static CRT,
  `WITH_CRT_DLL = 0`), so no Visual C++ redistributable has to be installed on the box.

**How the pin actually works**, because it decides the verification test — `jpeg.zig` `versionIs()`
(locates the loaded module with `platform.libraryOf` on Windows, where `dladdr` is unavailable),
**reads the DLL's own file bytes** and greps for the literal `libjpeg-turbo version <X> (build <Y>)`,
then requires `X == pinned` exactly. It also requires all seven of `tj3Init`, `tj3Destroy`, `tj3Set`,
`tj3Get`, `tj3DecompressHeader`, `tj3Decompress8` and `tj3GetErrorCode` to be exported, or it treats
the library as simply absent. Both are checkable without starting the server:

```
dumpbin /exports turbojpeg.dll          → all seven tj3* symbols
findstr /m /c:"libjpeg-turbo version 3.1.4.1" turbojpeg.dll
```

Our build reports `libjpeg-turbo version 3.1.4.1 (build 20261117)` and exports all seven.

**Confirmed by the engine itself**, with no model loaded — `tensorfold-native capabilities --json`
reports per-library status, and this is the authoritative check:

```
libjpeg-turbo    soname=turbojpeg.dll        found:true   usable:true    problem:null
```

`usable` is the real gate, not `found`: the grammar entry is `found:true, usable:null`. libwebp
reported `found:false, usable:false` until `TENSORFOLD_LIBWEBP` was set (Item 2); with it, both
decoders report `usable:true` (re-verified 2026-11-18 by `verify-engine.ps1 -Tier Probes`).
The same command is the fastest way to check any of the other three, and it needs no GPU work.

**The vision path's other dependency is already satisfied.** `--vision` on CUDA needs cuBLASLt for the
vision towers ("CUDA vision towers (--vision) and CUDA cuBLASLt projections"), and it reports
`found:true`. So the missing decoders, not the GPU libraries, are what has been blocking images.

**The pin decision (still open, worth an explicit call).** Moving the pin to 3.2.1 would trade the
official ARM64 binary for upstream's own security fixes, and the changelog looks alarming — it lists
**CVE-2026-75466** (partial decompression via `tj3DecompressToYUV8`, which can return a width and
height larger than the source and overrun the caller's buffer) plus roughly a dozen buffer-overrun and
use-after-free fixes. Read against what TensorFold actually binds, most of it does not apply: the
decoder uses whole-image `tj3Decompress8` into an RGB or gray buffer and **never calls the
compress, transform, scale, `tjloadimage`, YUV or partial/region decompression APIs** where nearly
every one of those CVEs lives. The exposure that does reach us is partial-decompression handling of
malformed files, and that is already addressed from TensorFold's side — `walk()` refuses a JPEG with
no end marker (`jpeg.zig` line 158), and upstream's `a0da83b48` adds the matching "every pixel was
written" check on top. Recommendation: **stay on a source-built 3.1.4.1** for the Pillow-12.3 pixel
parity, and revisit the pin only when something needs a 3.2.x behaviour.

**Verify:** POST a JPEG as a base64 data URL to `/v1/chat/completions` with `--vision` and require a
200 plus a description that matches the picture. A version mismatch returns the `wrong_version`
message naming libjpeg-turbo 3.1.4.1 — if that appears, the build's version string is wrong, not the
pixels.

## Item 2 — WebP (libwebpdecoder)

**Gap:** two spots have no Windows name — `optional_libraries.zig` line 36 (mac/else only) and
`picture/webp.zig` `library` (`libwebpdecoder.3.dylib` / `libwebpdecoder.so.3`). Pinned 1.6.0, and
the decoder version must pack to `0x010600`.

**DONE — 2026-11-17**, by `build-webp.bat` at the repo root. Two DLLs go in
`tensorfold/zig-out-v126/native/lib` — the decoder needs both:

| File | Bytes | sha256 |
| --- | --- | --- |
| `libwebpdecoder.dll` | 232,448 | `78289216a6b0680f56171f227d0b31f0af27f8d100040ddae98184b80ba79ade` |
| `libsharpyuv.dll` | 129,536 | `ef3a60f024c37fc403db2622e0ea34635857b9a2e249bdcf3e4094a94762c69f` |

What the build actually needed:

- **`webpdecoder` is an unconditional CMake target**, so turning every `WEBP_BUILD_*` option off
  still produces it; there is no "decoder only" switch to find. Do ship `libsharpyuv.dll` beside it.
- **`-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` matters.** Without it the decoder imports
  `VCRUNTIME140.dll` and the box needs the Visual C++ redistributable. With it the only import is
  `KERNEL32.dll`, matching `turbojpeg.dll`.
- Arm64 Neon is detected and used (`WEBP_HAVE_FLAG_NEON - Success`); the x86 and MIPS probes all
  fail, which is correct here.

**The env var is required, not merely cheapest — measured.** With both DLLs sitting in `../lib` and
no env var, the engine reports:

```
libwebp  found=False  usable=False  problem=libwebpdecoder.so.3 is required for WebP inputs (--vision)
```

Set `TENSORFOLD_LIBWEBP` and it becomes `found=True usable=True problem=null`. The engine's own
message prescribes exactly that variable, so this is the supported route and **the fork carries no
patch for it** — which is worth keeping, since `webp.zig` is upstream code. Put it in
`gui/models.json` under that model's `env`:

```json
"TENSORFOLD_LIBWEBP": "C:/Projects/tensorfold-win-arm64/tensorfold/zig-out-v126/native/lib/libwebpdecoder.dll"
```

One cosmetic trap: `capabilities --json` still prints `soname=libwebpdecoder.so.3` for libwebp
*after* it has loaded successfully, because that string comes from the Linux-only name list rather
than from what was opened. Judge by `usable`, never by `soname`.

If the env var is ever undesirable, the patch is two lines — a `win` branch in `webp.zig`'s `library`
and the matching name in `optional_libraries.zig` — but it is permanent fork delta in a file upstream
owns, so prefer the env var.

**Verified at the level that matters.** `tests/engine/pixel-parity.py` loads the built DLL through
ctypes, calls the three entry points `webp.zig` binds (`WebPGetDecoderVersion`, `WebPGetInfo`,
`WebPDecodeRGBAInto`) and compares every byte to Pillow's decode of the same file:
`WebPGetDecoderVersion() == 0x010600`, and lossy *and* lossless fixtures both come back at
**max channel diff 0**.

**Verify:** WebP data URL, same test as JPEG — or just run `tests/engine/verify-engine.ps1`.

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

## Item 4 — PDF (pdfium.dll)

**This item was missing from this file entirely.** A fourth optional decoder exists upstream and has
never been planned here. `optional_libraries.zig` line 41 declares it:

```zig
item(.pdfium, "PDFium", if (mac) &.{"libpdfium.dylib"} else if (win) &.{"pdfium.dll"} else &.{"libpdfium.so"},
     "PDF inputs (--vision --vision-pdf)", "install PDFium (chromium/7725) in lib/ beside the server
     or set TENSORFOLD_LIBPDFIUM to its file", error.PdfiumLibraryUnavailable, "TENSORFOLD_LIBPDFIUM", true),
```

Two things make it worth more than a fourth entry on the list:

- The **Windows name is already correct** (`pdfium.dll`), and line 118 has a **Windows-only loader
  path** — `if (is_win and s.id == .pdfium and @hasDecl(Sys.DynLib, "openRestricted")) return
  Sys.DynLib.openRestricted(path)` — so upstream has specifically anticipated PDFium on Windows. Of
  the four gaps in this file, this is the only one where Windows was designed for.
- It brings its own gate: PDF input needs both `--vision` **and** `--vision-pdf`
  (`cli/vision.zig` line 68), so it is a separate switch from the image path.

**Unknown, and it decides the cost:** there is no published `chromium/7725` Windows ARM64 build of
PDFium that this repo has verified. Where the other three are build problems, this may be a sourcing
problem — PDFium normally comes from a Chromium checkout or a vendor's prebuilt, and the pin is
specific. **Check sourcing before budgeting any build time**, and check whether upstream has grown a
`zig build pdfium` step since.

**Verify:** a PDF through the document path with `--vision --vision-pdf`; the request should be
accepted rather than answered with `PdfiumLibraryUnavailable`.

## How to make images work here — three things, and only one of them was the decoder

Measured 2026-11-17: images work end to end on this box, and the path is scripted. Three things are
required, and the decoders were never the whole story:

1. **The decoders** — `turbojpeg.dll` 3.1.4.1 and `libwebpdecoder.dll` 1.6.0 from `build-jpeg.bat` /
   `build-webp.bat`, pixel-exact against Pillow. `libwebpdecoder` needs `TENSORFOLD_LIBWEBP` because
   `core/picture/webp.zig:20` has no Windows branch.
2. **`--vision` on the serve command** — from the model's `extra_args` in `gui/models.json`, spliced
   onto the template in `gui/serve.json`. Both are read when the GUI **starts**.
   Keep `--vision-image-tokens` at **4096 or below**: FlashNext CUDA's `checkLimits`
   (`vision/qwen_cuda_media.zig`) aborts the whole load above it (`BadImageLimits`) even though the
   CLI accepts up to 262144 — a profile set to 16384 killed every LOAD until it was corrected.
3. **A checkpoint whose vision tower is bf16** — the one that was missing, and the reason `--vision`
   on the stock checkpoint aborts the entire load instead of degrading gracefully:

```
error: model.visual.blocks.0.attn.qkv.weight: f8_e4m3 { 3456, 1152 }, expected bf16 { 3456, 1152 }
tensorfold: the native CUDA engine cannot load ...\Qwen3.8-Flash-Next-FP4-Local (UnexpectedTensor)
```

ModelOpt quantised the tower: 499 `model.visual.*` tensors, of which 333 are weights and 166 are
`weight_scale` twins, in two formats — MXFP8 (`F8_E4M3` weight + `U8` E8M0 scale, group 32) and NVFP4
(`U8` packed weight + `F8_E4M3` scale, group 16, plus `weight_scale_2`). The checkpoint's
`quantization_config.ignore` has 10 entries and **none of them mention visual**, while
`vision_config.dtype` still says `bfloat16`. The export simply did not exclude the tower.

**Correction to this file's earlier claim.** The rejection is *not* in `families/radio/weights.zig` —
that is the Bolt/RADIO path, and Bolt's checkpoint has **0** visual tensors anyway despite advertising
a full `vision_config`. The real site is `vision/qwen_cuda_weights.zig:36`, whose `Reader.get()` calls
`r.ck.expect(name, .bf16, shape)` and returns `error.UnexpectedTensor` on anything else. The same
loader demands exactly **333** tensors (`3 + 27×12 + 6`) and at `:80` fails with
`error.UnusedVisionTensors` if any visual tensor is left unread — which is why the scale twins have to
be *deleted*, not merely ignored.

### The splice — `scripts/splice-vision-tower.py`

Takes the 333 bf16 visual tensors out of the QAD checkpoint's shard 21 and appends them to a copy of
FP4-Local's shard 15. Non-destructive: the original is verified to still hold its 499 quantised
tensors afterwards.

- the source data section is kept verbatim and original offsets are reused, so the 74,742 non-visual
  tensors are byte-identical **by construction** rather than by comparison
- the 499 quantised visual tensors are dropped and the 333 bf16 ones appended
- `config.json` is rewritten: `ignore` 10 → 11 (adds `model.visual*`), `quantized_layers` 545 → 435
- `model.safetensors.index.json` is patched, dropping the 166 stale `weight_scale` entries
  (375,487 → 375,321 names) — leaving them in is the failure this script's own verifier caught
- everything else is hardlinked: 70 files, 66 links, **5.41 GiB** of actual disk
- `verify()` re-reads the output and runs 15 checks ending in `SPLICE OK`

Where the bf16 came from: `nvidia/Qwen3.8-Flash-Next-NVFP4-QAD` lists `model.visual*` in its *own*
`ignore`, so its tower survived quantisation, and its `vision_config` is identical to FP4-Local's.
Only its 0.84 GiB shard 21 is ever read — the 120.8 GiB model is never loaded. That sidestep is the
whole reason this route beats "just serve QAD" on a 96 GB box.

```
python scripts/splice-vision-tower.py
tests\engine\verify-engine.ps1 -Tier Serve -Attach http://127.0.0.1:8889 `
    -Model models\Qwen3.8-Flash-Next-FP4-Local-vision
```

Measured here: **0 failed, 0 warned** — `photo.jpg`, `photo.webp` and `photo_lossless.webp` each
decoded and answered, and `truncated.jpg`, `cmyk.jpg`, `corrupt.webp` each refused with 400. Proof the
tower is really reading pixels rather than pattern-matching the prompt:

> A grainy, split-screen image displays a green square and magenta circle on the left, with a faint
> blue rectangle on the right, all set against a noisy, gradient background.

### Still open

- **Route B — teach the loader quantised vision.** `vision/qwen_cuda_weights.zig` should accept MXFP8
  and NVFP4 and dequantise into its bf16 sink, making the splice unnecessary. Upstream already does
  this for another family: `families/glm/cuda_vision.zig:555` maps `model.visual.*` to `.mxfp8` /
  `.w4a16_nvfp4`, with `core/quant/keys.zig` canonicalising the prefix — so the format code exists.
  Host-testable by extending `vision/qwen_cuda_weights_fixture.zig`, which already emits a synthetic
  tower. Engine work, so: ATC issue, claim, `atc who` overlap check, PR pre-flight.
- **Route C — report the packaging bug.** An exporter that quantises a tower while `vision_config`
  still advertises `bfloat16` will strand every user who trusts that field.
- **Reclaim 3.6 GiB.** `downloads/qad-vision/` is fully embedded in the spliced checkpoint; delete it
  once you trust the output, and re-fetch shard 21 alone if you ever need to rebuild.

**Operational gotcha, found the hard way:** `gui/models.json` **and** `gui/serve.json` are read when
the GUI **starts**. Editing them and then restarting only the *server* leaves the GUI holding a stale
in-memory catalog — observed directly: a running `tensorfold-native` whose command line had no
`--vision` even though `models.json` specified it. Restart the GUI (or use the Reload action, which
re-reads both), or launch the engine directly. To check what the GUI *would* run without touching the
GPU: `tensorfold-gui.exe --plan <n> --plan-out plan.txt`.

Note also that `tensorfold-native serve --help` **omits** `--vision`, `--vision-urls`, `--vision-pdf`,
`--vision-max-images` and `--vision-image-tokens` from its usage text while `server/cli.zig:479`
parses all of them. Trust `capabilities --json`'s `serve.flags`, not the help text.

## The build gate — `tests/engine/verify-engine.ps1`

Run this against a **candidate** tree before promoting it over the engine you serve. It never touches
a running server; point `-Exe` at a fresh build and it checks only that build. Exit code is the number
of failures, so it drops into a script.

```powershell
# cheap sanity on the installed engine (seconds, no GPU)
.\tests\engine\verify-engine.ps1

# the full gate on a candidate build, including booting a model (minutes)
.\tests\engine\verify-engine.ps1 -Exe C:\...\zig-out-main\native\bin\tensorfold-native.exe -Tier All
```

Four tiers, cheapest first:

| Tier | Cost | What it proves |
| --- | --- | --- |
| `Probes` | ~2 s, no GPU | the binary answers, `capabilities --json` parses, chip is `nvidia-sm121`, cuda backend present, every optional library is where expected, and all 15 serve flags the launchers depend on still exist |
| `Decode` | ~5 s, no GPU | `pixel-parity.py`: the built decoders reproduce Pillow's pixels **byte for byte** |
| `Vision` | ~20 s, no GPU | `vision-probe.py` against a server that is already up (`-Attach`): five facts that exist **only in the pixels**, an image-vs-text prompt-token delta, both decoders fed raw bytes, and broken input refused with 400 |
| `Serve` | minutes, GPU | boots a model, proves JPEG and WebP survive the vision tower into a reply, and that bad input is **refused**; holds the system awake while it runs |

Three design points worth keeping:

- **It reads `gui/models.json` and applies that model's `env` before probing.** Without this,
  `capabilities` reports libwebp missing when the GUI would have supplied it via
  `TENSORFOLD_LIBWEBP` — and, far worse, could pass a build the GUI would actually fail on. It
  therefore also asserts `--vision` is in `extra_args`, since its absence makes images silently
  unavailable rather than producing an error.
- **`Decode` is the tier that justifies the version pins.** A decoder that *loads* proves very
  little; one that reproduces Pillow's pixels byte-for-byte proves the pin is honoured. It calls the
  built DLLs through ctypes using the same signatures `jpeg.zig` and `webp.zig` declare — including
  `tj3Decompress8`'s caller-owned `[*]u8` buffer at `jpeg.zig:40`, which is not the allocating
  `tjDecompress2` habit and will fault the process if written wrong.

- **Image checks send `chat_template_kwargs {enable_thinking: false}`.** This is a thinking model, and
  `max_tokens` counts reasoning *and* answer, so a small budget returns `finish_reason=length` with
  `content` empty and every word in `reasoning_content`. The image assertions then fail with "empty
  reply" and look *exactly* like a decoder bug — which is how it cost a full debugging cycle before it
  was identified. Positive and negative calls both disable thinking, and the failure text now prints
  `reasoning_content` too, so this cannot masquerade as an image defect again.

**Run the Serve tier on AC power.** The gate holds `SetThreadExecutionState`
(ES_SYSTEM_REQUIRED|ES_DISPLAY_REQUIRED) while it boots and probes, because an idle-timeout Modern
Standby entry mid-load bugchecks this box: on 2026-11-18 the display-power watchdog in NVIDIA 621.24
timed out during a vision load and the whole machine rebooted (0x19C WIN32K_POWER_WATCHDOG_TIMEOUT,
Kernel-Power 41 with `ConnectedStandbyInProgress=true`). The keep-awake call blocks the idle path;
AC keeps the DC 5-minute display timeout out of the picture as well.

`Serve` includes the negative cases, because silently accepting these is a real defect rather than
a curiosity: `truncated.jpg` (no EOI — `jpeg.zig:158` must refuse), `cmyk.jpg` (4 components —
`jpeg.zig:157`), `corrupt.webp` (`WebPGetInfo` must reject). A refusal only counts at **HTTP 400** —
a 500 or a timeout means the decoder crashed or the server died, which is a failure, not a pass.

Regenerate the fixtures with `python tests\engine\make-fixtures.py`. They are deterministic
(fixed seed, odd dimensions, both chroma subsampling ratios, lossy and lossless WebP) so the checked-in
set does not churn.

**Run upstream's own loader tests too.** The pixel-parity check drives the DLLs through ctypes, which
proves the library decodes correctly but only *reimplements* the call sequence. For the engine's own
loader logic — the version pin, the symbol refusal, the missing-library message — use the upstream
step, which upstream CI only ever runs on Linux:

```
tools\zig-aarch64-windows-0.17.0\zig.exe build test-codec-diagnostics-host --summary all
```

Run from `tensorfold/zig` inside a `vcvarsall.bat arm64` environment. It builds four host tests against
mock codec libraries (`missing`, `wrong`, `symbols`, `ready`) that abort on pixel work. Verified here
2026-11-17: **16/16 steps, 12/12 tests pass on Windows ARM64.** The fuller pixel tests
(`zig/src/core/picture/picture_test.zig`) live in the general `test` step, which compiles the whole
CUDA tree, so reach for it deliberately rather than as a pre-flight.

## Suggested order

1. ~~JPEG — the smallest gap, and it unlocks pictures, which is the common case.~~ **Done
   2026-11-17** via `build-jpeg.bat`.
2. ~~WebP — an hour once the libwebp build pattern exists; may need no patch at all.~~ **Done
   2026-11-17** via `build-webp.bat`, with **no fork patch** — `TENSORFOLD_LIBWEBP` in
   `gui/models.json` does it. That same entry now carries `--vision`, so JPEG and WebP are reachable
   from the GUI. The `serve-*.bat` launchers pass neither flag, so they still serve text only.
3. PDF — sourcing check first (Item 4); upstream built its Windows loader path for this one.
4. Video — the only one with a real toolchain decision.

Before any of it ships, gate the build with `tests/engine/verify-engine.ps1`.

## Keep the receipt

When adding an optional decoder, document the exact version, source or build procedure, required runtime DLLs and a verified test request. Put machine-specific measurements, filesystem paths and binary hashes in an explicitly labeled test report rather than in the general installation guide.
