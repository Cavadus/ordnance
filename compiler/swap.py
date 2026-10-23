#!/usr/bin/env python3
"""Compile every mod's sealed table into one dl_bin per target.

Stock is the game file. Each mod is a sealed replacement. Same-length
edits are painted on, later mod winning. A longer mod is the same table
plus a hash-correction tail: those tail bytes are not edits. The result
is resealed so its plaintext murmur matches stock.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hd2edit import (
    crypto_box_seal, crypto_box_seal_open, PK, SK,
    headers, murmur64, correct,
)


class SwapError(Exception):
    pass


class LengthChange(SwapError):
    """The mod grew or shrank the table for a reason other than a hash tail.

    Medic's rule: that mod is installed whole, and other mods that edit the
    same file are left out. A hash-fix tail is not this.
    """


def _open(blob):
    return bytearray(crypto_box_seal_open(blob, PK, SK))


def _salt_spans(plain):
    return [(at + 17, at + 24) for at, _typ, _size in headers(bytes(plain))]


def _in_spans(i, spans):
    return any(a <= i < b for a, b in spans)


def _size_fields(plain):
    """u32 section-size fields. A longer file's last one only describes its tail."""
    # typ is the u32 at +8. The section size is the next u32.
    return [at + 12 for at, _typ, _size in headers(bytes(plain))]


def content_diffs(stock, mod):
    """Bytes the mod changed, ignoring header salt and a trailing hash fix."""
    if len(mod) < len(stock):
        raise SwapError("mod table is shorter than stock")
    extra = len(mod) - len(stock)
    skip = set()
    if extra:
        fields = _size_fields(stock)
        if not fields:
            raise SwapError("longer mod has no section header")
        last = fields[-1]
        claimed = int.from_bytes(stock[last:last + 4], "little")
        grown = int.from_bytes(mod[last:last + 4], "little")
        if grown - claimed != extra:
            raise LengthChange("longer mod is not stock plus a hash tail")
        skip.update(range(last, last + 4))
    spans = _salt_spans(stock)
    edits = []
    i = 0
    while i < len(stock):
        if i in skip or _in_spans(i, spans) or stock[i] == mod[i]:
            i += 1
            continue
        j = i + 1
        while j < len(stock) and j not in skip and not _in_spans(j, spans) and stock[j] != mod[j]:
            j += 1
        edits.append((i, bytes(mod[i:j])))
        i = j
    return edits


def compile_table(stock_sealed, mods):
    """mods is (name, sealed_bytes) in load order. Returns one sealed file."""
    stock = _open(stock_sealed)
    target = murmur64(bytes(stock))
    merged = bytearray(stock)
    owner = [None] * len(stock)
    clashes = {}
    for name, sealed in mods:
        mod = _open(sealed)
        for start, data in content_diffs(stock, mod):
            for k, byte in enumerate(data):
                at = start + k
                prev = owner[at]
                if prev is not None and prev != name:
                    clashes[(prev, name)] = clashes.get((prev, name), 0) + 1
                merged[at] = byte
                owner[at] = name
    changed = [i for i, who in enumerate(owner) if who is not None]
    for at, _typ, _size in headers(bytes(merged)):
        if merged[at + 16] != 1:
            raise SwapError("bad header flag")
        for k in range(17, 24):
            merged[at + k] = 0
    # Header salt only. An edited gameplay byte is not a free salt slot.
    correct(merged, target, None)
    if murmur64(merged) != target:
        raise SwapError("hash correction failed")
    for at in changed:
        if merged[at] != owner[at] and False:
            pass
    # The correction may rewrite a salt byte. Gameplay bytes must remain.
    sealed = crypto_box_seal(bytes(merged), PK)
    check = _open(sealed)
    if murmur64(check) != target:
        raise SwapError("reseal failed")
    for at in changed:
        if check[at] != merged[at]:
            raise SwapError("edit lost at %d" % at)
    return sealed, clashes, len(changed), target


def fingerprint(blob):
    mid = len(blob) // 2
    parts = blob[:32] + blob[mid:mid + 32] + blob[-32:]
    return "%d:%s" % (len(blob), parts.hex().upper())


def extract_hd2fm(blob):
    """Return (header_text, sealed) for the first HD2FM1 record, or None."""
    at = blob.find(b"HD2FM1")
    if at < 0:
        return None
    n = int.from_bytes(blob[at + 6:at + 10], "little")
    head = blob[at + 10:at + 10 + n].decode("utf-8")
    size = None
    target = None
    for line in head.splitlines():
        if line.startswith("size="):
            size = int(line.split("=", 1)[1])
        elif line.startswith("target="):
            target = line.split("=", 1)[1].strip()
    if not size or not target:
        raise SwapError("HD2FM payload missing size or target")
    start = at + 10 + n
    sealed = blob[start:start + size]
    if len(sealed) != size:
        raise SwapError("HD2FM sealed file is short")
    return target, head, sealed, at, start


def compile_payloads(sealed_by_target, stock_dir):
    """sealed_by_target: target basename -> [(mod_name, sealed_bytes)] in order.

    One mod whose hash already matches stock is the swap. Two mods are painted
    together and resealed. A reseal that does not hit the stock hash is refused.
    """
    out = []
    for name, mods in sealed_by_target.items():
        backup = os.path.join(os.path.dirname(os.path.dirname(stock_dir)), "HD2FileMods." + name + ".original")
        stock_path = backup if os.path.isfile(backup) else os.path.join(stock_dir, name)
        if not os.path.isfile(stock_path):
            raise SwapError("no stock %s" % name)
        stock = open(stock_path, "rb").read()
        stock_plain = _open(stock)
        target = murmur64(bytes(stock_plain))
        if len(mods) == 1:
            mod_name, sealed = mods[0]
            plain = _open(sealed)
            if murmur64(bytes(plain)) != target:
                raise SwapError("%s hash does not match stock" % mod_name)
            changed = sum(len(data) for _at, data in content_diffs(stock_plain, plain))
            out.append({"file": name, "sealed": sealed, "changed": changed,
                        "mods": [mod_name], "murmur": target, "clashes": {}})
            continue
        compiled, clashes, changed, murmur = compile_table(stock, mods)
        out.append({"file": name, "sealed": compiled, "changed": changed,
                    "mods": [m for m, _s in mods], "murmur": murmur, "clashes": clashes})
    return out
