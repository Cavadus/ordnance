#!/usr/bin/env python3
"""Merge several boot-script patches into one Helldivers 2 script.

The game runs one file for resource ``9ba626afa44a3aa3`` (Lua type
``0xA14E8DFA2CD117E2``). A later ``.patch_N`` of that name replaces the
earlier one, so two mods that each ship a full script cannot both load.

This joins them:

* An HD2FM installer that assigns ``shutdown = finish`` is rewritten to
  call the callbacks that were already there, then placed first.
* Every other Lua source is wrapped in its own function so a top-level
  ``return`` cannot skip the next mod.
* A Bingus option module whose body is only ``return true`` or
  ``return false`` is not a boot script. Emitting it under the boot-script
  name would replace every other script, so it is left out of the patch.
"""
import argparse
import json
import os
import struct
import sys

MAGIC = 0xF0000011
LUA_TYPE = bytes.fromhex("e217d12cfa8d4ea1")
BOOT_NAME = "9ba626afa44a3aa3"
HEADER = 192
SOURCE_AT = 200

CLOBBER = (
    "init = function() end\n"
    "update = function() end\n"
    "render = function() end\n"
    "shutdown = finish\n"
)
CHAINED = (
    "local _ord_init, _ord_update, _ord_render, _ord_shutdown = init, update, render, shutdown\n"
    "init = function(...)\n"
    "    if _ord_init then return _ord_init(...) end\n"
    "end\n"
    "update = function(...)\n"
    "    if _ord_update then return _ord_update(...) end\n"
    "end\n"
    "render = function(...)\n"
    "    if _ord_render then return _ord_render(...) end\n"
    "end\n"
    "shutdown = function(...)\n"
    "    finish()\n"
    "    if _ord_shutdown then return _ord_shutdown(...) end\n"
    "end\n"
)

# Folder name -> (require path, value). These are Bingus option modules.
# The boot script never loads them; Transmog reads them by require path.
OPTION_SETTINGS = {
    "HelmetOn": ("mods/hd2transmog/options/helmet_transmog", True),
    "HelmetOff": ("mods/hd2transmog/options/helmet_transmog", False),
    "PassiveIconsOn": ("mods/hd2transmog/options/passive_preview_icons", True),
    "PassiveIconsOff": ("mods/hd2transmog/options/passive_preview_icons", False),
    "IndependentStats": ("mods/hd2transmog/options/stats_follow_look", False),
    "LookStats": ("mods/hd2transmog/options/stats_follow_look", True),
}


class BootMergeError(Exception):
    pass


def _u32(buf, at):
    return struct.unpack_from("<I", buf, at)[0]


def _u64(buf, at):
    return struct.unpack_from("<Q", buf, at)[0]


def extract_source(patch):
    """Return the Lua bytes from a single-payload Lua patch."""
    if len(patch) < SOURCE_AT + 4 or _u32(patch, 0) != MAGIC or _u32(patch, 4) != 1:
        raise BootMergeError("not a single-payload patch")
    if patch[0x50:0x58] != LUA_TYPE:
        raise BootMergeError("patch type is not Lua")
    size = _u32(patch, 0xC0)
    if _u32(patch, HEADER) != size:
        raise BootMergeError("Lua size fields disagree")
    if SOURCE_AT + size > len(patch):
        raise BootMergeError("Lua size runs past the file")
    return bytes(patch[SOURCE_AT:SOURCE_AT + size])


def pack_source(prototype, source):
    """Rebuild a patch from the first 192 header bytes and a Lua source."""
    if len(prototype) < HEADER:
        raise BootMergeError("header shorter than 192 bytes")
    if b"\0" in source:
        raise BootMergeError("refusing to pack a source that contains NUL")
    pad = (-(SOURCE_AT + len(source))) % 16
    total = SOURCE_AT + len(source) + pad
    header = bytearray(prototype[:HEADER])
    struct.pack_into("<Q", header, 0x20, total)
    struct.pack_into("<I", header, 0xA0, len(source) + 8)
    payload = struct.pack("<II", len(source), 2) + source + (b"\0" * pad)
    out = bytes(header) + payload
    if len(out) != total or _u64(out, 0x20) != total:
        raise BootMergeError("repacked size does not match the header")
    if extract_source(out) != source:
        raise BootMergeError("repacked source does not round-trip")
    return out


def _strip_lua_comments(text):
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("--", i):
            if text.startswith("--[[", i) or text.startswith("--[=[", i):
                close = text.find("]]", i + 4)
                i = n if close < 0 else close + 2
            else:
                nl = text.find("\n", i)
                i = n if nl < 0 else nl
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def classify(source):
    """``installer``, ``script``, ``config``, or ``binary``."""
    if b"\0" in source:
        return "binary"
    try:
        text = source.decode("utf-8")
    except UnicodeDecodeError:
        return "binary"
    body = " ".join(_strip_lua_comments(text).split())
    if body in ("return true", "return false"):
        return "config"
    if CLOBBER in text or ("HD2FM1" in text and "shutdown = finish" in text):
        return "installer"
    return "script"


def chain_installer(text):
    if CLOBBER not in text:
        if "shutdown = finish" in text and CHAINED not in text:
            raise BootMergeError("installer clobbers shutdown in an unrecognized shape")
        return text
    if text.count(CLOBBER) != 1:
        raise BootMergeError("installer clobber block is not unique")
    return text.replace(CLOBBER, CHAINED, 1)


def _option_pin(name):
    for folder, (path, value) in OPTION_SETTINGS.items():
        if name == folder or name.endswith("/" + folder) or name.endswith("\\" + folder):
            return path, value
    return None


def _wrap(index, source):
    # The main chunk's varargs are forwarded. A return inside the source
    # leaves this function and does not abandon the rest of the boot script.
    return (
        "do\n"
        "local function _ordnance_mod_%d(...)\n" % index
        + source.decode("utf-8")
        + "\nend\n"
        "_ordnance_mod_%d(...)\n" % index
        + "end\n"
    )


def merge_sources(pieces):
    """Join ``(name, patch_bytes)`` in load order.

    Returns ``(patch_bytes, report)``. ``report`` has ``order``,
    ``skipped`` (config modules left out of the boot slot), and ``pins``
    (option require-path, value) for configs this compiler knows.
    """
    if not pieces:
        raise BootMergeError("no patches to merge")
    classified = []
    skipped = []
    pins = []
    seen_pin = {}
    prototype = None
    for name, patch in pieces:
        source = extract_source(patch)
        kind = classify(source)
        if kind == "binary":
            raise BootMergeError("%s is a Lua-typed patch with a binary payload, not a boot script" % name)
        if prototype is None:
            prototype = patch
        if kind == "config":
            skipped.append(name)
            pin = _option_pin(name)
            if pin:
                path, value = pin
                if path in seen_pin and seen_pin[path] != value:
                    raise BootMergeError("option %s is both true and false" % path)
                seen_pin[path] = value
                pins.append((name, path, value))
            continue
        text = source.decode("utf-8")
        if kind == "installer":
            text = chain_installer(text)
            source = text.encode("utf-8")
        classified.append((name, kind, source))
    if not classified and not pins:
        raise BootMergeError("nothing left after removing option modules")
    installers = [row for row in classified if row[1] == "installer"]
    rest = [row for row in classified if row[1] != "installer"]
    ordered = installers + rest
    parts = [
        "-- Ordnance boot script. %d mods, one resource. Do not stack another 9ba626 patch over this.\n"
        % len(ordered)
    ]
    if pins:
        # The game's boot environment may not have package. Skip the pin
        # then; the option modules were not part of the boot slot anyway.
        lines = [
            "do",
            "local pkg = rawget(_G, 'package')",
            "if type(pkg) == 'table' then",
            "pkg.preload = pkg.preload or {}",
        ]
        for _, path, value in pins:
            literal = "true" if value else "false"
            lines.append("pkg.preload['%s'] = function() return %s end" % (path, literal))
        lines.append("end")
        lines.append("end")
        parts.append("\n".join(lines) + "\n")
    order = []
    for index, (name, _kind, source) in enumerate(ordered, start=1):
        parts.append(_wrap(index, source))
        order.append(name)
    merged = "".join(parts).encode("utf-8")
    patch = pack_source(prototype, merged)
    return patch, {"order": order, "skipped": skipped, "pins": pins}


def main():
    ap = argparse.ArgumentParser(description="Merge boot-script patches into one file.")
    ap.add_argument("--boot", action="append", default=[], help="name=path, in load order")
    ap.add_argument("--list", help="JSON array of {name, path}, in load order")
    ap.add_argument("--copy", action="append", default=[], help="path of a non-boot patch to copy unchanged")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    pieces = []
    if args.list:
        for item in json.loads(open(args.list, encoding="utf-8").read()):
            pieces.append((item["name"], open(item["path"], "rb").read()))
    for item in args.boot:
        name, path = item.split("=", 1)
        pieces.append((name, open(path, "rb").read()))
    patch, report = merge_sources(pieces)
    os.makedirs(args.out, exist_ok=True)
    dest = os.path.join(args.out, BOOT_NAME + ".patch_0")
    open(dest, "wb").write(patch)
    for path in args.copy:
        target = os.path.join(args.out, os.path.basename(path))
        open(target, "wb").write(open(path, "rb").read())
        print("copied %s" % os.path.basename(path))
    print("boot %s (%d bytes)" % (dest, len(patch)))
    print("order: %s" % " | ".join(report["order"]))
    if report["skipped"]:
        print("left out of the boot slot: %s" % " | ".join(report["skipped"]))
    for name, path, value in report["pins"]:
        print("pin %s = %s from %s" % (path, value, name))


if __name__ == "__main__":
    try:
        main()
    except BootMergeError as exc:
        sys.exit(str(exc))
