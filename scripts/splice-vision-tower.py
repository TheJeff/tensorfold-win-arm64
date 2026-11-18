#!/usr/bin/env python3
"""Give Qwen3.8-Flash-Next-FP4-Local an unquantized vision tower.

The served checkpoint ships model.visual.* quantized -- blocks.0.attn.qkv.weight as
MXFP8 (F8_E4M3 with a U8 E8M0 scale, group 32) and blocks.0.mlp.linear_fc1.weight as
NVFP4 (packed U8 with an F8_E4M3 scale, group 16, plus weight_scale_2). The CUDA tower
loader, zig/src/vision/qwen_cuda_weights.zig, calls ck.expect(name, .bf16, shape) for
every one of its 333 tensors and returns error.UnexpectedTensor on the first mismatch,
so --vision refuses to load the model at all.

nvidia/Qwen3.8-Flash-Next-NVFP4-QAD left its tower alone -- its quantization_config
ignore list contains "model.visual*" -- and its vision_config is identical, so its bf16
tower is a drop-in. This script grafts that tower onto the FP4-Local weights without
ever modifying the original directory:

  * every file is hardlinked into the output directory, so the 95 GiB checkpoint costs
    no extra space and takes seconds rather than a copy
  * the single shard holding model.visual.* (model-00015-of-00021.safetensors, 4.6 GiB,
    75,242 tensors, most of them the 20M-entry ngram PLE tables) is rewritten. Its
    non-visual tensors are NOT re-serialized: the original data section is copied
    verbatim and their header offsets are reused unchanged, so byte-identity is true by
    construction rather than by comparison. The 499 quantized visual tensors are dropped
    from the header and the 333 bf16 ones are appended under the same names.
  * the shard keeps its original filename, so model.safetensors.index.json is already
    correct and is hardlinked untouched
  * config.json gains "model.visual*" in quantization_config.ignore and loses the 110
    model.visual.* entries from quantized_layers, so nothing claims the tower is still
    quantized

zig/src/vision/qwen_cuda_weights.zig ends with `if (r.ck.unused() != 0) return
error.UnusedVisionTensors`, which is why the 166 scale twins must be deleted rather than
left behind: an unconsumed tensor under the model.visual. prefix is a hard failure.

Usage:
    python scripts/splice-vision-tower.py            # build, then verify
    python scripts/splice-vision-tower.py --verify   # verify an existing output
"""
import argparse
import json
import os
import shutil
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "models", "Qwen3.8-Flash-Next-FP4-Local")
DST = os.path.join(ROOT, "models", "Qwen3.8-Flash-Next-FP4-Local-vision")
TOWER = os.path.join(ROOT, "downloads", "qad-vision", "model-00021-of-00036.safetensors")
PREFIX = "model.visual."
# Written, not linked: anything the engine may itself rewrite must not share an inode
# with the source checkpoint.
COPY_NOT_LINK = {".tensorfold-lock"}


_HDR_LEN = {}


def header_len(path):
    """Cached: a shard header here holds 75,242 entries, so parsing it per tensor is fatal."""
    n = _HDR_LEN.get(path)
    if n is None:
        with open(path, "rb") as f:
            n = struct.unpack("<Q", f.read(8))[0]
        _HDR_LEN[path] = n
    return n


def read_header(path):
    """(header, header_length) for a safetensors file."""
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        blob = f.read(n)
    _HDR_LEN[path] = n
    return json.loads(blob), n


def tensor_bytes(path, header, name):
    m = header[name]
    with open(path, "rb") as f:
        f.seek(8 + header_len(path) + m["data_offsets"][0])
        return f.read(m["data_offsets"][1] - m["data_offsets"][0])


def sections_identical(a, b):
    """Compare the source data section against the start of the destination's.

    The splice copies the source body verbatim and appends the bf16 tower, so the
    destination is legitimately longer. This asserts the first len(a) bytes match --
    not "the tensors we kept still match" but "every byte the tower was appended to is
    the byte it was". Returns (equal, bytes_compared).
    """
    _, an = read_header(a)
    _, bn = read_header(b)
    sa, sb = os.path.getsize(a) - 8 - an, os.path.getsize(b) - 8 - bn
    if sb < sa:
        return False, 0
    done = 0
    with open(a, "rb") as fa, open(b, "rb") as fb:
        fa.seek(8 + an)
        fb.seek(8 + bn)
        while done < sa:
            block = min(1 << 22, sa - done)
            ca, cb = fa.read(block), fb.read(block)
            if ca != cb:
                return False, done
            done += len(ca)
    return True, done


def expected_contract(vision_config):
    """The 333 tensors qwen_cuda_weights.zig demands, derived from vision_config alone."""
    v = vision_config
    h, d = v["hidden_size"], v["depth"]
    inter, out = v["intermediate_size"], v["out_hidden_size"]
    merged = (v.get("spatial_merge_size") or 2) ** 2 * h
    patch, temporal, channels = v["patch_size"], v["temporal_patch_size"], v.get("in_channels", 3)
    grid = int(v.get("num_position_embeddings", 48 * 48))
    e = {
        PREFIX + "patch_embed.proj.weight": [h, channels, temporal, patch, patch],
        PREFIX + "patch_embed.proj.bias": [h],
        PREFIX + "pos_embed.weight": [grid, h],
    }
    for i in range(d):
        b = f"{PREFIX}blocks.{i}."
        e.update({
            b + "norm1.weight": [h], b + "norm1.bias": [h],
            b + "attn.qkv.weight": [3 * h, h], b + "attn.qkv.bias": [3 * h],
            b + "attn.proj.weight": [h, h], b + "attn.proj.bias": [h],
            b + "norm2.weight": [h], b + "norm2.bias": [h],
            b + "mlp.linear_fc1.weight": [inter, h], b + "mlp.linear_fc1.bias": [inter],
            b + "mlp.linear_fc2.weight": [h, inter], b + "mlp.linear_fc2.bias": [h],
        })
    e.update({
        PREFIX + "merger.norm.weight": [h], PREFIX + "merger.norm.bias": [h],
        PREFIX + "merger.linear_fc1.weight": [merged, merged],
        PREFIX + "merger.linear_fc1.bias": [merged],
        PREFIX + "merger.linear_fc2.weight": [out, merged],
        PREFIX + "merger.linear_fc2.bias": [out],
    })
    return e


def build():
    if not os.path.isfile(TOWER):
        sys.exit("missing tower shard: %s\n  hf download nvidia/Qwen3.8-Flash-Next-NVFP4-QAD "
                 "model-00021-of-00036.safetensors --local-dir downloads/qad-vision" % TOWER)
    if os.path.exists(DST):
        sys.exit("refusing to overwrite %s\n  remove it first -- a splice is never applied in place" % DST)

    src_cfg = json.load(open(os.path.join(SRC, "config.json"), encoding="utf-8"))
    contract = expected_contract(src_cfg["vision_config"])
    index = json.load(open(os.path.join(SRC, "model.safetensors.index.json"), encoding="utf-8"))
    wm = index["weight_map"]

    shards = sorted({wm[k] for k in wm if k.startswith(PREFIX)})
    if len(shards) != 1:
        sys.exit("expected the tower in one shard, found %d: %s" % (len(shards), shards))
    target = shards[0]

    th, _ = read_header(TOWER)
    tower = {k: v for k, v in th.items() if k.startswith(PREFIX)}
    missing = sorted(set(contract) - set(tower))
    wrong = sorted(k for k in set(contract) & set(tower)
                   if tower[k]["dtype"] != "BF16" or tower[k]["shape"] != contract[k])
    if missing or wrong:
        sys.exit("tower shard is not usable: missing=%d wrong=%d" % (len(missing), len(wrong)))
    print("tower: %d bf16 tensors accepted against a %d-tensor contract" % (len(tower), len(contract)))

    os.makedirs(DST)
    linked = 0
    for base, _, files in os.walk(SRC):
        rel_dir = os.path.relpath(base, SRC)
        out_dir = DST if rel_dir == "." else os.path.join(DST, rel_dir)
        os.makedirs(out_dir, exist_ok=True)
        for name in files:
            rel = name if rel_dir == "." else os.path.join(rel_dir, name).replace("\\", "/")
            s = os.path.join(base, name)
            d = os.path.join(out_dir, name)
            if rel in (target, "config.json", "model.safetensors.index.json"):
                continue                       # all three written below
            if rel in COPY_NOT_LINK:
                shutil.copy2(s, d)
            else:
                os.link(s, d)                  # same volume: instant, no extra space
                linked += 1
    print("hardlinked %d files into %s" % (linked, DST))

    # --- rewrite the tower shard -----------------------------------------------------
    # Reuse the original data section byte for byte. Kept tensors keep their offsets, so
    # the 74,743 non-visual tensors cannot drift; only the header changes, plus appended
    # bf16 tower bytes at the end.
    src_shard = os.path.join(SRC, target.replace("/", os.sep))
    sh, sn = read_header(src_shard)
    body_start = 8 + sn
    body_len = os.path.getsize(src_shard) - body_start
    max_end = max((m["data_offsets"][1] for k, m in sh.items() if k != "__metadata__"), default=0)
    if max_end > body_len:
        sys.exit("%s: header claims %d bytes but the data section holds %d" % (target, max_end, body_len))

    header = {}
    if "__metadata__" in sh:
        header["__metadata__"] = sh["__metadata__"]
    kept = dropped = 0
    for name, m in sh.items():
        if name == "__metadata__":
            continue
        if name.startswith(PREFIX):
            dropped += 1
            continue
        header[name] = {"dtype": m["dtype"], "shape": m["shape"], "data_offsets": list(m["data_offsets"])}
        kept += 1

    cursor = max_end
    added_bytes = 0
    for name in sorted(contract):
        raw = tensor_bytes(TOWER, th, name)
        header[name] = {"dtype": "BF16", "shape": tower[name]["shape"], "data_offsets": [cursor, cursor + len(raw)]}
        cursor += len(raw)
        added_bytes += len(raw)

    blob = json.dumps(header, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    blob += b" " * ((-len(blob)) % 8)          # data section must start 8-byte aligned
    out_shard = os.path.join(DST, target.replace("/", os.sep))
    tmp = out_shard + ".part"
    with open(tmp, "wb") as out, open(src_shard, "rb") as src:
        out.write(struct.pack("<Q", len(blob)))
        out.write(blob)
        src.seek(body_start)
        remaining = body_len
        while remaining:
            chunk = src.read(min(1 << 22, remaining))
            if not chunk:
                break
            out.write(chunk)
            remaining -= len(chunk)
        for name in sorted(contract):
            out.write(tensor_bytes(TOWER, th, name))
    os.replace(tmp, out_shard)
    print("rewrote %s: kept %d tensors, dropped %d quantized visual, appended %d bf16 "
          "(%.3f GiB), file %.0f MiB"
          % (target, kept, dropped, len(contract), added_bytes / 2**30, os.path.getsize(out_shard) / 2**20))

    # --- config.json: never hardlink a file you are about to modify ------------------
    cfg = json.loads(json.dumps(src_cfg))
    qc = cfg.setdefault("quantization_config", {})
    ignore = qc.setdefault("ignore", [])
    if PREFIX.rstrip(".") + "*" not in ignore:
        ignore.append(PREFIX.rstrip(".") + "*")
    ql = qc.get("quantized_layers")
    removed = 0
    if isinstance(ql, dict):
        for k in [k for k in ql if k.startswith(PREFIX) or k in ("model.visual*", "model.visual")]:
            ql.pop(k)
            removed += 1
    with open(os.path.join(DST, "config.json"), "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print("config.json: ignore now %d entries, removed %d visual quantized_layers" % (len(ignore), removed))

    # --- index: it still maps the 166 scale twins we deleted -------------------------
    # 375,487 names, of which 499 were visual. Leave the dangling ones and a reader that
    # resolves names through the index looks up tensors that no longer exist.
    present = set(header) - {"__metadata__"}
    stale = sorted(k for k in wm if k.startswith(PREFIX) and k not in present)
    new_wm = {k: v for k, v in wm.items() if k not in set(stale)}
    index_out = {"metadata": index.get("metadata", {}), "weight_map": new_wm}
    with open(os.path.join(DST, "model.safetensors.index.json"), "w", encoding="utf-8") as f:
        json.dump(index_out, f, indent=2)
        f.write("\n")
    print("index: dropped %d stale weight_scale entries, %d -> %d names"
          % (len(stale), len(wm), len(new_wm)))
    print("\nbuilt %s" % DST)


def verify():
    ok = True

    def check(cond, label, detail=""):
        nonlocal ok
        print("  %s  %s%s" % ("PASS" if cond else "FAIL", label, "  [%s]" % detail if detail else ""))
        if not cond:
            ok = False

    print("== structure")
    cfg = json.load(open(os.path.join(DST, "config.json"), encoding="utf-8"))
    contract = expected_contract(cfg["vision_config"])
    wm = json.load(open(os.path.join(DST, "model.safetensors.index.json"), encoding="utf-8"))["weight_map"]
    src_files = {os.path.relpath(os.path.join(b, n), SRC).replace("\\", "/")
                 for b, _, fs in os.walk(SRC) for n in fs}
    dst_files = {os.path.relpath(os.path.join(b, n), DST).replace("\\", "/")
                 for b, _, fs in os.walk(DST) for n in fs}
    check(src_files == dst_files, "file set identical to the source checkpoint", "%d files" % len(dst_files))
    check(len(contract) == 333, "contract is the expected size", str(len(contract)))

    print("\n== every shard header")
    seen, shard_headers = {}, {}
    for rel in sorted({p.replace("/", os.sep) for p in wm.values()}):
        hh, _ = read_header(os.path.join(DST, rel))
        shard_headers[rel] = hh
        for k in hh:
            if k == "__metadata__":
                continue
            if k in seen:
                check(False, "%s appears in two shards" % k, "%s and %s" % (seen[k], rel))
            seen[k] = rel
    check(set(wm) == set(seen), "index and shard headers agree",
          "index-only=%d shard-only=%d" % (len(set(wm) - set(seen)), len(set(seen) - set(wm)))
          if set(wm) != set(seen) else "%d names" % len(wm))
    unresolved = sorted(k for k in wm if k not in seen)
    check(not unresolved, "every name in the index exists", "%d unresolved" % len(unresolved) if unresolved else "")

    print("\n== the loader contract")
    bad = [n for n in contract if n not in seen
           or shard_headers[seen[n]][n]["dtype"] != "BF16"
           or shard_headers[seen[n]][n]["shape"] != contract[n]]
    for n in bad[:5]:
        got = shard_headers.get(seen.get(n, ""), {}).get(n)
        check(False, n, "want BF16 %s, got %s" % (contract[n], got))
    check(not bad, "all %d tower tensors present, bf16, shapes exact" % len(contract))

    probe = PREFIX + "blocks.0.attn.qkv.weight"
    m = shard_headers[seen[probe]][probe]
    check(m["dtype"] == "BF16" and m["shape"] == [3456, 1152], "the tensor that refused to load",
          "%s %s" % (m["dtype"], m["shape"]))

    print("\n== no quantized leftovers under the prefix")
    leftovers = sorted(k for k in seen if k.startswith(PREFIX) and k not in contract)
    check(not leftovers, "no FP8 tensors or scale twins remain",
          "%d extra: %s" % (len(leftovers), leftovers[:3]) if leftovers else "clean")

    print("\n== the rewritten shard did not disturb its neighbours")
    # Compute the tower-bearing shard once. Scanning shard headers per weight_map entry
    # would be 375,487 passes over a 75,242-key dict and never finish.
    target = sorted(rel for rel, hh in shard_headers.items()
                    if any(k.startswith(PREFIX) for k in hh))[0]
    oh, _ = read_header(os.path.join(SRC, target.replace("/", os.sep)))
    nh = shard_headers[target.replace("/", os.sep)]
    differ = 0
    for name, om in oh.items():
        if name.startswith(PREFIX) or name == "__metadata__":
            continue
        nm = nh.get(name)
        if not nm or nm["dtype"] != om["dtype"] or nm["shape"] != om["shape"] or \
           nm["data_offsets"] != om["data_offsets"]:
            differ += 1
    check(differ == 0, "all %d non-visual tensors keep dtype, shape and offsets"
          % sum(1 for k in oh if not k.startswith(PREFIX) and k != "__metadata__"),
          "%d differ" % differ if differ else "")
    eq, nbytes = sections_identical(os.path.join(SRC, target.replace("/", os.sep)),
                                    os.path.join(DST, target.replace("/", os.sep)))
    check(eq, "the entire %d MiB data section is byte-identical, not just the tensors we kept"
          % (nbytes // 2**20), "diverges at byte %d" % nbytes if not eq else "")
    check(nh.get("__metadata__") == oh.get("__metadata__"), "__metadata__ preserved",
          str(nh.get("__metadata__")))

    print("\n== config agrees the tower is unquantized")
    qc = cfg.get("quantization_config") or {}
    check(any("visual" in str(i) for i in qc.get("ignore", [])), "model.visual* is in ignore",
          "%d entries" % len(qc.get("ignore", [])))
    check(not [k for k in (qc.get("quantized_layers") or {}) if k.startswith(PREFIX)],
          "no model.visual.* entries remain in quantized_layers",
          "%d left" % len([k for k in (qc.get("quantized_layers") or {}) if k.startswith(PREFIX)]))

    print("\n== the source checkpoint is untouched")
    orig = {}
    for rel in sorted({p.replace("/", os.sep) for p in json.load(
            open(os.path.join(SRC, "model.safetensors.index.json"), encoding="utf-8"))["weight_map"].values()}):
        hh, _ = read_header(os.path.join(SRC, rel))
        orig.update({k: v["dtype"] for k, v in hh.items() if k.startswith(PREFIX)})
    check(len(orig) == 499, "source still holds its 499 quantized visual tensors", str(len(orig)))
    # Exactly these four are real copies: the shard we rewrote, the config we patched,
    # the index we pruned, and the lock file the engine may itself write -- which must
    # never share an inode with the source. Everything else must be a hardlink, or this
    # would be a 95 GiB duplication.
    should_copy = {target.replace("\\", "/"), "config.json",
                   "model.safetensors.index.json"} | COPY_NOT_LINK

    def shares_inode(rel):
        s = os.path.join(SRC, rel.replace("/", os.sep))
        d = os.path.join(DST, rel.replace("/", os.sep))
        if not (os.path.isfile(s) and os.path.isfile(d)):
            return False
        a, b = os.stat(s), os.stat(d)
        return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)

    unshared = {rel for rel in src_files if not shares_inode(rel)}
    check(unshared == should_copy, "only the %d rewritten files are copies; the rest share inodes"
          % len(should_copy),
          "unexpected copies=%s missing=%s" % (sorted(unshared - should_copy), sorted(should_copy - unshared))
          if unshared != should_copy else "%d of %d hardlinked" % (len(src_files) - len(unshared), len(src_files)))

    print("\n" + ("SPLICE OK" if ok else "SPLICE HAS FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true", help="only verify an existing output")
    a = ap.parse_args()
    if not a.verify:
        build()
        print()
    sys.exit(verify())
