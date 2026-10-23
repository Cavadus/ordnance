#!/usr/bin/env python3
"""Medic's merge rules: hash tails are not edits, a real length change is exclusive."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swap


def table(body, extra=b""):
    size = len(body) + len(extra)
    raw = bytearray(24 + size)
    raw[0:8] = b"LDLD\x01\x00\x00\x00"
    struct.pack_into("<I", raw, 8, 1)
    struct.pack_into("<I", raw, 12, size)
    raw[16] = 1
    raw[24:24 + len(body)] = body
    if extra:
        raw[24 + len(body):] = extra
    return raw


class SwapRuleTests(unittest.TestCase):
    def test_hash_tail_is_not_an_edit(self):
        stock = table(b"\x02" * 16)
        mod = table(b"\x02" * 16, extra=b"\x00" * 8)
        self.assertEqual(swap.content_diffs(stock, mod), [])

    def test_a_real_byte_change_survives(self):
        body = bytearray(b"\x02" * 16)
        body[4] = 0
        stock = table(b"\x02" * 16)
        mod = table(bytes(body))
        edits = swap.content_diffs(stock, mod)
        self.assertEqual(edits, [(28, b"\x00")])

    def test_a_length_change_that_is_not_a_hash_tail_is_exclusive(self):
        stock = table(b"\x02" * 16)
        mod = table(b"\x02" * 16) + b"\x00" * 8
        with self.assertRaises(swap.LengthChange):
            swap.content_diffs(stock, mod)


if __name__ == "__main__":
    unittest.main()
