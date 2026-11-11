# TensorFold 1.2.6 on the N1X: Qwen3.8 Flash Next FP4, A/B against our 1.2.3 build

Measured 2026-11-11 on the RTX Spark N1X (Windows 11 ARM64, `sm_121`, 98,304 MiB framebuffer),
branch `win-arm64/v1.2.6` (upstream tag `v1.2.6` + the Windows/Bolt fork delta) against the
`win-arm64/v1.2.3` install the box has been serving from.

## Verdict

**1.2.6 is safe to keep and worth keeping, but it is not a speed-up for Flash Next on this box
beyond one measurable cell: 8 concurrent streams decode 3.7% faster.** Cold prefill, single-stream
decode and replies are unchanged to within noise. The port built clean on the first attempt
(aarch64-windows + CUDA 13.4.59 + `-Dsm=121`), and Bolt still serves through `libbolt.dll`.

| warm cache (median) | 1.2.3 | 1.2.6 | delta |
| --- | ---: | ---: | ---: |
| cold prefill, 2K tokens | 1,825 tok/s | 1,936 tok/s | +6.1% |
| cold prefill, 8K | 1,932 | 1,906 | −1.3% |
| cold prefill, 32K | 1,810 | 1,828 | +1.0% |
| decode, 1 stream (384 tokens) | 207.6 tok/s | 211.7 tok/s | +2.0% |
| decode, 8 streams (aggregate) | 197.1 tok/s | **204.3 tok/s** | **+3.7%** |

The 8-stream cell is the only one whose samples do not overlap: 1.2.3 read 196.3 and 197.9, 1.2.6
read 204.0, 204.2, 204.5 and 206.3. That matches upstream's one GB10 claim for this checkpoint
family (`#1942`, "8 streams decode 3-6% faster"). Everything else is the "level" their own release
reads reported.

## Method

`bench/run-ab.sh` + `bench/bench-flashnext.py`, one build at a time, alternating:

- serve Qwen3.8-Flash-Next-FP4-Local with `serve-qwen38.bat`'s settings (`--parallel 2
  --context 262144 --prompt-cache-gib 4`, `TF_FLASHNEXT_DRAFTS=6`, `TF_FLASHNEXT_GATHER_READ=pread`,
  `TENSORFOLD_MEMORY_RESERVE_GIB=4`), one server on the GPU at a time, framebuffer drained between runs;
- every prefill prompt is **unique** (random nonce + shuffled filler) so the prefix cache cannot
  serve it: TTFT is a real cold prefill, cross-checked against the server's own `ttft=` line;
- 384-token streaming replies, `temperature 0`, `seed 42`, decode measured between first and last
  delta; 8-stream runs are 8 threads released together, each on its own prompt;
- a fixed prompt is hashed every run to prove equal tokens across builds.

Run order: 1.2.3, 1.2.6a, 1.2.3b, 1.2.6b, 1.2.6c (both Flash Next prefill knobs off), 1.2.3c,
1.2.6d, 1.2.3d.

## The trap that produced a fake 25% win

The first two 1.2.3 runs read 1,243 / 1,402 / 1,438 tok/s prefill and looked like 1.2.6 was 20-30%
faster. They were simply the first runs on a **cold Windows page cache**: Flash Next reads its
n-gram embedding tables from the checkpoint files through the page cache (upstream lists this in
`docs/known-issues.md`), so a fresh server right after a 40-minute build is 20-35% slower to
prefill than the same binary later. Once 1.2.3 was re-measured warm (`1.2.3c`, `1.2.3d`) it matched
1.2.6 exactly. **Never A/B this model on cold boots** — do a throwaway run first and score the second
and later ones, or alternate runs and discard the first pair.

Consequence for the reading of upstream's numbers: their "release reads" alternate fresh servers and
drop an unscored warm-up, which is exactly why they report level where a naive first-run comparison
reports tens of percent.

## The two documented Flash Next prefill knobs do nothing here

`1.2.6c-noknobs` ran with `TF_FLASHNEXT_PROMPT_BF16=0 TF_FLASHNEXT_KEEP_INPASS=0` and read
1,876 / 1,943 / 1,847 tok/s — level with 1.2.6 defaults and with 1.2.3. So on this checkpoint
(NVFP4 `FP4-Local`, not the MLX 4-bit pack the 1.2.5 tile win was measured beside) neither the
128 × 128 BF16 prompt tile (`#1846`) nor the in-pass prompt-cache mark (`#1866`) moves the number.
They cost nothing, so leave them on.

## Absolute tok/s are not general throughput

The bench prompts drive MTP acceptance to 94-99% (`accepted=353/358` in the request log), because the
replies are predictable prose about the filler. The earlier receipt in `README.md` — 110 tokens in
3.57 s, ~30 tok/s — was the same model at 58% acceptance on a short answer. Both are real; the A/B
above is valid because both builds saw identical acceptance, but do not quote 211 tok/s as this
model's throughput.

## Equal replies

`primes` hash `69577cb06964986c` on all eight runs, and the 384-token stream reply hash
`6e035c11bd458287` on every run after the first (that one was the 128-token sample). Per-request
`sha=` lines in `logs/serve-*.log` match one for one between builds.

## Load and memory

- Flash Next: load 35-42 s, 80.8 GiB resident (weights 72.7 GiB + 4 GiB prompt cache + reserve),
  same on both builds.
- Bolt on 1.2.6: loaded in 25.2 s, `/health` reports `version: 1.2.6` and
  `NVIDIA RTX Spark N1X (6144-core Blackwell RTX GPU)`; a 28-token prompt answered
  `bolt 1.2.6 ok` at 203 tok/s (9 tokens, MTP 7/7). The libbolt lane registration survived the move
  from `zig/src/native/cuda.zig` to `native/cuda_families.zig`.

## What a re-port cost

`git apply --3way` of the v1.2.3 fork delta onto `v1.2.6` left two conflicts; both were structural,
not semantic:

- `zig/build/cuda.zig` — upstream dropped `golden.zig` (its step moved into `cuda_server_host.zig`),
  so only the `bolt_build` import and `bolt_build.steps(b, nvcc)` call were re-added;
- `zig/src/native/cuda.zig` — the family registry moved to `native/cuda_families.zig`, so
  `nemotron.bolt` was added there;
- the lane vtable (`zig/src/core/lanes/backend.zig`) is byte-identical between the tags, so
  `bolt_native.zig` needed no work.

Build: `build-bolt-126.bat` (same toolchain as `build-bolt.bat`, `--prefix zig-out-v126` so the 1.2.3
install stays intact). One clean `BUILD OK`, ~40 min cold, seconds warm. `tensorfold-native.exe`
49.4 MB vs 47.3 MB for 1.2.3.

## Reproduce

```bash
./build-bolt-126.bat                                            # ~40 min cold, zig-out-v126
STREAM_TOKENS=384 bash bench/run-ab.sh 1.2.6a tensorfold/zig-out-v126/native/bin/tensorfold-native.exe
STREAM_TOKENS=384 bash bench/run-ab.sh 1.2.3a tensorfold/zig-out/native/bin/tensorfold-native.exe
```

Run each twice, alternating, and ignore the first pair on a cold page cache.
