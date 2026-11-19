# Upstream TensorFold 1.2.7 — the re-port map

Checked 2026-11-19 against `origin` = `ashhart/TensorFold`. Everything below is **measured**
(apply-checks in a throwaway worktree at the tag), not estimated — except where marked.

| | |
| --- | --- |
| Target | tag `v1.2.7` → commit **`93a2e93ecebff8aa52b88e58c5dd222516e69c5f`** (annotated tag; the commit is exactly Mia's `TF_REF`) |
| Our base | `../../tensorfold/` submodule `6c6615bd0`, branch `win-arm64/v1.2.6` = tag `v1.2.6` + 2 commits |
| Fork delta | `git diff v1.2.6..HEAD` — **12 files, +905/−4** (Bolt lane + build step + registry + docs) |
| Upstream churn | 188 commits, 292 files, +11,895/−1,245 between the tags |
| Prebuilt for Windows? | **No.** v1.2.7 assets: linux-aarch64, linux-x86_64, macos-arm64 only. Source build as always. |
| Toolchain | Zig **0.17.0** aarch64-windows (Mia builds v1.2.7 with the same), CUDA 13.4.59, MSVC arm64 — unchanged from the 1.2.6 build |

## Verdict in one line

The re-port itself is **nearly free — zero conflicts measured** — and upstream 1.2.7 brings almost
no speed to what we serve; the prize is that it is the exact base Mia's five patches are written
against, and **all five apply cleanly on top of our fork delta** (measured). That stack is where
the wins are: FP8 KV (context/concurrency), quantised-tower loading (no more splice), 16k image
budgets, the MXFP8 prefill tile, and the video wiring. Plus a handful of upstream robustness fixes.

## What 1.2.7 itself brings, against our box

The release read's loud numbers are Metal (M3/M5 Ultra), HIP (gfx1151, R9700), GLM TP=2 on **two**
GB10s, Qwen3.8-27B dense + DSpine, and LightOnOCR-3 — none of which we serve. For Flash Next FP4 on
one GB10 at `sm_121` and Bolt via `libbolt.dll`, expect a **flat speed panel from the base bump**;
that is the correct result, not a failed port (same reading as 1.2.6).

| Upstream item | Applies here? |
| --- | --- |
| Damaged JPEG refused as undecodable (#2759) | **Yes** — strengthens the vision negative path our Serve gate already tests |
| A failed round fails only its own streams; finished streams deliver | **Yes** — multi-stream robustness |
| Flash Next CUDA: non-finite draft row → `ProposalNonfinite` (was `ProposalPaddingPick`), one log line naming stream + draft length (#2753) | **Yes** — error-name change; note for any log parsers |
| Prompt cache: two failed disk restores resume from RAM state, `cached_tokens` reports that position (#2694) | **Yes** — agentic long-chat resilience |
| `tie_word_embeddings` unset → loads untied; conflicting root/`text_config` refused `BadTiedHead` (#2714) | **Check at load** — our FP4-Local config should set it explicitly; a refusal here is a config read, not a port bug |
| Responses API WebSocket mode (`GET /v1/responses` upgrade) | New capability, optional for clients |
| LightOnOCR-3 0.8B/4B image chat on CUDA | New model we don't have; ignore |
| GLM tool-call / Metal grouped-rows / `--decode-share` Qwen3.5 changes | Not our families/settings |

## Measured re-port cost (the 1.2.6 playbook, replayed)

In a detached worktree at `v1.2.7`:

```
git apply --check --verbose fork-v126.patch   → PASS, one hunk at offset +1 line
git apply --3way fork-v126.patch              → all 12 files applied, ZERO conflicts
git diff --name-only --diff-filter=U          → (empty)
```

Why it is cleaner than the 1.2.6 re-port (which had two structural conflicts): our v1.2.6 delta was
already written against the post-move layout, and **every file the port touches at the structural
level is byte-identical between the tags**:

| file | v1.2.6 → v1.2.7 |
| --- | --- |
| `zig/src/core/lanes/backend.zig` (lane vtable) | no diff → `bolt_native.zig` needs **no API work** |
| `zig/build/cuda.zig` (bolt_build site) | no diff → the fork's re-add lands unchanged |
| `zig/src/native/cuda_families.zig` (registry) | no diff → `nemotron.bolt` registration unchanged |
| `zig/src/platform/optional_libraries.zig`, `core/lanes/grammar.zig` | no diff → `tfgrammar.dll`, `pdfium.dll`, `tfvideo.dll` names and the Windows `openRestricted` path intact |
| `zig/src/server/cli.zig` | no diff → the 15 serve flags `verify-engine.ps1` asserts are unchanged |
| root `build.zig` + `zig/build/` | 16 files, +74/−12 (host-CI, qwen35 layers, hip…) — none conflict with the fork |

Fork files also touched upstream: only `../../README.md` and `zig/src/server/main.zig` — both applied
cleanly (main.zig at offset +1).

## The Mia stack — all five apply on v1.2.7 + fork (measured)

Applied in order in the same worktree after the fork delta: `0001 → 0002 → 0003 → 0004 → 0005`,
**every one clean**, 56 files touched total. Copies kept in `../../local-patches/mia-v1.2.7/` with
`LICENSE.mia` (MIT, MiaAI-Lab; source repo @ `b956dba8`, patches written against `93a2e93e`).
Provenance per patch: 0001/0002/0003/0004 MiaAI-Lab (0003 adapted from their GLM recipe's
`0038-glm-kv-fp8`), 0005 = chai-md's TensorFold #90 rebased by Mia.

| patch | default behaviour after landing | what it buys | gate before trusting |
| --- | --- | --- | --- |
| `0001` quantised vision tower | loader **also** accepts MXFP8/NVFP4 `model.visual.*`, dequantised to bf16 at load; bf16 path unchanged | stock FP4-Local serves with `--vision`, **no splice**; the spliced checkpoint keeps working | `test-qwen-vision-weights-host` (0001 wires its new quant tests into it) + Serve tier on the **stock** checkpoint |
| `0002` image budget 16k | per-request cap 4,096 → 16,384; per-image still ≤4,096; `Limits` default unchanged | multi-image requests without `BadImageLimits`; `--vision-image-tokens 16384` becomes legal | vision gate, then raise the GUI profile value deliberately |
| `0003` FP8 KV | **opt-in** `--kv-cache fp8`; default stays bf16. e4m3 + power-of-two scale per position/KV-head; indexer keys, pooled blocks, DeltaNet states stay bf16. Refuses `--tp`, `--slide`, `TF_FLASHNEXT_KV_PAGES` (our profile uses none) | ~17.5 KiB/token vs 30: **262k×3 full streams** beside 72.7 GiB weights at 4 GiB reserve + 2 GiB vision (×4 at 2 GiB reserve), vs ×2 bf16. Mia measures ~98.8% top-1 agreement | its own A/B: greedy reply hashes bf16-vs-fp8, a 200k needle, `/stats` memory, full-window admission. Lossy — never a silent default |
| `0004` MXFP8 prompt tile | **on by default** for N≥1024 (`mx_min_n=1024`); `TF_FLASHNEXT_PROMPT_MX128=0` reverts to the exact kernels | Mia's v1.2.7 prefill 2,108/2,166/2,047 → **2,303/2,443/2,293 tok/s** (4k/31k/126k), 199,730-token prompt 95.7 s; decode/TTFT unchanged, `exact.py` passes | our warm-cache A/B + reply hashes; the =0 run isolates its contribution |
| `0005` video wiring | inert: `video_tokens` defaults 0 and `tfvideo.dll` doesn't exist yet → video parts refused exactly as today | the lanes-path glue our serve needs (`QwenVideoUnsupported` gone); ready for the FFmpeg DLL when built | `check-native-cuda-host` compile gate now; live video only after the separate FFmpeg work item |

**Expectation setting:** Mia's headline decode gains (+17%/+37% at 3/5 streams) are vs **v1.1.4** —
we already banked most of that at v1.2.6. Against our v1.2.6 the honest expectation is: prefill
+~5-10% (0004), decode/TTFT level, KV memory ~halved when fp8 is enabled, plus the feature unlocks.
The A/B decides, not their table.

## The plan

**P0 — branch + re-port (~15 min, already proven in scratch).**
```bat
cd C:\Projects\tensorfold-win-arm64\tensorfold
git diff v1.2.6..win-arm64/v1.2.6 > ../local-patches/fork-v126.patch
git switch -c win-arm64/v1.2.7 v1.2.7
git apply --3way ../local-patches/fork-v126.patch
git add -A && git commit -m "re-port the Windows ARM64 / Bolt fork from v1.2.6 onto upstream v1.2.7"
```
Zero conflicts expected (measured). FORK.md gets its v1.2.7 row in P5, with the verified numbers.

**P1 — Mia stack as five revertible commits + host gates (~30 min).**
Apply each `../../local-patches/mia-v1.2.7/000N-*.patch` with `git apply`, one commit each, message
naming the patch, MiaAI-Lab @ `b956dba8`, MIT, and `TF_REF 93a2e93e`. Per-commit granularity means
any single patch can be reverted without unwinding the port. Then, in a `vcvarsall.bat arm64`
environment from `../../tensorfold/`:
```bat
tools\zig-aarch64-windows-0.17.0\zig.exe build check-native-cuda-host
tools\zig-aarch64-windows-0.17.0\zig.exe build test-qwen-vision-weights-host --summary all
tools\zig-aarch64-windows-0.17.0\zig.exe build test-codec-diagnostics-host --summary all
```
(12/12 codec diagnostics is the v1.2.6 baseline; the vision-weights step now includes 0001's quant
tests; `check-native-cuda-host` is Mia's compile gate for 0005 — no GPU.)

**P2 — build (~40 min cold, per the 1.2.6 receipt).** `../../scripts/build/build-bolt-127.bat` = copy of
`../../scripts/build/build-bolt-126.bat` with `--prefix zig-out-v127` and the rem updated. Same line otherwise:
`zig build native bolt install -Dsm=121 -Dstrip=true -Dnvcc=... -Dbolt-src=...\bolt-recipe\engine`.
**The v1.2.6 install keeps serving throughout** — nothing points at v127 until P5.

**P3 — candidate gate (~30 min, Serve tier on AC).**
- Copy the codec DLLs into `zig-out-v127/native/lib/`: `turbojpeg.dll`, `libwebpdecoder.dll`,
  `libsharpyuv.dll`, `tfgrammar.dll` from the v126 install, plus **`pdfium.dll`** from
  `../../downloads/pypdfium2-5.14.0-py3-none-win_arm64.whl` (see MIA-V127-REVIEW.md — verified loadable).
- `../../tests/engine/verify-engine.ps1 -Exe ...\zig-out-v127\native\bin\tensorfold-native.exe -Tier Probes`
  then `-Tier Decode` (no GPU). The gate reads `../../gui/models.json` env, so the v126-pointing
  `TENSORFOLD_LIBWEBP` still resolves — the DLLs are engine-version-independent.
- `-Tier Serve` on AC power (keep-awake is built into the gate): boots the vision model, JPEG/WebP
  positives + negatives. **Add the PDF fixture here** and `--vision-pdf` to the profile — the PDF
  wiring is zero engine work and rides this pass for free.
- New acceptance for 0001: load the **stock** (unspliced) FP4-Local with `--vision` and get a pixel
  answer — the splice-free path proven on this box.

**P4 — A/B bench vs v1.2.6 (~1-2 h, method per BENCH-1.2.6.md).**
`../../bench/run-ab.sh v127 <exe>` against the v126 baseline: **warm page cache** (discard the first
pair, alternate builds, medians), nonce prompts, prefill 2/8/32K, 1- and 8-stream decode, reply
hashes. Expected: prefill up, decode level, hashes identical. One run with
`TF_FLASHNEXT_PROMPT_MX128=0` isolates 0004. Bolt: load + answer + a strict `json_schema` through
`tfgrammar.dll` (flat Bolt panel is correct — its kernels are the recipe's). Then the **FP8 KV
A/B** separately: `--kv-cache fp8` vs bf16, greedy hashes, a 200k needle, `/stats` resident bytes,
and 3 concurrent full 262k windows admitted.

**P5 — promote + receipts (~15 min).** Point `../../serve-qwen38.bat` / `../../serve-bolt.bat` and the GUI
profile's exe + `TENSORFOLD_LIBWEBP` at `zig-out-v127`; **restart the GUI** (catalog is read at
startup). Write `BENCH-1.2.7.md`, update FORK.md (branch row + status), README receipt, bump the
superproject's submodule pointer. Push `win-arm64/v1.2.7` to the `fork` remote (TheJeff) via the
gh credential helper. **Rollback stays hot:** `zig-out-v126` + `win-arm64/v1.2.6` untouched; the
GUI header's version chip makes the running engine obvious.

## Risks a build still has to settle

1. **New-TU compiler break classes** (skill's standing warning): 188 commits of new code can hit
   clang-19 ARM64 `/O2` SEH epilogue bugs (remedy: the offending TU onto the `/O1` list in
   `zig/build/options.zig` — which upstream touched, +2/−1) or x86 intrinsics guarded only by
   `_MSC_VER`. Read the failing TU from the log; don't assume the 1.2.6 patch set covers it.
2. **CUDA contract receipts are nvcc-keyed** (`sm121 refreshed with 13.0.88`, later
   `later_pending`): `tf-cuda-test` won't assert our 13.4 images — coverage gap, not a build gate.
3. **0003 is lossy** (~98.8% top-1 on Mia's harness): opt-in flag only until our own hash/needle
   A/B passes; never make it a profile default silently.
4. **0004's relaxed tile is not bit-exact by construction** (Mia gates it with `exact.py` and a
   FP64-bound `tf-cuda-test qmmf-prompt-mx`): our reply-hash gate is the equivalent; the =0 env
   gives an instant fallback if hashes move.
5. **`BadTiedHead` refusal** if the checkpoint's `tie_word_embeddings` is unset/contradictory
   (#2714) — a config read at first load, not a port defect.
6. **0005 changes nothing observable** until `tfvideo.dll` exists — video stays refused; the
   FFmpeg Windows build is its own work item (NEXT-STEPS Item 3, routes (a)/(b)).

## Effort

~Half a day of machine time, mostly unattended: P0+P1 ≈ 45 min (composition already proven),
P2 ≈ 40 min cold build, P3 ≈ 30 min, P4 ≈ 1-2 h bench, P5 ≈ 15 min. No new toolchain, no new
dependencies except the already-verified pdfium.dll.

## Reproduce the scoping

```bash
cd C:/Projects/tensorfold-win-arm64/tensorfold
git fetch origin tag v1.2.7 --no-tags
git rev-parse v1.2.7^{commit}                      # 93a2e93e... = Mia TF_REF
git diff v1.2.6..win-arm64/v1.2.6 > fork.patch     # 12 files, +905/-4
git worktree add --detach <scratch>/tf-127 v1.2.7
cd <scratch>/tf-127
git apply --check --verbose fork.patch             # PASS (one +1 offset)
git apply --3way fork.patch                        # zero conflicts
for p in <repo>/local-patches/mia-v1.2.7/000*.patch; do git apply "$p" || break; done   # all 5 clean
git diff v1.2.6..v1.2.7 -- zig/src/core/lanes/backend.zig zig/build/cuda.zig \
    zig/src/native/cuda_families.zig zig/src/platform/optional_libraries.zig \
    zig/src/core/lanes/grammar.zig zig/src/server/cli.zig    # empty: all byte-identical
```

## Decisions before starting

1. **Carry all five Mia patches** as separate commits on `win-arm64/v1.2.7` (recommended — each
   revertible, runtime defaults stay conservative), or re-port pure first and stack later.
2. **PDF wiring rides P3** (recommended — dependencies verified, zero engine work).
3. **FP8 KV stays opt-in** until its A/B passes (recommended).
4. Video's FFmpeg build deferred to its own session (NEXT-STEPS Item 3).

ATC note: this is fork-branch maintenance on our own `win-arm64/*` line — no upstream claim
needed. Anything that later goes upstream as a PR follows `../../tensorfold/AGENTS.md` (claim, `atc who`,
PR pre-flight). Mia patch commits carry their MIT provenance in the message and
`../../local-patches/mia-v1.2.7/LICENSE.mia`.

## Execution status — P0–P2 DONE (2026-11-19)

- **P0** — branch `win-arm64/v1.2.7` at the tag commit; re-port commit `1ff67e5ba`, zero conflicts
  exactly as scoped. Fork delta kept at `../../local-patches/fork-v126.patch`.
- **P1** — five Mia commits: `65509a3fa` (0001), `9ec0bd16d` (0002), `55df98965` (0003),
  `f0137a17e` (0004), `fcedfdeca` (0005). Host gates via `../../scripts/build/host-gates-127.bat`:
  `test-codec-diagnostics-host` **12/12** (the v1.2.6 baseline), `test-qwen-vision-weights-host`
  **16/16** including 0001's five new quant tests, `check-native-cuda-host` **OK** (0005's compile
  gate). No compiler break classes hit — the `/O1` and `_MSC_VER` risks did not materialize.
- **P2** — `../../scripts/build/build-bolt-127.bat`, **BUILD OK first attempt, 7.5 min** (11:05:47 → 11:13:17; warm
  zig cache from the 1.2.6 build plus gate 3's host compile). `zig-out-v127/native/bin/
  tensorfold-native.exe` 49,894,400 bytes; `bolt.dll` 6,206,464 bytes (recipe sources unchanged,
  cached artifact reused). Runner: `../../scripts/port-127/port-127-gates-build.ps1` (keep-awake, gates-then-build),
  log `../../logs/port-127-gates-build.log`.
- **Candidate gate so far (no GPU):** codec DLLs + `tfgrammar.dll` copied from the v126 install,
  `pdfium.dll` from the win_arm64 wheel into `zig-out-v127/native/lib/`.
  `verify-engine.ps1 -Exe <v127> -Tier Probes`: **0 failed, 1 warned** (video — the known FFmpeg
  gap); version **1.2.7**, chip `nvidia-sm121`, cuda present, 102 serve flags, PDFium found.
  `-Tier Decode`: pixel parity vs Pillow **max channel diff 0** on every JPEG/WebP fixture,
  0 failed.
- **P3 DONE (2026-11-19, on AC):** Serve gate on the spliced vision checkpoint **0 failed,
  0 warned** — including the new PDF checks (`document.pdf rendered and read [PDFIUM-OK]`,
  `corrupt.pdf refused [HTTP 400]`); 26 s boot. **0001 acceptance:** the stock unspliced FP4-Local
  booted with `--vision` (77.65 GiB, 55.9 s) and passed the same gate (1 informational warn: the
  stock GUI profile carries no `--vision` itself). Gate extended: `make-fixtures.py` writes
  `document.pdf`/`corrupt.pdf`; `verify-engine.ps1` adds `--vision-pdf` when pdfium.dll ships beside
  the candidate and asserts the PDF positive+negative; `../../gui/models.json` vision profile carries
  `--vision-pdf`.
- **P4 DONE:** three keep-awake rounds (`../../scripts/port-127/ab-127{,-round2,-round3}.ps1`). Scored b/c medians
  (128-token replies): prefill **+4.8/+1.4/+2.4%** (2K/8K/32K), 1-stream decode level, 8-stream
  −10.4% — a noise-dominated cell (per-stream 24-148 tok/s) that **reversed at the historical
  384-token length: +6.4%** (152.5 → 162.3 agg, d pair). Reply hashes identical on every prompt
  across all runs. mx0 isolation: the 0004 tile contributes ~+12% at 2K even in this I/O-bound
  regime. **fp8 KV: 5 full 262k streams admitted** (4.72 GiB/stream vs bf16 7.86, which caps at 3 —
  the bf16×3 probe was admitted, my pre-estimate of a refusal was wrong); **255,002-token needle
  FOUND on both dtypes** (fp8 161.8 s, bf16 145.5 s). Environment: SW power cap 1761/3003 MHz,
  72 °C, cold n-gram cache post-reboot — absolutes ~4-5× below BENCH-1.2.6's warm day, deltas
  valid. Round 1 lost three runs to a stale LISTENING entry; `run-ab.sh` now waits the port out.
  Bolt lane + grammar: **PASS** on the fixed check (true readiness + thinking off; the first
  attempt failed on the check's own handling, not the engine). Receipt: `BENCH-1.2.7.md`.
- **P5 DONE:** `../../serve-qwen38.bat` (v127 + `KV_CACHE` passthrough, bf16 default), `../../serve-bolt.bat`,
  `../../gui/models.json` (exe + `TENSORFOLD_LIBWEBP` → v127, `--vision-pdf` on the vision profile),
  README/FORK.md promoted, `BENCH-1.2.7.md` written, submodule branch pushed to the fork remote,
  superproject pointer bumped. **v1.2.7 is the serving default; `zig-out-v126` +
  `win-arm64/v1.2.6` stay hot for rollback.**

