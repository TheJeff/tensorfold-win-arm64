# Upstream TensorFold after our pin: 1.2.4 / 1.2.5 / 1.2.6

Checked 2026-11-10 20:54 UTC against `origin/main` = `22fb6014b` (upstream `ashhart/TensorFold`).

| | |
| --- | --- |
| Our engine pin | `tensorfold/` submodule `467e654cd`, tag `v1.2.3-4` (branch `win-arm64/v1.2.3`) |
| Upstream now | `v1.2.6` (released 2026-11-10 12:51Z) + 28 commits on `main`; **1406 commits ahead of our base** |
| New tags since us | `v1.2.4` (11-07), `v1.2.5` (11-08), `v1.2.6` (11-10) |
| Prebuilt for Windows? | **No.** Release assets are `linux-aarch64`, `linux-x86_64`, `macos-arm64` (+ a darwin-arm64-metal engine) only. `docs/WINDOWS.md`: "Windows is supported from source only", and it names `aarch64-windows` / `sm_121` as a *PR-reported* receipt "not reproduced on the maintained tree". |

So every speed number below is measured upstream on a **DGX Spark GB10** — the same GB10 silicon at
`sm_121` that we run — but on Linux, and never with our Windows-ARM64 build.

> **Outcome (2026-11-11):** ported and measured. The tree built clean on the first attempt
> (`win-arm64/v1.2.6`, `build-bolt-126.bat`), Bolt still serves through `libbolt.dll`, and the A/B
> came out as this assessment predicted: prefill and single-stream decode level, **8 concurrent
> streams +3.7%**, replies identical. Receipt: `BENCH-1.2.6.md`.

## Verdict in one line

The CUDA claims are real for `sm_121` and are explicitly GB10-measured (one gate is literally
`sm_12x`, i.e. 120/121), but for **what we actually serve** — Qwen3.8-Flash-Next FP4 and Nemotron 3.5
Bolt via `libbolt` — the gains are single-digit percent on prefill and multi-stream decode, plus a
19% first-token win on short new prompts. The big headlines on the release pages (23% prompt fill,
32% decode, 105 s → 25.8 s follow-ups) belong to other models or to **two** GB10s.

## Claim by claim, against our box

Upstream publishes a "release read" per tag: the same bench from alternating fresh servers, so it
measures the whole release, not one PR. That is the number to trust for "what would I get".

| Upstream claim | Where | Applies here? |
| --- | --- | --- |
| Many agents: follow-up median first token 105 s → 25.8 s at 16 agents, decode 33.6 → 100.8 tok/s (GB10) | 1.2.6 #2699 | **Not on our models.** Measured on Qwen3.8-27B + DFlash2. The same release read says Flash Next on a GB10 is *level* at 8-16 agents. Would apply if we served Qwen3.8-27B dense. |
| Qwen3.6-35B-A3B NVFP4 MoE: cold prompts 9.9-14.1% faster, 2K-64K (GB10) | 1.2.6 #2537 | Not now — we serve no `qwen3_5_moe` NVFP4 checkpoint. The 257-row crossover is tuned for GB10, so it would land if we add one. |
| GLM-5.3-Flash TP=2: prompts 13-23% faster, code decode 32% faster (two GB10s) | 1.2.6 #2257 | No — GLM isn't in `models/`, and it needs two GPUs. |
| DSpine-b16 drafter for Qwen3.8-27B: agent-shaped decode 2.4-19.8% faster, chat/code 10-19% slower (GB10) | 1.2.6 #2633 | No — needs that checkpoint + drafter folder. |
| **Flash Next on CUDA, `--parallel 1`: prompts 15-23% faster, +3.2 GiB** | 1.2.4 #2246 | **Yes**, but only at one lane. Our `qwen4_exp` profile runs 2 lanes (`gui/models.json`), so we'd get a partial share, or take the win and lose a lane. |
| **Flash Next on CUDA: 8 streams decode 3-6% faster** (one launch for a shared round's DeltaNet) | 1.2.4 #1942 | **Yes** — matches how we serve Flash Next. |
| **Flash Next on CUDA: a new short prompt's first token 19% sooner** (prompt-cache mark kept inside the pass) | 1.2.4 #1866 | **Yes** — best single agent-facing win for our box. `TF_FLASHNEXT_KEEP_INPASS=0` reverts it. |
| Flash Next NP4: BF16 prompt projections 128×128 tile on **`sm_12x`**: 3.7-4.4% less cold-prompt time + 0.6-0.8% | 1.2.5 #1846/#1848 | **Yes** — our checkpoint is the FP4 one these were measured on. Note the 1.2.5 *release read* on the MLX 4-bit Flash Next was level, so the tile is checkpoint-dependent (`TF_FLASHNEXT_PROMPT_BF16=0` off). |
| Gemma 4 / Qwen 3.5 cold load 28-31% faster (direct reads, `TF_LOAD_DIRECT=0` off) | 1.2.4 #2282 | Marginal: our 95 GiB FP4 pack spends the time in packing, not page-cache reads. Spark 2.5/Dory load wins (5.03 → 2.53 s) are load-only. |
| Nemotron 3.5 Lightning on GB10 | 1.2.4/1.2.5/1.2.6 reads | **Level** in all three release reads (1.2.4: decode after a 32K prompt 2.0-2.6% faster only). |
| Nemotron: skip the last layers of prompt chunks nothing reads (up to 3.9% sooner cold prompts) | 1.2.5 #2432 | **No for Bolt** — Bolt's forward pass is `bolt-recipe/engine/bolt_*.cu` (`libbolt.dll`), a lane backend; upstream's Nemotron CUDA kernels never run for it. |
| Router/sampling refactors "same machine code on sm_80…sm_121" | 1.2.5/1.2.6 #2536/#2556 | Neutral by construction: no speed change, no risk. |
| Prompt-state identity keyed by resolved arithmetic (persisted states) | 1.2.6 #2287 | Behavioural: every kept state starts cold once after the upgrade. |
| `--prompt-cache-gib` default scales with free room on unified-memory CUDA (8 GiB discrete / 16 GiB Flash Next batch host) | 1.2.6 #2699 | **Watch the memory**: our FP4 pack packs to 72.7 GiB of a 96 GiB framebuffer; a larger default prompt budget eats into the same headroom. Budget explicitly. |

Metal-only (M3/M5 Ultra), HIP/ROCm-only (`gfx1151`, R9700), XPU-only (Arc B70) and TP=2/4 entries are
excluded; there are no x86-only claims that would skip an ARM host.

## What that means in practice, per server

- **Qwen3.8 Flash Next FP4, port 8083** (the one on `--parallel 2`): expect roughly 4-5% off cold
  prefill (tiles), 3-6% more decode at high stream counts, and ~19% sooner first token on short new
  prompts — i.e. the agent-loop feel improves more than tok/s does. Take `--parallel 1` and the
  prompt win goes to 15-23% for +3.2 GiB.
- **Nemotron 3.5 Bolt 74B-A9B, port 8082**: essentially nothing. Its decode is libbolt's kernels; the
  host-side server improvements in 1.2.4-1.2.6 are settings, refusals and prompt-state keys.
- **Qwen3.8-27B / Qwen3.6-35B-A3B**, if we ever add one: those are where the loud numbers live
  (105 s → 25.8 s follow-ups, 14% prefill).

## Cost to get it: re-port v1.2.3 → v1.2.6

Measured, not guessed: `git diff v1.2.3..HEAD` (1020 lines) applied with `git apply --check` onto a
clean `v1.2.6` tree.

```
Checking patch zig/build/bolt.zig...                     OK
Checking patch zig/build/cuda.zig...                     FAIL  (bolt step: file reworked, -167 lines)
Checking patch zig/src/cli/hub.zig...                    FAIL  (title table + modelType: upstream added families)
Checking patch zig/src/families/nemotron/bolt_api.zig... OK
Checking patch zig/src/families/nemotron/bolt_native.zig.OK
Checking patch zig/src/families/nemotron/cuda.zig...     OK
Checking patch zig/src/native/cuda.zig...                FAIL  (registry moved to native/cuda_families.zig)
Checking patch zig/src/server/main.zig...                OK  (offset 27)
Checking patch zig/tests/bolt_lib_compile.zig...         OK
```

8 of 11 hunks land unchanged. The three that don't are one-line-ish re-applications, and the lane
vtable our `bolt_native.zig` implements is **byte-identical** between v1.2.3 and v1.2.6
(`zig/src/core/lanes/backend.zig` has no diff), so the 580-line Bolt backend needs no API work this
time — unlike the v1.1.6 → 1.2.3 move, where `prefill_step` grew a `max_rows` budget.

Unknowns a build has to settle (no prebuilt to fall back on):

1. Nothing proves upstream `main`/1.2.6 still compiles `aarch64-windows` + CUDA 13.4 `sm_121`; the
   last proof on this box is v1.2.3. Expect the usual break classes (MSVC-ARM64 intrinsics guards,
   clang `/O2` SEH epilogue TUs, host-compiler surprises) in files we never touched.
2. CUDA contract receipts are keyed by nvcc version (`sm121 refreshed with 13.0.88`; later compilers
   are `later_pending`), so `tf-cuda-test` won't assert our 13.4 images. That is a test-coverage
   gap, not a build gate.
3. Windows still has no image/video path (`turbojpeg`/`tfvideo`), and 1.2.6 adds
   `POST /v1/images/generations` — irrelevant here, but it keeps the "picture reader" gap in place.
4. `libbolt` is pinned to the recipe's `bolt-recipe/` submodule (`6b064a31`); re-check it against the
   new lane/round loop before promising its numbers carry over.

## Reproduce this check

```bash
cd C:/Projects/tensorfold-win-arm64/tensorfold
git fetch origin --tags --prune
git rev-list --left-right --count HEAD...origin/main        # 4   1406
git show origin/main:CHANGELOG.md | awk '/^## 1\.2\.3$/{exit} {print}'
curl -sS https://api.github.com/repos/ashhart/TensorFold/releases/tags/v1.2.6
git diff v1.2.3..HEAD > fork.patch && git apply --check --verbose fork.patch   # run inside a v1.2.6 tree
```

## If we do it

Branch `win-arm64/v1.2.6` off the tag, re-apply the three failing hunks (bolt step in
`zig/build/cuda.zig`, the title/`modelType` patch in `cli/hub.zig`, `nemotron.bolt` in
`native/cuda_families.zig`), `zig build native bolt install -Dsm=121 -Dstrip=true`, then bench
`Flash Next FP4` cold on 2/8/32K plus 8-stream decode against the 1.2.3 numbers in `README.md`. Only
the Flash Next panel is expected to move; a flat Bolt panel is the correct result, not a failed port.
