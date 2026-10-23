#!/usr/bin/env python3
"""Deploy the enabled Ordnance profile into a game data directory.

Text Lua patches of 9ba626afa44a3aa3 are merged first. Everything else is
copied in profile order. This is the same rule Deploy uses.
"""
import argparse
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bootmerge
import swap

BOOT = bootmerge.BOOT_NAME


def load_manifest(path):
    try:
        return json.load(open(path, encoding="utf-8"))
    except ValueError as exc:
        raise SystemExit("unreadable manifest %s: %s" % (path, exc))


def mods_by_guid(mods_root):
    found = {}
    for name in sorted(os.listdir(mods_root)):
        folder = os.path.join(mods_root, name)
        man_path = os.path.join(folder, "manifest.json")
        if not os.path.isfile(man_path):
            continue
        try:
            man = json.load(open(man_path, encoding="utf-8"))
        except ValueError as exc:
            print("skip %s: %s" % (name, exc), file=sys.stderr)
            continue
        guid = (man.get("Guid") or man.get("guid") or "").lower()
        if guid:
            found[guid] = (folder, man)
    return found


def resolve_include(folder, relative):
    """Match Include paths the way Ordnance does: backslashes and any case."""
    relative = relative.replace("\\", "/").strip("/")
    current = folder
    for piece in relative.split("/"):
        if piece in ("", "."):
            continue
        if not os.path.isdir(current):
            return os.path.join(folder, relative)
        names = os.listdir(current)
        exact = next((n for n in names if n == piece), None)
        chosen = exact or next((n for n in names if n.lower() == piece.lower()), None)
        if chosen is None:
            return os.path.join(folder, relative)
        current = os.path.join(current, chosen)
    return current


def enabled_dirs(folder, man, config):
    if not config.get("Enabled", True):
        return []
    options = man.get("Options") or []
    if not options:
        return [folder]
    toggled = config.get("Toggled") or []
    selected = config.get("Selected") or []
    dirs = []
    for i, opt in enumerate(options):
        if i >= len(toggled) or not toggled[i]:
            continue
        for inc in opt.get("Include") or []:
            dirs.append(resolve_include(folder, inc))
        subs = opt.get("SubOptions") or []
        if subs and i < len(selected):
            idx = selected[i]
            if 0 <= idx < len(subs):
                for inc in subs[idx].get("Include") or []:
                    dirs.append(resolve_include(folder, inc))
    return dirs


def patch_files(directory):
    if not os.path.isdir(directory):
        raise SystemExit("enabled option folder is missing: %s" % directory)
    out = []
    for name in sorted(os.listdir(directory)):
        if ".patch_" not in name:
            continue
        out.append(os.path.join(directory, name))
    return out


def prefix_of(path):
    name = os.path.basename(path)
    return name[:16]


def index_of(path):
    name = os.path.basename(path)
    mid = name.split(".patch_")[1]
    digits = []
    for ch in mid:
        if ch.isdigit():
            digits.append(ch)
        else:
            break
    return int("".join(digits) or "0")


def is_sidecar(path):
    name = os.path.basename(path)
    return name.endswith(".gpu_resources") or name.endswith(".stream")


def collect(mods_root, profile_path):
    prof = json.load(open(profile_path, encoding="utf-8"))
    active = prof["Profiles"][prof["Active"]]
    library = mods_by_guid(mods_root)
    groups = {}
    order = []
    for config in active["Configs"]:
        guid = config["Guid"].lower()
        if guid not in library:
            print("skip unknown guid %s" % guid, file=sys.stderr)
            continue
        folder, man = library[guid]
        for directory in enabled_dirs(folder, man, config):
            files = patch_files(directory)
            # Keep a mod's own patch_0 before patch_1.
            files.sort(key=lambda p: (prefix_of(p), index_of(p), os.path.basename(p)))
            for path in files:
                if is_sidecar(path):
                    continue
                key = prefix_of(path)
                groups.setdefault(key, [])
                groups[key].append(path)
                order.append(path)
    return groups


def fold_boot(groups):
    paths = groups.get(BOOT, [])
    boot = []
    rest = []
    for path in paths:
        try:
            source = bootmerge.extract_source(open(path, "rb").read())
        except bootmerge.BootMergeError:
            rest.append(path)
            continue
        kind = bootmerge.classify(source)
        if kind == "binary":
            rest.append(path)
        else:
            name = os.path.basename(os.path.dirname(path))
            boot.append((name, path))
    if len(boot) < 2:
        return None
    pieces = [(name, open(path, "rb").read()) for name, path in boot]
    patch, report = bootmerge.merge_sources(pieces)
    handle = tempfile.NamedTemporaryFile(prefix="ordnance-boot-", suffix=".patch_0", delete=False)
    handle.write(patch)
    handle.close()
    groups[BOOT] = [handle.name] + rest
    return handle.name, report


def siblings(src):
    gpu = src + ".gpu_resources"
    stream = src + ".stream"
    return gpu if os.path.isfile(gpu) else None, stream if os.path.isfile(stream) else None


def table_swaps(groups, stock_dir):
    """Every HD2FM payload becomes one sealed file per target table."""
    by_target = {}
    owners = {}
    for paths in groups.values():
        for path in paths:
            blob = open(path, "rb").read()
            found = swap.extract_hd2fm(blob)
            if not found:
                continue
            target, _head, sealed, _at, _start = found
            name = os.path.basename(target)
            mod = os.path.basename(os.path.dirname(path))
            by_target.setdefault(name, []).append((mod, sealed))
            owners.setdefault(name, []).append(path)
    if not by_target:
        return []
    return swap.compile_payloads(by_target, stock_dir)


def deploy(mods_root, profile_path, data_dir):
    groups = collect(mods_root, profile_path)
    folded = fold_boot(groups)
    game_tables = os.path.join(os.path.dirname(data_dir), "game")
    swaps = table_swaps(groups, game_tables)
    os.makedirs(data_dir, exist_ok=True)
    # Purge previous patch files so a higher leftover index cannot hide the new set.
    for name in os.listdir(data_dir):
        if ".patch_" in name or name == ".ddmm-deployed.json":
            os.remove(os.path.join(data_dir, name))
    written = []
    for key, paths in groups.items():
        for index, src in enumerate(paths):
            dest = os.path.join(data_dir, "%s.patch_%d" % (key, index))
            shutil.copyfile(src, dest)
            written.append(dest)
            gpu, stream = siblings(src) if not src.startswith(tempfile.gettempdir()) else (None, None)
            for suffix, side in ((".gpu_resources", gpu), (".stream", stream)):
                target = dest + suffix
                if side:
                    shutil.copyfile(side, target)
                else:
                    open(target, "wb").close()
                written.append(target)
    if folded:
        os.unlink(folded[0])
    for row in swaps:
        dest = os.path.join(game_tables, row["file"])
        if os.path.isfile(dest) and open(dest, "rb").read() == row["sealed"]:
            continue
        open(dest, "wb").write(row["sealed"])
    return folded, written, swaps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mods", required=True)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--data", required=True)
    args = ap.parse_args()
    folded, written, swaps = deploy(args.mods, args.profile, args.data)
    print("wrote %d files into %s" % (len(written), args.data))
    for row in swaps:
        print("swap %s: %s, %d bytes, hash %x" % (
            row["file"], ", ".join(row["mods"]), row["changed"], row["murmur"]))
    if folded:
        _path, report = folded
        print("boot order: %s" % " | ".join(report["order"]))
        if report["skipped"]:
            print("option modules left out: %s" % " | ".join(report["skipped"]))
    else:
        print("boot: no merge, fewer than two text scripts")


if __name__ == "__main__":
    main()
