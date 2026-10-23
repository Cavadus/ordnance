#!/usr/bin/env python3
"""Apply an edit list to stock Helldivers 2 .dl_bin tables and reseal them.

One output file per table. Edits are record-relative. The last edit of a
field wins. This is the byte step behind src-tauri/src/compiler.
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hd2edit import (
    crypto_box_seal, crypto_box_seal_open, PK, SK,
    headers, murmur64, correct, u32, f32, put_u32, put_f32,
)

TABLES = {
    "projectile": ("generated_projectile_settings.dl_bin", 0xBD4042C2, 272),
    "explosion": ("generated_explosion_settings.dl_bin", 0x2AEA2592, 152),
    "damage": ("generated_damage_settings.dl_bin", 0xE0A72CF0, 76),
    "entities": ("generated_entities.dl_bin", None, None),
}

def open_sealed(path):
    return bytearray(crypto_box_seal_open(open(path, "rb").read(), PK, SK))

def table_base(blob, type_id):
    for at, typ, size in headers(bytes(blob)):
        if typ == type_id:
            return at, at + 24, size
    raise SystemExit(f"table {type_id:#x} not in file")

def find_record(blob, base, stride, record_id):
    rows = u32(blob, base + 8)
    for i in range(rows):
        off = base + 16 + i * stride
        if u32(blob, off) == record_id:
            return off
    raise SystemExit(f"record {record_id} not found")

def clear_header_salt(blob, at):
    if blob[at + 16] != 1:
        raise SystemExit(f"header flag at {at} is not 1")
    for k in range(17, 24):
        blob[at + k] = 0

def apply_file(stock_path, edits):
    blob = open_sealed(stock_path)
    target = murmur64(bytes(blob))
    type_id = None
    stride = None
    header_at = None
    float_offsets = []
    # group assumes one table per file; type comes from the first edit's table
    table = edits[0]["table"]
    filename, type_id, stride = TABLES[table]
    if type_id is None:
        raise SystemExit(f"{table} apply is not wired yet")
    header_at, base, size = table_base(blob, type_id)
    for edit in edits:
        if edit["table"] != table:
            raise SystemExit("mixed tables in one file apply")
        rec = find_record(blob, base, stride, int(edit["record"]))
        off = rec + int(edit["offset"])
        kind = edit["kind"]
        if kind == "f32":
            put_f32(blob, off, float(edit["value"]))
            float_offsets.append(off)
        elif kind == "u32":
            put_u32(blob, off, int(edit["value"]) & 0xFFFFFFFF)
        else:
            raise SystemExit(f"bad kind {kind}")
    clear_header_salt(blob, header_at)
    correct(blob, target, float_offsets or None)
    if murmur64(blob) != target:
        raise SystemExit("hash correction failed")
    sealed = crypto_box_seal(bytes(blob), PK)
    check = crypto_box_seal_open(sealed, PK, SK)
    if murmur64(check) != target:
        raise SystemExit("reseal did not round-trip")
    return sealed, blob, base, stride

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("edits_json")
    ap.add_argument("--stock", required=True, help="directory of stock .dl_bin files")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    edits = json.load(open(args.edits_json))
    by_table = {}
    for edit in edits:
        by_table.setdefault(edit["table"], []).append(edit)
    os.makedirs(args.out, exist_ok=True)
    for table, group in by_table.items():
        filename = TABLES[table][0]
        sealed, blob, base, stride = apply_file(os.path.join(args.stock, filename), group)
        dest = os.path.join(args.out, filename)
        open(dest, "wb").write(sealed)
        # report the records we touched
        print(f"wrote {dest} ({len(sealed)} bytes)")
        for edit in group:
            rec = find_record(blob, base, stride, int(edit["record"]))
            off = rec + int(edit["offset"])
            shown = f32(blob, off) if edit["kind"] == "f32" else u32(blob, off)
            print(f"  {table} record {int(edit['record'])} +{edit['offset']} = {shown}")

if __name__ == "__main__":
    main()
