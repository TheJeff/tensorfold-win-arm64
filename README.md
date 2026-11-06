# Nemotron 3.5 Bolt on Windows 11 ARM64 (RTX Spark N1X) — native, no WSL, no Docker

Built, served and benchmarked on 2026-11-01 from
`MiaAI-Lab/Nemotron-3.5-Bolt-TensorFold-DGX-Spark` @ `646c947` (PR #7 merged),
on TensorFold `eea9dc9c` (v1.1.6) + `patches/0002-register-bolt.patch`.

This is the receipt for that path on this machine. It is the first build of the Bolt recipe
outside Docker/Linux; nothing in it needs WSL.

The work now lives in the fork [TheJeff/TensorFold](https://github.com/TheJeff/TensorFold), whose purpose
is to advance TensorFold on this hardware: `main` there is this v1.1.6 baseline, and `win-arm64/v1.2.3`
re-ports it onto upstream v1.2.3 (it builds and serves on this machine). That fork's `README.md` lists
what differs from upstream and `FORK.md` lists the branches and pins.

## Machine

- NVIDIA RTX Spark N1X, driver 617.42, **98,304 MiB framebuffer visible to CUDA** (WDDM pool)
- Windows 11 Pro ARM64 (10.0.28000.3231), Balanced power plan, AC power
- VS Build Tools 2022 17.14.42 with `Hostarm64` tools, CUDA 13.4.59 `nvcc`, Zig 0.17.0 aarch64-windows

## Layout

```
tensorfold/                 submodule → TheJeff/TensorFold, branch win-arm64/v1.2.3
                            pinned at 467e654cd (v1.2.3 + 4: the N1X port commits)
bolt-recipe/                submodule → MiaAI-Lab's DGX Spark recipe (engine/, patches/, contract/)
xgrammar/                   submodule → mlc-ai/xgrammar, pinned at 9778737 (v0.2.8) for tfgrammar.dll
local-patches/              our fixes to the tree beyond the recipe: 0001-grammar-dll-windows.patch
gui/                        Win32 Zig control surface (load/unload + telemetry)
models/Nemotron-3.5-Bolt-74B-A9B-24GB     23 GiB, 90 shards, revision a326822a      (not in git)
models/Nemotron-3.5-Bolt-LiLiCorr         918 MiB drafter, revision 4c6a5613        (not in git)
models/Qwen3.8-Flash-Next-FP4-Local       95.24 GiB, 21 shards                     (not in git)
tools/zig-aarch64-windows-0.17.0/         Zig 0.17.0, sha256 0a59d91f…26            (not in git)
build-bolt.bat, build-grammar.bat, serve-bolt.bat, serve-qwen38.bat
logs/                       build, serve and bench output                          (not in git)
```

Clone with `git clone --recurse-submodules`, then drop the Zig 0.17 aarch64-windows
toolchain into `tools/` (see `.gitignore`: checkpoints, the toolchain, downloads and
build output stay out of the repo).

## Artifacts

| File | Bytes | sha256 |
| --- | ---: | --- |
| `tensorfold/zig-out/native/lib/bolt.dll` | 6,206,464 | `fad5dc8532f6e1ff339c3ede5dd6ca5d2be3017e3d8b8a4e538f39666c043b16` |
| `tensorfold/zig-out/native/lib/tfgrammar.dll` | 2,501,632 | `4f677b740d1514530415cc376539a0515cb30033287fd9a0bde98166d5720309` |
| `tensorfold/zig-out/native/bin/tensorfold-native.exe` | 35,873,792 | `9ee2f6161b9cd868bae241935b439c3405d5d45fcc76ec7c3766deadb8da0d60` |

`tensorfold-native info` on the snapshot: `family: Nemotron 3.5 Bolt (nemotron_h_puzzle)`,
`modelopt mixed precision (IQ2_XXS, Q8_0, W4A16_NVFP4)`, 22.46 GiB.
`scripts/ckptcheck.py` accepts it: `nemotron_h_puzzle, 88 layers (40 Mamba, 40 MoE, 8 attention),
top-9, latent 1024, IQ2_XXS 27728, NVFP4 80, Q8_0 113, 90 shards`.

## Build (verified commands, ~7 min)

1. Zig 0.17.0 aarch64-windows from `https://ziglang.org/download/0.17.0/zig-aarch64-windows-0.17.0.zip`
   (sha256 `0a59d91fa1cb40cf068e9b0954434ce973500c7a2ea749f1e01af62cdab52d26`).
2. `git clone` the recipe **with `core.autocrlf false`**. Without it the checkout turns
   `patches/0002` into CRLF and `git apply` fails on TensorFold's LF files (`patch does not apply`
   on `zig/build/cuda.zig`, `zig/src/cli/hub.zig`, `zig/src/families/nemotron/cuda.zig`,
   `zig/src/native/cuda.zig`, `zig/src/server/main.zig`). Fixing it is
   `git config core.autocrlf false && rm patches/0002-register-bolt.patch && git checkout -- patches/`.
3. `git init tensorfold`, `git config core.autocrlf false`, fetch `eea9dc9c`, detach, then
   `git apply C:/Projects/tensorfold-win-arm64/bolt-recipe/patches/0002-register-bolt.patch`
   and copy `bolt_native.zig` + `bolt_api.zig` into `zig/src/families/nemotron/`.
4. From `vcvarsall.bat arm64`: `zig build native bolt install -Dsm=121 -Dstrip=true
   -Dnvcc=<CUDA 13.4>\bin\nvcc.exe -Dbolt-src=C:\Projects\tensorfold-win-arm64\bolt-recipe\engine`.
   See `build-bolt.bat`.
5. Structured output: `git clone --branch v0.2.8 --recurse-submodules https://github.com/mlc-ai/xgrammar`,
   then `zig build grammar -Dxgrammar=<clone>` (`build-grammar.bat`), **plus**
   `git apply local-patches/0001-grammar-dll-windows.patch` and a rebuild — without the patch the
   DLL builds but the server never finds it (see the section below).

Hermes/MSYS traps hit on the way: native `git` cannot read `/c/...` paths here (path conversion is
off) — pass `C:/...`; `cmd //c foo.bat` silently opened an interactive prompt instead of running the
bat, so call `./foo.bat` directly from bash.

## Serve

`serve-bolt.bat` (defaults mirror `docs/windows.md`: 4 streams, 131k, 4 GiB cache, port 8082).
`PARALLEL` / `CONTEXT` / `PROMPT_CACHE_GIB` / `PORT` can be set in the environment.

```
BOLT_DRAFT=<models\Nemotron-3.5-Bolt-LiLiCorr> BOLT_KV=bf16 BOLT_KV_PIN=0 BOLT_SSM_LAZY=1
BOLT_DRAFT_Q8=1 BOLT_NV4_FP4=1
tensorfold-native.exe serve <snapshot> --name Nemotron-3.5-Bolt --host 127.0.0.1 --port 8082
  --parallel N --context N --prompt-cache-gib N
```

Load: **26–27 s**. With the recipe's own defaults (`PARALLEL=16`, `CONTEXT=262144`, 8 GiB prompt
cache) the GPU held **34.7 GB** of 98,304 MiB and the server reported 61.8 GiB left after its
11.0 GiB reserve — i.e. the full Spark-shaped configuration fits this laptop without downsizing.
(The PR's 64 GB machine had to drop to 4 streams / 131k / 4 GiB.)

## Control GUI (Zig, native)

`gui/` is a Win32 control surface written in Zig 0.17 — one binary, no Electron, WebView,
Node or runtime DLLs. It scans `models/`, reads each checkpoint's family/quant/shard
metadata, pairs drafters, and loads or unloads a checkpoint by driving
`tensorfold-native serve` with a per-model profile from `gui/models.json` (port, lanes,
context, prompt cache, env vars, extra args). While a server runs it polls
`/health`, `/stats` and `/metrics` and draws decode/prefill throughput, a five-minute
chart, live counters, MTP acceptance, KV occupancy, host RAM plus the serve process's
working set, and the real GPU framebuffer via NVML — it can also attach to a server it
did not start (`--attach PORT`). The binary carries the app mark (violet orb) as its
window, taskbar and Explorer icon, rendered from `gui/src/make_icon.zig` into
`gui/assets/tensorfold.ico` and embedded through `gui/assets/tensorfold.rc`.

```
gui\build-gui.bat
gui\zig-out\bin\tensorfold-gui.exe            (--attach PORT | --load N | --shot out.bmp)
```

Verified on this machine: load 26 s → serving on 8082, NVML 30.9/96.0 GiB resident,
a test prompt produced 96 tokens at 48 % MTP acceptance, unload returned the GPU to
3.2 GiB. Flags, file map and limits: `gui/README.md`; screenshot: `gui/docs/gui.png`.

## Qwen3.8 Flash-Next on this box (qwen4_exp)

MiaAI-Lab's [Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)
recipe targets Linux/Docker on a 121 GiB Spark and pins TensorFold v1.1.4 plus a patch series.
On this machine it needs no `.cu` DLL port like Bolt did: TensorFold 1.2.3 already registers
`flashnext` in the native CUDA registry (`zig/src/native/cuda.zig`), lists `qwen4_exp` in
`capabilities --json`, reads the recipe's `TF_FLASHNEXT_*` knobs, and `info` recognises NVIDIA's
checkpoint as `modelopt mixed precision (MXFP8, NVFP4, W4A16_NVFP4)`. The work was data and
settings, not kernels.

Verified 2026-11-05 with `nvidia/Qwen3.8-Flash-Next-FP4-Local` (95.24 GiB on disk, 21 shards):

```
serve-qwen38.bat        (parallel 2, 262k, bf16 KV, pread n-gram reader, 4 GiB reserve)
```

- `tensorfold-native info`: `family: Qwen3.8 Flash Next (qwen4_exp)`, `weights: 95.24 GiB`.
- Serve with `--parallel 1 --context 32768 --kv-cache` omitted: **loaded in 41.0 s**, engine
  reports **72.71 GiB** resident, NVML shows 78.2 GiB of the 96 GiB framebuffer.
- Chat completion returned 42 tokens (MTP 58 % acceptance); a 110-token reply took 3.57 s
  (~30 tok/s single stream, 25-token prompt).
- **`--kv-cache fp8` is refused**: "this CUDA family keeps bf16 caches". The recipe's fp8 KV
  patch is not in the Windows path, so a full 262,144-token window costs ~10.6 GiB and two
  streams fit where the recipe runs five.
- Text only: image/video decode still needs `turbojpeg.dll`/webp/`tfvideo.dll`, which this tree
  does not build on Windows (`NEXT-STEPS.md`); the vision tower itself loads.

## Measured

`tensorfold/tools/bench_concurrent.py`, 512-token replies, thinking off, drafts on, **one run each**
(no medians), Balanced plan. 4-stream cells ran on the 4-stream/131k server config; 8- and 16-stream
cells on the 16-stream/262k config.

| streams | prompt | sampling | aggregate tok/s | each stream | TTFT max |
| ---: | --- | --- | ---: | ---: | ---: |
| 1 | chat (prose) | greedy | 88.7 | 88.7 | 0.07 s |
| 1 | chat (prose) | sampled | 86.9 | 86.9 | 0.05 s |
| 1 | code | greedy | 145.4 | 145.4 | 0.07 s |
| 1 | code | sampled | 129.8 | 129.8 | 0.07 s |
| 4 | chat | greedy | 240.9 | 60.6 | 0.17 s |
| 4 | chat | sampled | 179.9 | 47.1 | 0.17 s |
| 4 | code | greedy | 390.9 | 99.2 | 0.20 s |
| 4 | code | sampled | 204.6 | 68.2 | 0.20 s |
| 8 | chat | greedy | 308.6 | 39.0 | 0.36 s |
| 8 | chat | sampled | 215.0 | 28.2 | 0.37 s |
| 8 | code | greedy | 413.4 | 52.6 | 0.43 s |
| 8 | code | sampled | 229.5 | 38.0 | 0.42 s |
| 16 | chat | greedy | 343.7 | 21.8 | 0.71 s |
| 16 | chat | sampled | 254.3 | 17.1 | 0.70 s |
| 16 | code | greedy | 446.2 | 28.8 | 1.02 s |
| 16 | code | sampled | 251.1 | 18.3 | 0.86 s |

Cold prefill (fresh random-word prompt, `max_tokens 1`, prompt cache cannot help):

| prompt tokens | prefill tok/s | prefill time |
| ---: | ---: | ---: |
| 23,814 | 2,463 | 9.67 s |
| 44,171 | 2,313 | 19.09 s |
| 122,447 | 1,601 | 76.48 s |

Correctness (`bench_concurrent.py --alone --serial`, greedy, 4 streams, 128 tokens):
concurrent replies equal solo ones **4/4**, and drafted replies equal `"draft": false` **1/1**.
Speculative acceptance on a short smoke request: 30/73 drafts, 2.88 tokens a round.

### Against the PR's own N1X numbers

The PR measured a 64 GB N1X on battery: 59.9 prose greedy / 100.1 code greedy / 47.6 prose sampled
alone, 117.6 aggregate at 4 streams, 1,508 tok/s on a 24k prompt. This machine, on AC with the full
96 GiB framebuffer: 88.7 / 145.4 / 86.9 alone, 240.9 aggregate at 4 streams, 2,463 tok/s at 24k.
Not an apples-to-apples delta — different memory partition, power source and driver (617.42 here,
621.01 there) — but it puts the Windows path at or above the Linux/Docker numbers published for a
DGX Spark on the same cells (73.8 prose / 137.4 code greedy, 330 aggregate at 16 streams).

## Structured output on Windows — two upstream gaps, both patched locally

`zig build grammar -Dxgrammar=<clone>` builds `tfgrammar.dll` fine, but TensorFold 1.1.6 will not
find it on Windows as shipped:

1. `zig/src/platform/optional_libraries.zig` gives `tfgrammar` only `.dylib`/`.so` names (the
   `.video`/`.jpeg` entries right above it *do* have Windows branches — this one was missed).
2. `zig/src/core/lanes/grammar.zig` hard-codes `pub const library = "libtfgrammar.so"`, so the
   loader looks for `../lib/libtfgrammar.so`, `./libtfgrammar.so` and a bare `libtfgrammar.so`,
   never `tfgrammar.dll`.

Both fixes are in `local-patches/0001-grammar-dll-windows.patch` (already applied in this tree;
re-apply with `git apply` after a fresh checkout). Verified after rebuild:

- `response_format` `json_schema` (strict, `additionalProperties: false`) → valid JSON that parses
  and carries every required key.
- `tool_choice: "required"` with one function → `tool_calls` with
  `{"name":"get_weather","arguments":"{\"city\":\"Osaka\",\"unit\":\"c\"}"}`, `finish_reason:
  tool_calls`.

## What this path does not have

- **Images and video**: the RADIO tower loads, but `libturbojpeg` and `libtfvideo` are not built on
  Windows, so this runbook serves text only. Loader names for `turbojpeg.dll`/`tfvideo.dll` already
  exist in `optional_libraries.zig` (webp's does not); what is missing is the libraries themselves
  and, for video, a `zig build video` that links Windows import libraries instead of static `.a`.
  Full breakdown, upstream watch list and work plan: `NEXT-STEPS.md`.
- `start.sh` / `stop.sh` / the Docker image are Linux-side; on Windows you drive
  `tensorfold-native.exe` directly (that is what `serve-bolt.bat` does).
- The Linux build was not rebuilt with these changes (upstream's claim, not verified here).

## Other models: what would it take

Nothing in this folder is Bolt-specific except `bolt.dll` and the patch that registers
`nemotron_h_puzzle`. Two tiers:

1. **Already native on Windows, no work.** TensorFold's own Windows CUDA port serves
   Nemotron 3.5 Lightning 30B-A3B and the Qwen3.5/3.8 hybrids (MLX-4bit and mixed-width
   checkpoints, `--drafter` DFlash2). Build `zig build native install -Dsm=121` and serve them;
   `libtfgrammar`/`tfgrammar.dll` is the same structured-output gap.
2. **Needs a port, same shape as this one.** For a family whose forward pass has no Windows-capable
   CUDA kernels — Flash-Next, an EXL3 `qwen3_5_moe`, anything else — the recipe pattern is:
   a `.cu` forward-pass library built as a DLL (with a `bolt.def`-style export list), a Zig lane
   backend that binds it (`bolt_api.zig`), a patch that registers the family in the CUDA host, and
   the portability shims (`bolt_port.h` for mmap/fadvise, `sys` layer for clock/env). The porting
   work is mechanical; the kernels are the real cost. EXL3 additionally has no Zig loader at all —
   that format currently lives only in TensorFold's Python engine.

## Next steps

- Pictures/video: build `turbojpeg.dll` (libjpeg-turbo 3.1.4.1) and `tfvideo.dll` (FFmpeg 9.0.2)
  if images matter; `optional_libraries.zig` already knows the Windows names.
- Long-context check at the full 262,144 window, and a prompt-cache hit-rate test with a repeated
  system prompt (the recipe claims prefix reuse restores Mamba state + attention rows).
- An agentic smoke test now that `tool_choice: required` works end to end (Hermes against
  `http://127.0.0.1:8082/v1`).
- Offer the two grammar-name fixes upstream as a PR against TensorFold; they are two one-line
  changes and block structured output for every Windows user.
- `serve-bolt.bat` is the launcher; add a `stop` wrapper if this becomes the daily driver.
