#!/usr/bin/env python3
"""Apply a field-level edit PLAN to stock .dl_bin tables and reseal.

Plans are self-describing: each edit names its "file", section "type" and
geometry ("buckets" + "stride" for keyed tables, "stride" for row tables).
Ordnance carries no knowledge of game tables; a wrong layout is the plan
author's bug.
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hd2edit import (
    crypto_box_seal, crypto_box_seal_open, PK, SK,
    headers, murmur64, correct, u32, f32, put_u32, put_f32, rd64,
)


def hx(v):
    return v if isinstance(v, int) else int(v, 0)

def open_sealed(path):
    return bytearray(crypto_box_seal_open(open(path, "rb").read(), PK, SK))

def req(e, key):
    """Table geometry the plan's author must supply (Ordnance knows no layouts)."""
    if e.get(key) is None:
        raise SystemExit('stat-plan edit is missing "%s" (plans must carry their own table layout)' % key)
    return hx(e[key])

def find_record(blob, base, stride, rid):
    for i in range(u32(blob, base + 8)):
        o = base + 16 + i * stride
        if u32(blob, o) == rid:
            return o
    raise SystemExit("record %d not found" % rid)

def find_keyed(blob, tid, lo, hi, buckets, stride):
    for at, t, s in headers(bytes(blob)):
        if t == tid:
            base = at + 24
            for k in range(buckets):
                e = base + k * 16
                if u32(blob, e) == lo and u32(blob, e + 4) == hi:
                    return base + buckets * 16 + u32(blob, e + 8) * stride
            raise SystemExit("entity not found in %x" % tid)
    raise SystemExit("table %x not found" % tid)

def do_op(blob, off, op, kind, value, floats):
    if op == "set":
        if kind == "f32":
            put_f32(blob, off, float(value)); floats.append(off)
        else:
            put_u32(blob, off, hx(value) & 0xFFFFFFFF)
    elif op == "mul":
        if kind == "u32":
            put_u32(blob, off, max(0, min(0xFFFFFFFF, round(u32(blob, off) * float(value)))))
        else:
            put_f32(blob, off, f32(blob, off) * float(value)); floats.append(off)
    elif op == "add":
        if kind == "u32":
            put_u32(blob, off, max(0, min(0xFFFFFFFF, u32(blob, off) + round(float(value)))))
        else:
            put_f32(blob, off, f32(blob, off) + float(value)); floats.append(off)
    else:
        raise SystemExit("bad op " + op)

def apply_plan(stock_dir, plan, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    groups = {}
    for e in plan:
        key = e.get("file", "")
        if not key and "table" in e:
            raise SystemExit("legacy stat-plan edit (\"table\" without \"file\"): the mod's author must update it to the self-describing format")
        if not key or "/" in key or "\\" in key or ".." in key or not key.endswith(".dl_bin"):
            raise SystemExit("stat-plan edit has a missing or invalid \"file\": %r" % (key,))
        groups.setdefault(key, []).append(e)
    for filename, edits in groups.items():
        blob = open_sealed(os.path.join(stock_dir, filename))
        target = murmur64(bytes(blob))
        floats = []
        header_ats = [at for at, _t, _s in headers(bytes(blob))]
        for e in edits:
            table = e.get("file", "")
            if "lo" in e:
                rec = find_keyed(blob, hx(e["type"]), hx(e["lo"]), hx(e["hi"]), req(e, "buckets"), req(e, "stride"))
                do_op(blob, rec + int(e["offset"]), e["op"], e["kind"], e["value"], floats)
            elif e["op"] == "clone":
                tid, stride = req(e, "type"), req(e, "stride")
                base = next(at + 24 for at, t, s in headers(bytes(blob)) if t == tid)
                src = find_record(blob, base, stride, hx(e["src"]))
                dst = find_record(blob, base, stride, hx(e["dst"]))
                src_ptr = rd64(blob, src + 40); dst_ptr = rd64(blob, dst + 40)
                clone = bytearray(blob[src:src + stride])
                put_u32(clone, 0, hx(e["dst"]))
                for k, v in e["fields"].items():
                    put_f32(clone, int(k), float(v)); floats.append(dst + int(k))
                clone[40:48] = blob[dst + 40:dst + 48]
                blob[dst:dst + stride] = clone
                blob[base + dst_ptr:base + dst_ptr + 8] = blob[base + src_ptr:base + src_ptr + 8]
            else:
                tid, stride = req(e, "type"), req(e, "stride")
                base = next(at + 24 for at, t, s in headers(bytes(blob)) if t == tid)
                rec = find_record(blob, base, stride, hx(e["record"]))
                do_op(blob, rec + int(e["offset"]), e["op"], e["kind"], e["value"], floats)
        for at in header_ats:
            if blob[at + 16] != 1: raise SystemExit("bad header flag")
            for k in range(17, 24): blob[at + k] = 0
        correct(blob, target, floats or None)
        if murmur64(blob) != target: raise SystemExit("hash correction failed: " + filename)
        sealed = bytes(crypto_box_seal(bytes(blob), PK))
        if murmur64(crypto_box_seal_open(sealed, PK, SK)) != target: raise SystemExit("round trip failed: " + filename)
        open(os.path.join(out_dir, filename), "wb").write(sealed)
        print("wrote " + filename)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("plan_json"); ap.add_argument("--stock", required=True); ap.add_argument("--out", required=True)
    a = ap.parse_args()
    apply_plan(a.stock, json.load(open(a.plan_json)), a.out)
