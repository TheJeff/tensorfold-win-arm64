# MiaAI-Lab's v1.2.7 recipe — what transfers to this Windows ARM64 port

Review date: 2026-11-19. Subject: `MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold`
at `b956dba8` (main, 2026-11-18), reviewed against this repo's `tensorfold/` submodule
(`win-arm64/v1.2.6`, `6c6615bd0`). Question asked: did Mia solve PDF and video, are the
fixes Linux-only, and what benefits ours?

**Short answer:** PDF yes — and it is *not* Linux-only in any way that blocks us; the
engine already renders PDFs in-process on Windows, and the PDFium binary comes out of a
pypdfium2 **win_arm64 wheel** that exists and loads here (verified below). Video half —
the engine glue is portable Zig (their patch `0005`), but the FFmpeg build behind it is
still the Linux-only static build this repo's NEXT-STEPS Item 3 already describes; Mia
has not served a live video even on their Spark (compile-only). Bonus: two of their
engine patches (`0001` quantised vision tower, `0002` 16k image budget) and the big one
(`0003` FP8 KV) **apply cleanly to our v1.2.6 tree** — no v1.2.7 re-port needed to try them.

## What Mia shipped (commits, 2026-11-18)

| commit | what | Linux-only? |
| --- | --- | --- |
| `bbc91901` PDF=1 | Recipe only: extract `libpdfium.so` from the pinned **pypdfium2 5.14.0** manylinux-aarch64 wheel (sha256 `f1b696e6…`), set `TENSORFOLD_LIBPDFIUM`, pass `--vision-pdf` behind an opt-in. **No engine patch.** | The `.so` extraction is; the trick is not — see below |
| `7c56732a` VIDEO=1 | FFmpeg **9.0.2** built static from the checksummed tarball by TensorFold's own `tools/zig/build_ffmpeg.sh` (bash, Linux configure) inside the Docker image; `zig build video -Dffmpeg=PREFIX` makes `libtfvideo.so`; patch `0005` wires video into the CUDA engine. Off the loader path unless `VIDEO=1`. | The FFmpeg build script is; patch `0005` is pure Zig |
| `b956dba8` harden.sh | Trims NGC base-image ballast into an opt-in tag | Yes, and irrelevant — we serve natively, no container |

Base: TensorFold **v1.2.7** (`93a2e93e`) with patches `0001`–`0005`. Their `start.sh`,
Docker/NGC machinery and `config.sh` are Linux-only but are recipe plumbing, not engine
work — none of it is needed here.

## PDF — solved, portable, and verified loadable on this box

The engine side is **already in our v1.2.6 fork** (it is upstream code, not Mia's):

- `zig/src/server/pdf.zig` + `pdf_worker.zig`, `--vision-pdf` parsed in `server/cli.zig`.
- **Windows renders in-process**: `pdf.zig:218` — `if (comptime sys.windows) try
  renderInProcess(...) else { worker... }`. The POSIX worker (rlimits, `/proc/self/statm`,
  pipes, signals) is compiled out on Windows (`server/main.zig:57`, `root.zig:90`), so
  Mia's Linux worker path is simply not the path we would run. Upstream designed this.
- `optional_libraries.zig:41` already names `pdfium.dll` on Windows, and `:118` opens it
  with `DynLib.openRestricted` — a Windows-only loader path written for exactly this.
- **No version gate.** `pdf.loadDynLib` only looks up symbols; the `chromium/7725` in the
  install hint is advisory text. Any PDFium exporting the bound symbols works.

Sourcing (the open question in NEXT-STEPS Item 4) is resolved: **pypdfium2 publishes a
`win_arm64` wheel.** Same pin as Mia (5.14.0), Windows flavour:

```
https://files.pythonhosted.org/packages/46/ab/35f2276deeeebb781925e2647dd88a39f8ea1a910104a0dbb28218473502/pypdfium2-5.14.0-py3-none-win_arm64.whl
wheel sha256  eb8aeca157808f323e39ea298cc6d6c8e080c192ea2efb1ca81daa0f0ff4d095
```

Extract `pypdfium2_raw/pdfium.dll` (and the `licenses/` tree beside it, as Mia's
Dockerfile does). A copy of the wheel is kept in `downloads/` (gitignored).

| fact | value |
| --- | --- |
| pdfium.dll size | 6,807,552 bytes |
| pdfium.dll sha256 | `45e414bce25cd698d25ac7e90e91b967c9d0b5b28ca5fad6cf69c5a8ce699f40` |
| PDFium version | pdfium-binaries **156.0.8076** (`pypdfium2_raw/version.json`) |
| PE machine | `0xAA64` — ARM64, confirmed from the header |

**Verified here (2026-11-19, no GPU):**

1. `TENSORFOLD_LIBPDFIUM=<dll> tensorfold-native.exe capabilities --json` →
   `PDFium found:true problem:null` (the DLL opens through `openRestricted`).
   `usable:null` is the same no-probe pattern as grammar — capabilities has no symbol
   test for PDFium, so the next two checks are the real gate.
2. `tests/engine/pdfium-exports.py` (checked in with this review): the DLL exports
   **all 13 required `FPDF_*` symbols** `pdf.zig` binds, plus all 3 optional
   progressive-render ones (`FPDF_RenderPageBitmap_Start/Continue/Close`); 470 exports total.
3. The second dependency, libjpeg-turbo's **encoder** (`tj3Compress8` — PDF pages are
   rendered to JPEG), is already satisfied: our `build-jpeg.bat` turbojpeg.dll exports
   all 5 `JpegFns` symbols including `tj3Compress8`.

**Remaining work is wiring, not building:** put `pdfium.dll` in
`tensorfold/zig-out-v126/native/lib/` (auto-discovered beside the server) or set
`TENSORFOLD_LIBPDFIUM` in the GUI profile's `env`; add `--vision-pdf` to the model's
`extra_args` (needs `--vision`, already there); restart the GUI (it reads the catalog at
startup); then a live PDF request. Caps are the engine's: 32 MiB/document, 16 pages
(`TENSORFOLD_MAX_PDF_PAGES` lowers), pages share the request's image budget; inline data
only (`document.source.url` refused). Accepted shapes: Anthropic `{"type":"document"}`,
OpenAI `file`/`input_file`, and `image_url` with a `data:application/pdf;base64,` URL.
The Serve tier of `verify-engine.ps1` does not cover PDF yet — add a PDF fixture there
when wiring. **PROVEN 2026-11-19 on v1.2.7 + mia 0001-0005 (`zig-out-v127`):** the Serve gate
(extended with `document.pdf` / `corrupt.pdf` fixtures) rendered the page in-process and the tower
read the printed word back — `document.pdf rendered and read [PDFIUM-OK]`, `corrupt.pdf refused
[HTTP 400]`, full gate **0 failed, 0 warned**, 26 s boot. The **stock unspliced** FP4-Local also
loads with `--vision` on this build (0001 acceptance): 77.65 GiB, 55.9 s, every pixel fact read —
the splice is no longer required. `--vision-pdf` is wired into the GUI's vision profile.

## Video — the glue transfers, the FFmpeg build does not (yet)

What Mia's `0005` actually is: chai-md's TensorFold #90 rebased onto v1.2.7 — three
files, all portable Zig, no OS-specific code:

- `families/flashnext/cuda_images.zig`: declares `video = core.qwen_vl.video`,
  `video_time_first = true`, `video_ids`, `prepareVideo`, video error messages.
- `native/cuda_vision_offer.zig`: passes `time_first` into the video offer.
- `vision/qwen_cuda_media.zig`: `Limits` gains `video_tokens/max_videos/max_frames`;
  the placeholder walk accepts `<|video_pad|>` groups beside `<|image_pad|>` instead of
  returning `QwenVideoUnsupported`.

**Why we need it:** our registered FlashNext family is the *lanes* path
(`families/flashnext/cuda_launch.zig:41` → `cuda_lanes.zig` → `cuda_images.zig`), and in
v1.2.6 that path refuses video at `vision/qwen_cuda_media.zig:67`
(`error.QwenVideoUnsupported`). The video-capable `native/flashnext_images.zig` in our
tree is a *different* host (used by `flashnext_host.zig` etc.) that the FlashNext registry
entry does not use — do not be fooled by its presence. v1.2.7 unified these; `0005` is
the wiring our path lacks.

**Apply status on our v1.2.6 (measured with `git apply --check` in a throwaway worktree):**

- `0005` alone: fails on `cuda_images.zig` and `qwen_cuda_media.zig`.
- After `0002`: `qwen_cuda_media.zig` applies; **one hunk left** — `cuda_images.zig:71`,
  because v1.2.7's `state()` carries a `.prep8` field v1.2.6 lacks. A context-only
  rebase, not a semantic one.
- The server side (parts, sampler `core/qwen_vl/video.zig`, `--vision-video-tokens`,
  `--vision-max-videos`) is already in our tree, as is the Windows-aware `tfvideo.dll`
  loader name.

**The Linux-only part is the FFmpeg build**, exactly as NEXT-STEPS Item 3 documented:
Mia runs TensorFold's `tools/zig/build_ffmpeg.sh` (bash + configure, static `.a` prefix)
inside their image. Their commit adds no Windows route. Ours remains:

- (a) quick: BtbN's `winarm64` **shared** 9.0 zip (has `include/` + `av*.lib` import
  libraries) + a Windows branch in `zig/build/video.zig` linking those and dropping `-lm`,
  shipping the four FFmpeg DLLs beside `tfvideo.dll`;
- (b) faithful: FFmpeg 9.0.2 from source for aarch64-windows (llvm-mingw / MSYS2
  clangarm64) with Mia's now-published decoder set — H.264/HEVC/VP8/VP9/MPEG-4 decoders,
  MP4/MOV + Matroska/WebM demuxers, `--disable-network --disable-programs` — which
  matches `build_ffmpeg.sh` and keeps pixel parity with the Linux receipts.

Serve-side settings Mia uses (defaults worth copying): `--vision-max-videos 4`,
`--vision-video-tokens 16384` (`TENSORFOLD_VIDEO_TOKENS`), 2 fps sampling, two frames a
tower group, ≤256 frames/clip; video groups share the images' 50-group / 16,384-row
budgets (~50 s of footage a request at defaults). Needs `--vision`.

**Expectation setting:** Mia's own README says `0005` compiles and `zig build video`
builds, but *no server has served a video from it* — not even on their Spark. A working
Windows video path would be the first live one anywhere on this engine; budget testing
accordingly, and keep the negative cases (too-short/too-large/unreadable clips → 400).

## The other patches — apply status on our v1.2.6 and what each buys

Measured with `git apply --check` against bare `6c6615bd0` (and the cascade above):

| patch | size | applies to v1.2.6? | what it buys us |
| --- | --- | --- | --- |
| `0001` vision-nvidia-fp4-tower | 27 KB | **clean** | ModelOpt MXFP8/NVFP4 vision linears dequantised to bf16 at load (new `vision/qwen_cuda_dequant.zig` + quant host tests). **This is NEXT-STEPS "Route B"** — the stock FP4-Local tower loads directly, no splice. Build + run the new host tests + Serve gate before trusting it. |
| `0002` vision-image-tokens-16384 | 2.4 KB | **clean** | Per-request image row budget 4,096 → 16,384 (per image still ≤4,096). Removes the `BadImageLimits` load-abort for multi-image requests; `--vision-image-tokens 16384` becomes legal. |
| `0003` kv-cache-fp8 | 125 KB | **clean** | FlashNext CUDA `--kv-cache fp8`: e4m3 codes + power-of-two scale per position/KV-head, 1,056 B/position/layer vs 2,048 → ~17.5 KiB/token vs 30. Indexer keys, pooled blocks, DeltaNet states stay bf16. Mia measures ~98.8% top-1 agreement with bf16. Constraints: one rank, contiguous caches, not with `--tp`/`--slide`/`TF_FLASHNEXT_KV_PAGES`. **The big one for this box:** 262,144×5 streams becomes budgetable beside 72.7 GiB of weights on a 96 GiB framebuffer. Lossy — A/B reply hashes and an exactness check before adopting. |
| `0004` prompt-mxfp8-tile | 35 KB | no (`qmmf.cu:243` context moved) | MXFP8 prompt tile; Mia's v1.2.7 prefill 2,303/2,443/2,293 tok/s at 4k/31k/126k, 199,730-token prompt in 95.7 s. Needs the v1.2.7 re-port. |
| `0005` flashnext-cuda-video | 6.8 KB | one-hunk rebase after `0002` | Video wiring — see above. |

v1.2.7 itself (upstream release read): mostly Metal resume wins, GLM TP=2 and LightOnOCR
— little for our FlashNext CUDA serve beyond fixes worth having: damaged-JPEG refusal
(the "every pixel was written" check), a failed round failing only its own streams, and
disk-restore fallback to RAM state. The re-port is small per BENCH-1.2.6.md's method
(two structural conflicts: `build/cuda.zig` bolt_build re-add, family registry move).

## Suggested order

1. **PDF wiring** — zero engine changes, every dependency verified present. DLL install +
   `--vision-pdf` + a PDF fixture in the Serve gate. Cheapest win on the board.
2. **Cherry-pick `0001` + `0002` onto `win-arm64/v1.2.6`** — clean applies, host-testable
   (`qwen_cuda_weights_quant_test.zig` is new in 0001; run the codec-diagnostics and
   pixel-parity gates too). Retires the splice for future checkpoints and unlocks 16k
   multi-image requests. Engine work in the submodule: follow `tensorfold/AGENTS.md` ATC
   (claim/`atc who`/PR pre-flight) if any of it goes upstream; our fork branch is our port.
3. **Video** — FFmpeg winarm64 build (route (a) to decode, (b) for parity) + the one-hunk
   `0005` rebase + flags. First live video on this engine anywhere; test hard.
4. **`0003` FP8 KV A/B** — clean apply, but lossy: warm-cache A/B per BENCH-1.2.6.md,
   reply-hash equality on greedy, and a long-context needle before it becomes a default.
5. **v1.2.7 re-port** when `0004`'s prefill tile and the upstream fixes are wanted.

## Reproducing the checks

```bash
# wheel -> dll (copy kept in downloads/)
python -c "import zipfile; z=zipfile.ZipFile('downloads/pypdfium2-5.14.0-py3-none-win_arm64.whl'); open('pdfium.dll','wb').write(z.read('pypdfium2_raw/pdfium.dll'))"
# engine opens it (no GPU, ~2 s)
TENSORFOLD_LIBPDFIUM=<path>/pdfium.dll tensorfold/zig-out-v126/native/bin/tensorfold-native.exe capabilities --json
# symbol gate against pdf.zig's exact bindings
python tests/engine/pdfium-exports.py <path>/pdfium.dll tensorfold/zig-out-v126/native/lib/turbojpeg.dll
# patch apply status (throwaway worktree, never the serving checkout)
git -C tensorfold worktree add --detach <scratch>/tf-cascade HEAD
git -C <scratch>/tf-cascade apply --check <mia>/patches/000N-*.patch
```

Mia's repo snapshot used: main tarball at `b956dba8`, patches `0001`–`0005`,
`scripts/config.sh` pins (pypdfium2 5.14.0, FFmpeg 9.0.2 sha256
`8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`, TF_REF
`93a2e93ecebff8aa52b88e58c5dd222516e69c5f`).
