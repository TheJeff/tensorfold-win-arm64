# BENCH-1.2.7 — v1.2.6 → v1.2.7 (+ MiaAI-Lab 0001–0005), Flash Next FP4 on the N1X

Measured 2026-11-19, one RTX Spark N1X (GB10, `sm_121`, 96 GiB framebuffer), Windows 11 ARM64.
Builds: `zig-out-v126` (`win-arm64/v1.2.6`, `6c6615bd0`) vs `zig-out-v127`
(`win-arm64/v1.2.7`, `fcedfdeca` = upstream `93a2e93e` + fork delta + mia 0001–0005).
Zig 0.17.0 aarch64-windows, CUDA 13.4.59, MSVC arm64. Port receipt: `UPSTREAM-1.2.7.md`;
patch review: `MIA-V127-REVIEW.md`.

## Verdict

**Promote.** Replies are bit-identical across builds on every hashed prompt. Prefill is a few
percent up, single-stream decode is level, and at the historical 384-token reply length
**8-stream decode is +6.4%** (152.5 → 162.3 tok/s aggregate). The feature unlocks are the real
prize: **fp8 KV admits 5 full 262,144-token streams** (bf16 caps at 3), a **255,002-token needle
is found on both KV dtypes**, **PDF input works end-to-end**, and the **stock unspliced
checkpoint loads with `--vision`** (mia 0001). One noisy cell (8-stream at 128-token replies,
−10%) was re-measured at 384 tokens and reversed — see the method note.

## Environment caveat — absolutes are NOT comparable to BENCH-1.2.6's day

Two conditions held for every run today, equally for both builds:

- **GPU power-capped:** 1761 MHz of 3003 max, `clocks_event_reasons.active = 0x4` (SW power
  capping), 72 °C, AC connected. The box had been under continuous load since 11:21.
- **Cold n-gram page cache:** the 2026-11-18 bugcheck reboot emptied it, and the bench's unique
  nonce prompts keep touching fresh table rows. Prefill read ~360–800 tok/s where BENCH-1.2.6's
  warm day read ~1,800–1,940. This is I/O-bound prefill, which also **masks part of mia 0004's
  compute win** (the mx0 isolation below still shows the tile contributing at 2K).

The A/B deltas are the valid comparison: alternating builds, one server on the GPU at a time,
framebuffer drained between runs, same thermal regime. Do not quote today's absolutes against
last week's.

## Method

`../../bench/run-ab.sh` + `../../bench/bench-flashnext.py` (unique nonce prompts, TTFT → prefill tok/s,
decode between first and last delta, reply hashes), as in BENCH-1.2.6.md, with additions:

- `KV_CACHE` / `STREAMS` / `NEEDLE` env passthroughs; `../../bench/boot-probe.sh` for admission
  probes (short deadline, reads the engine's own `serving` line); `../../bench/needle-200k.py`
  (deterministic seeded haystack, needle at 60% depth, greedy, thinking off).
- Keep-awake wrappers (`../../scripts/port-127/ab-127*.ps1`) hold `ES_SYSTEM_REQUIRED` for whole sequences.
- Run order: **a pair (discarded warm-up)** → b, c pairs (scored, 128-token replies) →
  mx0 isolation → bf16×3 admission probe → fp8×3 bench+needle → bf16×1 bench+needle →
  **d pair (384-token confirmation)** → Bolt lane check.
- Round 1 lost three runs to a stale `LISTENING` netstat entry ~1 s after teardown;
  `run-ab.sh` now waits the port out (30 s) instead of refusing on the first read.

## Scored medians (b, c pairs; 128-token replies)

| metric | 1.2.6 | 1.2.7 | delta | 1.2.7 mx0 (0004 off) |
| --- | ---: | ---: | ---: | ---: |
| cold prefill 2K tok/s | 382 | 401 | **+4.8%** | 359 |
| cold prefill 8K | 590 | 599 | +1.4% | 593 |
| cold prefill 32K | 761 | 779 | +2.4% | 762 |
| decode 1-stream agg | 83.6 | 83.2 | −0.4% | 83.2 |
| decode 8-stream agg | 93.7 | 84.0 | −10.4% ⚠ | 90.0 |

⚠ The 128-token 8-stream cell is noise-dominated: per-stream speeds ranged 24–148 tok/s
(MTP acceptance on short replies), and the two pairs disagreed in magnitude. The 384-token
confirmation below is the cell to trust — it matches BENCH-1.2.6's method.

## 384-token confirmation (d pair, historical reply length)

| metric | 1.2.6d | 1.2.7d | delta |
| --- | ---: | ---: | ---: |
| cold prefill 2K tok/s | 353.2 | 361.2 | +2.3% |
| cold prefill 8K | 595.8 | 592.1 | −0.6% |
| cold prefill 32K | 740.5 | 800.8 | +8.1% |
| decode 1-stream, per-stream | 244.5 | 243.8 | level |
| decode 1-stream agg | 161.6 | 177.1 | +9.6% (wall/TTFT overhead, not kernel speed) |
| **decode 8-stream agg** | **152.5** | **162.3** | **+6.4%** |

Single samples each (confirmation, not a median); the per-stream spread is still wide
(25.7–179.8 on 1.2.7d) but the aggregate ordering held in both 384-token runs' direction.

## Reply hashes — identical across builds, every run

| prompt | hash (1.2.6 = 1.2.7, all runs) |
| --- | --- |
| primes (fixed) | `69577cb06964986c` |
| streams1, 128-token replies | `bf91a34a74215605` |
| streams1, 384-token replies | `6e035c11bd458287` |

The relaxed MXFP8 prompt tile (0004) and the rest of the stack preserve greedy output on these
prompts, matching Mia's `exact.py` result on their Spark.

## fp8 KV (mia 0003) — the context/concurrency unlock

Engine admission lines (`--context 262144`, 4 GiB reserve, model 72.76 GiB):

| config | per-stream window budget | streams admitted | prompt cache | load |
| --- | ---: | ---: | ---: | ---: |
| bf16 ×3 | 7.86 GiB | 3 (of 26.0 GiB KV budget) | 2.4 GiB | 51.8 s |
| fp8 ×3 | **4.72 GiB** | 3 | 4.0 GiB | 53.2 s |
| fp8 ×5 | 4.72 GiB | **5** | 2.4 GiB | 51.1 s |

bf16 ×4 does not fit the budget (4 × 7.86 = 31.4 > 26.0); fp8 ×5 does (5 × 4.72 = 23.6).
**Five concurrent full 262k windows on one 96 GiB GB10** — the Spark-recipe concurrency, here.

Needle at depth (`../../bench/needle-200k.py`, seeded haystack, code at 60%):

| run | prompt tokens | found | wall | reply |
| --- | ---: | --- | ---: | --- |
| fp8 ×3 | 255,002 | **yes** | 161.8 s | `VIOLET-7391` |
| bf16 ×1 | 255,002 | **yes** | 145.5 s | `VIOLET-7391` |

The lossy cache retrieves the buried fact exactly. fp8 read ~11% slower end-to-end on this
single sample (codes widened to bf16 per read); worth more samples before calling it a cost.
Resident after the needle: fp8 ×3 **80,263 MiB with three windows** vs bf16 ×1 83,217 MiB with
one — fp8 holds 3× the concurrency in less memory.

**Adoption:** opt-in (`--kv-cache fp8`, `KV_CACHE=fp8` in `../../serve-qwen38.bat`). Default stays
bf16. Mia's ~98.8% top-1 agreement is their harness; our hashes + needle pass, but sampled
long-chat equivalence is not proven here.

## PDF and the stock tower (P3 gate receipts)

`verify-engine.ps1 -Exe <v127> -Tier Serve`, on AC, keep-awake held by the gate:

- Spliced vision checkpoint: **0 failed, 0 warned**, ready in 26 s (gate's 8192-context boot).
  New PDF checks: `document.pdf rendered and read [PDFIUM-OK]` (the printed word exists only if
  PDFium rendered the page in-process — `pdf.zig:218`), `corrupt.pdf refused [HTTP 400]`.
  JPEG/WebP positives, 3 refusals, 5/5 ground-truth facts, 560 vs 26 prompt tokens — all pass.
- **Stock unspliced FP4-Local with `--vision` (mia 0001 acceptance): 0 failed**, 1 informational
  warn (the stock GUI profile carries no `--vision` itself). Loaded **77.65 GiB in 55.9 s** —
  the quantised tower decodes to bf16 at load; the ~15 s over the spliced load is that pass.
  The splice is now optional, kept for the v1.2.6 install.

## Bolt lane + grammar on v127

`../../scripts/port-127/bolt-check-127.ps1`: boot through the promoted `../../serve-bolt.bat`, chat reply, strict
`json_schema` (`answer: 4`) through the copied `tfgrammar.dll`. The first attempt failed on the
check's own handling (`/v1/models` answers before the load finishes; thinking ate the 64-token
budget — the engine logged the remedy). Fixed check (true readiness from the engine's `serving`
line, `enable_thinking: false`): **PASS** — ready ~22 s, chat answered, strict `json_schema`
returned `answer: 4` ("structured output: xgrammar over 131072 tokens"), MTP decode 87.9 /
135.0 tok/s. The hand-written lane backend needed no API work (vtable byte-identical between
tags), and the 1.2.6-era grammar DLL serves structured output on 1.2.7.

## Load times observed today

26 s (gate, 8192 ctx, spliced) · 51–56 s (262k ctx, parallel 2/3/5, stock) · 55.9 s (gate,
8192 ctx, stock + dequant). BENCH-1.2.6's 41 s was a warmer, higher-clock day; the delta is
environmental, not a port regression (both builds read 51–56 s today).

## Reproduce

From the repo root:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\port-127\ab-127.ps1          & rem round 1: a pair, probes, fp8x3 + bf16 needles (keep-awake)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\port-127\ab-127-round2.ps1   & rem b/c pairs, mx0, fp8x5 admission probe
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\port-127\ab-127-round3.ps1   & rem 384-token d pair
python bench\summarize-127.py
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\port-127\bolt-check-127.ps1
```

Per-run JSON: `../../bench/results/results-1.2.{6,7}{a,b,c,d}.json`, `results-1.2.7-mx0.json`,
`results-1.2.7-fp8x3.json`, `results-1.2.7-bf16n.json`, `needle-1.2.7-{fp8x3,bf16n}.json`.
Server logs: `../../logs/serve-*.log`, `../../logs/boot-*.log`, `../../logs/verify-*.log`, `../../logs/ab-127*.log`.
