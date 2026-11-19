#!/usr/bin/env python3
"""Needle-in-haystack at ~200k tokens against a running Flash Next server.

Proves long-context retrieval -- and for --kv-cache fp8 (mia 0003), that the lossy
cache still finds a fact buried at depth. Deterministic haystack (seeded), needle
at ~60% depth, greedy with thinking off. Reports usage.prompt_tokens (the real
count, not the char estimate), wall seconds, and whether the code came back.

Usage: python needle-200k.py --label fp8x3 --base-url http://127.0.0.1:8084/v1 \
           --out bench/results/needle-fp8x3.json
Exit 0 = needle found, 1 = missed or request failed.
"""
import argparse
import json
import random
import time
import urllib.request

NEEDLE = "The secret launch code is VIOLET-7391."
QUESTION = "What is the secret launch code? Answer with the code only."


def post(base, body, timeout=900):
    req = urllib.request.Request(
        base.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def haystack(target_chars, seed=7):
    rng = random.Random(seed)
    stations = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
    lines, total, i = [], 0, 0
    while total < target_chars:
        s = rng.choice(stations)
        v = rng.randint(100, 999)
        t = rng.randint(-40, 60)
        line = (f"Log entry {i:06d}: station {s} reported {v} units at {t} degrees, "
                f"nominal drift, no action taken.")
        lines.append(line)
        total += len(line) + 1
        i += 1
    lines.insert(int(len(lines) * 0.6), NEEDLE)
    return "\n".join(lines), i


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--base-url", default="http://127.0.0.1:8084/v1")
    ap.add_argument("--model", default="Qwen3.8-Flash-Next")
    ap.add_argument("--out", required=True)
    ap.add_argument("--target-chars", type=int, default=780_000)
    args = ap.parse_args()

    text, n = haystack(args.target_chars)
    body = {
        "model": args.model,
        "messages": [{"role": "user", "content": text + "\n\n" + QUESTION}],
        "max_tokens": 48,
        "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    t0 = time.time()
    try:
        r = post(args.base_url, body)
    except Exception as e:
        out = {"label": args.label, "needle_found": False, "error": str(e)}
        json.dump(out, open(args.out, "w"), indent=1)
        print(f"NEEDLE {args.label}: REQUEST FAILED {e}")
        return 1
    dt = time.time() - t0
    msg = r["choices"][0]["message"]
    reply = ((msg.get("content") or msg.get("reasoning_content") or "")).strip()
    usage = r.get("usage", {})
    found = "VIOLET-7391" in reply
    out = {
        "label": args.label,
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "needle_found": found,
        "reply": reply,
        "seconds": round(dt, 1),
        "haystack_lines": n,
    }
    json.dump(out, open(args.out, "w"), indent=1)
    pt = usage.get("prompt_tokens") or 0
    pre = f", ~{pt / dt:.0f} tok/s end-to-end" if pt else ""
    print(f"NEEDLE {args.label}: {'FOUND' if found else 'MISSED'} "
          f"({pt} prompt tokens, {dt:.1f}s{pre}) reply={reply!r}")
    return 0 if found else 1


if __name__ == "__main__":
    raise SystemExit(main())
