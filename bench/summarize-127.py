#!/usr/bin/env python3
"""Aggregate the 1.2.6 vs 1.2.7(+mia) A/B results per docs/receipts/BENCH-1.2.6.md's method:
discard the first (warm-up) pair, score medians of the remaining alternating
runs, compare reply hashes. Prints a markdown table for docs/receipts/BENCH-1.2.7.md.

Usage: python bench/summarize-127.py
"""
import json
import os
import statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "results")


def load(label):
    p = os.path.join(RES, f"results-{label}.json")
    return json.load(open(p)) if os.path.exists(p) else None


def med(rows, key):
    vals = [r[key] for r in rows if r.get(key) is not None]
    return st.median(vals) if vals else None


def fmt(x, nd=1):
    return f"{x:.{nd}f}" if isinstance(x, (int, float)) else "—"


def main():
    builds = {"1.2.6": ["1.2.6b", "1.2.6c"], "1.2.7": ["1.2.7b", "1.2.7c"]}
    data = {b: [load(l) for l in labs if load(l)] for b, labs in builds.items()}
    mx0 = load("1.2.7-mx0")
    a = {b: load(f"{b}a") for b in builds}

    print("## scored runs (warm-up pair a discarded)\n")
    for b, rows in data.items():
        print(f"- {b}: {len(rows)} scored runs")
    if a["1.2.6"] and a["1.2.7"]:
        print(f"- warm-up pair a: 1.2.6 prefill2K {a['1.2.6']['prefill'][0]['prefill_tps']:.0f} / "
              f"1.2.7 {a['1.2.7']['prefill'][0]['prefill_tps']:.0f} tok/s (discarded)")

    print("\n| metric | 1.2.6 | 1.2.7 | delta | 1.2.7 mx0 (0004 off) |")
    print("| --- | --- | --- | --- | --- |")
    for i, nom in enumerate((2000, 8000, 32000)):
        v6 = med([r["prefill"][i] for r in data["1.2.6"] if r], "prefill_tps")
        v7 = med([r["prefill"][i] for r in data["1.2.7"] if r], "prefill_tps")
        vm = mx0["prefill"][i]["prefill_tps"] if mx0 else None
        d = f"{(v7 / v6 - 1) * 100:+.1f}%" if v6 and v7 else "—"
        print(f"| prefill {nom // 1000}K tok/s | {fmt(v6, 0)} | {fmt(v7, 0)} | {d} | {fmt(vm, 0)} |")
    for s in (1, 8):
        def agg(rows):
            return med([x for r in rows if r for x in r["streams"] if x["streams"] == s], "aggregate_tps")
        v6, v7 = agg(data["1.2.6"]), agg(data["1.2.7"])
        vm = None
        if mx0:
            vm = next((x["aggregate_tps"] for x in mx0["streams"] if x["streams"] == s), None)
        d = f"{(v7 / v6 - 1) * 100:+.1f}%" if v6 and v7 else "—"
        print(f"| decode {s}-stream agg tok/s | {fmt(v6)} | {fmt(v7)} | {d} | {fmt(vm)} |")

    print("\n## reply hashes (must be identical across builds)\n")
    hashes = {}
    for lab in ("1.2.6a", "1.2.6b", "1.2.6c", "1.2.7a", "1.2.7b", "1.2.7c", "1.2.7-mx0"):
        r = load(lab)
        if r:
            hashes[lab] = r.get("reply_hashes", {})
    keys = sorted({k for h in hashes.values() for k in h})
    for k in keys:
        vals = {h.get(k) for h in hashes.values() if h.get(k)}
        status = "IDENTICAL" if len(vals) == 1 else f"DIFFER: {vals}"
        print(f"- {k}: {status} ({next(iter(vals)) if len(vals) == 1 else ''})")

    print("\n## fp8 KV / needle receipts\n")
    for lab in ("1.2.7-fp8x3", "1.2.7-bf16n"):
        p = os.path.join(RES, f"needle-{lab}.json")
        if os.path.exists(p):
            n = json.load(open(p))
            print(f"- {lab}: needle {'FOUND' if n.get('needle_found') else 'MISSED'} "
                  f"at {n.get('prompt_tokens')} prompt tokens, {n.get('seconds')}s, reply={n.get('reply')!r}")


if __name__ == "__main__":
    main()
