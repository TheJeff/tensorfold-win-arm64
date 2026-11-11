#!/usr/bin/env python3
"""Cold-prefill and multi-stream bench for a TensorFold serve, A/B across engine builds.

Every prefill prompt is unique (random nonce + shuffled filler), so the engine's
prefix cache can never serve it: TTFT is a real cold prefill.

  python bench/bench-flashnext.py --label 1.2.3 --port 8084 --out bench/results-1.2.3.json

Reports, per label: cold prefill tok/s and TTFT at 2K/8K/32K, decode tok/s at one
stream, aggregate decode tok/s at 8 streams, and a reply hash so two builds can be
checked for equal tokens.
"""

import argparse
import hashlib
import json
import random
import threading
import time
import urllib.error
import urllib.request

WORDS = (
    "engine kernel tensor lane prompt cache decode prefill stream rank fabric memory"
    " shard expert router attention latent window slot budget reserve quant tile warp"
    " block row column vector matrix gradient token model server client request reply"
).split()


def filler(rng, tokens):
    """~1.3 tokens a word on BPE; good enough to land in the right length band."""
    words = [rng.choice(WORDS) for _ in range(tokens)]
    return " ".join(words)


def make_prompt(rng, target_tokens, nonce):
    return (
        f"[{nonce}] Read the following operator notes and answer with one short sentence.\n\n"
        + filler(rng, target_tokens)
        + "\n\nIn one sentence: what are these notes about?"
    )


def stream_chat(base, model, prompt, max_tokens, timeout=1800):
    """One streaming chat completion. Returns ttft, tokens, decode tok/s, text."""
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "seed": 42,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    req = urllib.request.Request(
        base + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    ttft = None
    chunks = 0
    text = []
    usage = None
    last = None
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                ev = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if ev.get("usage"):
                usage = ev["usage"]
            for choice in ev.get("choices") or []:
                delta = choice.get("delta") or {}
                piece = delta.get("content") or delta.get("reasoning_content") or ""
                if not piece:
                    continue
                now = time.perf_counter()
                if ttft is None:
                    ttft = now - t0
                else:
                    chunks += 1
                last = now
                text.append(piece)
    wall = time.perf_counter() - t0
    tokens = (usage or {}).get("completion_tokens")
    if tokens is None:
        tokens = chunks + 1
    prompt_tokens = (usage or {}).get("prompt_tokens")
    decode = (tokens - 1) / (last - t0 - ttft) if (ttft and last and last > t0 + ttft and tokens > 1) else None
    return {
        "ttft": ttft,
        "wall": wall,
        "tokens": tokens,
        "prompt_tokens": prompt_tokens,
        "decode_tps": decode,
        "text": "".join(text),
    }


def reply_hash(text):
    norm = " ".join(text.split())
    return hashlib.sha256(norm.encode()).hexdigest()[:16]


def wait_health(base, deadline_s=900):
    t0 = time.time()
    url = base.rsplit("/v1", 1)[0] + "/health"
    while time.time() - t0 < deadline_s:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    print(f"  healthy after {time.time() - t0:.0f}s", flush=True)
                    return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(5)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:8084/v1")
    ap.add_argument("--model", default="Qwen3.8-Flash-Next")
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefill-lens", default="2000,8000,32000")
    ap.add_argument("--streams", default="1,8")
    ap.add_argument("--stream-tokens", type=int, default=128)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    if not wait_health(args.base_url):
        raise SystemExit("server never became healthy")
    base = args.base_url.rstrip("/")
    rng = random.Random(args.seed)
    out = {"label": args.label, "prefill": [], "streams": [], "reply_hashes": {}}

    # warm-up: JIT, first-touch, avoids a cold first measurement
    stream_chat(base, args.model, make_prompt(rng, 64, "warmup"), 16)
    print("  warm-up done", flush=True)

    for n in [int(x) for x in args.prefill_lens.split(",")]:
        nonce = f"p{n}-{rng.randrange(1 << 30)}"
        r = stream_chat(base, args.model, make_prompt(rng, n, nonce), 8)
        pt = r["prompt_tokens"]
        rec = {
            "nominal_tokens": n,
            "prompt_tokens": pt,
            "ttft_s": round(r["ttft"], 3),
            "prefill_tps": round(pt / r["ttft"], 1) if r["ttft"] else None,
        }
        out["prefill"].append(rec)
        print(f"  prefill {n:>6}: prompt_tokens={pt} ttft={rec['ttft_s']}s {rec['prefill_tps']} tok/s", flush=True)

    for k in [int(x) for x in args.streams.split(",")]:
        prompts = [make_prompt(rng, 400, f"s{k}-{i}-{rng.randrange(1 << 30)}") for i in range(k)]
        results = [None] * k
        barrier = threading.Barrier(k)

        def run(i):
            barrier.wait()
            results[i] = stream_chat(base, args.model, prompts[i], args.stream_tokens)

        t0 = time.perf_counter()
        threads = [threading.Thread(target=run, args=(i,)) for i in range(k)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        wall = time.perf_counter() - t0
        tokens = sum(r["tokens"] for r in results)
        per = [round(r["decode_tps"], 1) for r in results if r["decode_tps"]]
        rec = {
            "streams": k,
            "wall_s": round(wall, 2),
            "tokens": tokens,
            "aggregate_tps": round(tokens / wall, 1),
            "per_stream_decode_tps": per,
            "ttft_s": [round(r["ttft"], 3) for r in results],
        }
        out["streams"].append(rec)
        print(f"  streams {k:>2}: aggregate={rec['aggregate_tps']} tok/s over {wall:.1f}s per-stream={per}", flush=True)
        if k == 1:
            out["reply_hashes"][f"streams{k}"] = reply_hash(results[0]["text"])

    # one fixed prompt both builds must answer identically (equal-reply check)
    fixed = "List the first eight prime numbers, comma separated, and nothing else."
    r = stream_chat(base, args.model, fixed, 64)
    out["reply_hashes"]["primes"] = reply_hash(r["text"])
    out["primes_reply"] = " ".join(r["text"].split())[:200]

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)
    print(f"  wrote {args.out}", flush=True)


if __name__ == "__main__":
    main()
