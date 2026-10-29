#!/usr/bin/env python3
"""Apply a field-level edit PLAN to stock .dl_bin tables and reseal."""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hd2edit import (
    crypto_box_seal, crypto_box_seal_open, PK, SK,
    headers, murmur64, correct, u32, f32, put_u32, put_f32, rd64,
)

TABLES = {
    "projectile": ("generated_projectile_settings.dl_bin", 0xBD4042C2, 272),
    "explosion": ("generated_explosion_settings.dl_bin", 0x2AEA2592, 152),
    "damage": ("generated_damage_settings.dl_bin", 0xE0A72CF0, 76),
}
KEYED = {0x88E4DBB1: (746, 1240), 0xFB8D88A3: (560, 160), 0x4F2CF417: (386, 32)}

def hx(v):
    return v if isinstance(v, int) else int(v, 0)

def open_sealed(path):
    return bytearray(crypto_box_seal_open(open(path, "rb").read(), PK, SK))

def find_record(blob, base, stride, rid):
    for i in range(u32(blob, base + 8)):
        o = base + 16 + i * stride
        if u32(blob, o) == rid:
            return o
    raise SystemExit("record %d not found" % rid)

def find_keyed(blob, tid, lo, hi):
    for at, t, s in headers(bytes(blob)):
        if t == tid:
            buckets, stride = KEYED[tid]
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
        put_f32(blob, off, f32(blob, off) * float(value)); floats.append(off)
    elif op == "add":
        put_f32(blob, off, f32(blob, off) + float(value)); floats.append(off)
    else:
        raise SystemExit("bad op " + op)

def apply_plan(stock_dir, plan, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    groups = {}
    for e in plan:
        key = "generated_entities.dl_bin" if e["table"] == "entities" else TABLES[e["table"]][0]
        groups.setdefault(key, []).append(e)
    for filename, edits in groups.items():
        blob = open_sealed(os.path.join(stock_dir, filename))
        target = murmur64(bytes(blob))
        floats = []
        header_ats = [at for at, _t, _s in headers(bytes(blob))]
        for e in edits:
            table = e["table"]
            if table == "entities":
                rec = find_keyed(blob, hx(e["type"]), hx(e["lo"]), hx(e["hi"]))
                do_op(blob, rec + int(e["offset"]), e["op"], e["kind"], e["value"], floats)
            elif e["op"] == "clone":
                _fn, tid, stride = TABLES[table]
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
                _fn, tid, stride = TABLES[table]
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
