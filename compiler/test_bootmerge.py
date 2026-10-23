#!/usr/bin/env python3
"""Boot-script merge: one resource, every mod's source still present."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bootmerge

LUA_TYPE = bootmerge.LUA_TYPE


def pack(source, addon=b"\x11" * 8):
    raw = source.encode("utf-8")
    pad = (-(bootmerge.SOURCE_AT + len(raw))) % 16
    total = bootmerge.SOURCE_AT + len(raw) + pad
    header = bytearray(bootmerge.HEADER)
    struct.pack_into("<I", header, 0, bootmerge.MAGIC)
    struct.pack_into("<I", header, 4, 1)
    struct.pack_into("<I", header, 8, 1)
    struct.pack_into("<Q", header, 0x20, total)
    header[0x50:0x58] = LUA_TYPE
    header[0x68:0x70] = addon
    header[0x70:0x78] = LUA_TYPE
    struct.pack_into("<I", header, 0xA0, len(raw) + 8)
    body = bytes(header) + struct.pack("<II", len(raw), 2) + raw + (b"\0" * pad)
    return body


class BootMergeTests(unittest.TestCase):
    def test_installer_chains_and_a_later_return_does_not_drop_the_next_mod(self):
        installer = (
            "local MAGIC = \"HD2FM1\"\n"
            "local function finish() ended = (ended or 0) + 1 end\n"
            + bootmerge.CLOBBER
        )
        early = "if rawget(_G, 'gone') then return end\nseen_early = true\n"
        late = "seen_late = true\n"
        patch, report = bootmerge.merge_sources([
            ("early", pack(early)),
            ("installer", pack(installer)),
            ("late", pack(late)),
        ])
        text = bootmerge.extract_source(patch).decode("utf-8")
        self.assertEqual(report["order"], ["installer", "early", "late"])
        self.assertIn(bootmerge.CHAINED.strip(), text)
        self.assertNotIn("shutdown = finish", text)
        self.assertLess(text.index("_ordnance_mod_1"), text.index("seen_early"))
        self.assertLess(text.index("seen_early"), text.index("seen_late"))
        # A top-level return in mod 2 must not be at the chunk's top level.
        self.assertIn("local function _ordnance_mod_2(...)", text)
        self.assertIn("if rawget(_G, 'gone') then return end", text)

    def test_option_module_is_not_deployed_as_the_boot_script(self):
        config = "-- Transmog configuration resource.\n-- pad\nreturn true\n"
        script = "marker_script = true\n"
        patch, report = bootmerge.merge_sources([
            ("HelmetOn", pack(config)),
            ("foundation", pack(script)),
        ])
        text = bootmerge.extract_source(patch).decode("utf-8")
        self.assertEqual(report["skipped"], ["HelmetOn"])
        self.assertEqual(report["pins"][0][1:], ("mods/hd2transmog/options/helmet_transmog", True))
        self.assertNotIn("\nreturn true\n", text)
        self.assertIn("marker_script = true", text)
        self.assertIn("pkg.preload['mods/hd2transmog/options/helmet_transmog']", text)

    def test_opposite_options_are_refused(self):
        on = "return true\n"
        off = "return false\n"
        with self.assertRaises(bootmerge.BootMergeError):
            bootmerge.merge_sources([
                ("HelmetOn", pack(on)),
                ("HelmetOff", pack(off)),
                ("foundation", pack("marker = true\n")),
            ])

    def test_binary_payload_is_not_wrapped_as_lua(self):
        source = b"HD2FM1" + b"\0" * 20
        patch = bytearray(pack("placeholder\n"))
        # Swap in a binary payload and fix the size fields so extract accepts it.
        pad = (-(bootmerge.SOURCE_AT + len(source))) % 16
        total = bootmerge.SOURCE_AT + len(source) + pad
        struct.pack_into("<Q", patch, 0x20, total)
        struct.pack_into("<I", patch, 0xA0, len(source) + 8)
        blob = bytes(patch[:bootmerge.HEADER]) + struct.pack("<II", len(source), 2) + source + (b"\0" * pad)
        with self.assertRaises(bootmerge.BootMergeError):
            bootmerge.merge_sources([("payload", blob)])

    def test_repack_keeps_the_header_identity(self):
        addon = bytes.fromhex("fa95186993df76f4")
        patch, _ = bootmerge.merge_sources([("only", pack("answer = 1\n", addon=addon))])
        self.assertEqual(patch[0x68:0x70], addon)
        self.assertEqual(patch[0x50:0x58], LUA_TYPE)
        self.assertEqual(bootmerge._u64(patch, 0x20), len(patch))


class RealModTests(unittest.TestCase):
    SB = (
        "/home/lkavadas/.config/hd2arsenal/mods/"
        "Stratagem Balls Stay Put 1.0.3 17712 1.0.3 2026-10-22T21-56Z b7xT2t6RE_AR743085"
    )
    TM = "/home/lkavadas/.local/share/io.github.katsyk.ddmm/mods-pre-eac/HD2 Transmog Foundation"
    DK = (
        "/home/lkavadas/.local/share/io.github.katsyk.ddmm/mods-pre-eac/"
        "DiverKit - Alpha 8.10.6 Transmog Compatibility"
    )

    def test_the_three_mods_become_one_script(self):
        files = {
            "stratagem": os.path.join(self.SB, "Install/9ba626afa44a3aa3.patch_0"),
            "diverkit": os.path.join(self.DK, "Addon/9ba626afa44a3aa3.patch_0"),
            "transmog": os.path.join(self.TM, "Addon/9ba626afa44a3aa3.patch_0"),
            "helmet": os.path.join(self.TM, "HelmetOn/9ba626afa44a3aa3.patch_0"),
            "stats": os.path.join(self.TM, "IndependentStats/9ba626afa44a3aa3.patch_0"),
            "icons": os.path.join(self.TM, "PassiveIconsOn/9ba626afa44a3aa3.patch_0"),
            "payload": os.path.join(self.SB, "Install/b5b0c0ffee5b5b10.patch_0"),
        }
        for path in files.values():
            if not os.path.isfile(path):
                self.skipTest("missing " + path)
        originals = {name: bootmerge.extract_source(open(path, "rb").read()) for name, path in files.items() if name != "payload"}
        self.assertEqual(bootmerge.classify(originals["stratagem"]), "installer")
        self.assertEqual(bootmerge.classify(originals["diverkit"]), "script")
        self.assertEqual(bootmerge.classify(originals["transmog"]), "script")
        self.assertEqual(bootmerge.classify(originals["helmet"]), "config")
        payload = open(files["payload"], "rb").read()
        self.assertEqual(bootmerge.classify(bootmerge.extract_source(payload)), "binary")

        pieces = [(name, open(files[name], "rb").read()) for name in
                  ("stratagem", "diverkit", "transmog", "helmet", "stats", "icons")]
        # Profile order is stratagem, then the two addons. Configs may sit
        # anywhere; they must not enter the boot slot.
        patch, report = bootmerge.merge_sources(pieces)
        text = bootmerge.extract_source(patch).decode("utf-8")
        self.assertEqual(report["order"], ["stratagem", "diverkit", "transmog"])
        self.assertEqual(report["skipped"], ["helmet", "stats", "icons"])
        self.assertNotIn("shutdown = finish", text)
        for name in ("diverkit", "transmog"):
            self.assertIn(originals[name].decode("utf-8"), text)
        chained = bootmerge.chain_installer(originals["stratagem"].decode("utf-8"))
        self.assertIn(chained, text)
        for name in ("helmet", "stats", "icons"):
            self.assertNotIn(originals[name].decode("utf-8"), text)
        # Each mod's source sits inside its own function, installer first.
        self.assertLess(text.index("local MAGIC = \"HD2FM1\""), text.index("-- HD2-Addon: mods/codex/loadouts"))
        self.assertLess(text.index("-- HD2-Addon: mods/codex/loadouts"), text.index("-- HD2-Addon: mods/hd2transmog/foundation"))


if __name__ == "__main__":
    unittest.main()
