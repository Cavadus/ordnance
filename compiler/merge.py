#!/usr/bin/env python3
"""Merge several .dl_bin swap mods into one sealed file per table.

Each mod ships a whole sealed file. Ordnance opens stock and each mod,
keeps the bytes that differ from stock, and paints them onto one copy in
mod order. A later mod wins where two edits cover the same byte. Header
hash-salt bytes are ignored, then the merged file is hash-corrected and
resealed. The result is one install, not one file pasted over another.
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hd2edit import (
    crypto_box_seal, crypto_box_seal_open, PK, SK,
    headers, murmur64, correct,
)

TABLES = [
    "generated_projectile_settings.dl_bin",
    "generated_explosion_settings.dl_bin",
    "generated_damage_settings.dl_bin",
    "generated_entities.dl_bin",
]

def open_sealed(path):
    return bytearray(crypto_box_seal_open(open(path, "rb").read(), PK, SK))

def salt_spans(blob):
    spans = []
    for at, typ, size in headers(bytes(blob)):
        spans.append((at + 17, at + 24))
    return spans

def in_spans(i, spans):
    return any(a <= i < b for a, b in spans)

def diff_bytes(stock, mod):
    if len(stock) != len(mod):
        raise SystemExit(f"length mismatch {len(stock)} vs {len(mod)}")
    spans = salt_spans(stock)
    ranges = []
    i = 0
    n = len(stock)
    while i < n:
        if stock[i] != mod[i] and not in_spans(i, spans):
            j = i + 1
            while j < n and stock[j] != mod[j] and not in_spans(j, spans):
                j += 1
            ranges.append((i, bytes(mod[i:j])))
            i = j
        else:
            i += 1
    return ranges

def merge_table(stock_path, mod_paths):
    stock = open_sealed(stock_path)
    target = murmur64(bytes(stock))
    merged = bytearray(stock)
    owner = [None] * len(stock)
    conflicts = []
    for name, path in mod_paths:
        mod = open_sealed(path)
        for start, data in diff_bytes(stock, mod):
            for k, byte in enumerate(data):
                at = start + k
                prev = owner[at]
                if prev is not None and prev != name:
                    conflicts.append((at, prev, name))
                merged[at] = byte
                owner[at] = name
    # one conflict record per losing mod, not per byte
    clash = {}
    for at, prev, name in conflicts:
        clash.setdefault((prev, name), 0)
        clash[(prev, name)] += 1
    changed_at = [i for i, o in enumerate(owner) if o is not None]
    float_offsets = [i for i in changed_at if i % 4 == 0]
    hs = headers(bytes(merged))
    for at, typ, size in hs:
        if merged[at + 16] != 1:
            raise SystemExit("bad header flag")
        for k in range(17, 24):
            merged[at + k] = 0
    correct(merged, target, float_offsets or None)
    if murmur64(merged) != target:
        raise SystemExit("hash correction failed")
    sealed = crypto_box_seal(bytes(merged), PK)
    check = crypto_box_seal_open(sealed, PK, SK)
    if murmur64(check) != target:
        raise SystemExit("reseal failed")
    return sealed, clash, sum(1 for o in owner if o)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock", required=True)
    ap.add_argument("--mod", action="append", required=True, help="name=directory, in load order")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    mods = []
    for item in args.mod:
        name, path = item.split("=", 1)
        mods.append((name, path))
    os.makedirs(args.out, exist_ok=True)
    for filename in TABLES:
        present = [(name, os.path.join(path, filename)) for name, path in mods if os.path.isfile(os.path.join(path, filename))]
        if not present:
            continue
        stock_path = os.path.join(args.stock, filename)
        sealed, clash, changed = merge_table(stock_path, present)
        dest = os.path.join(args.out, filename)
        open(dest, "wb").write(sealed)
        print(f"{filename}: {len(present)} mods, {changed} bytes changed, {len(clash)} clashes")
        for (loser, winner), n in clash.items():
            print(f"  clash {loser} -> {winner} ({n} bytes)")

if __name__ == "__main__":
    main()
