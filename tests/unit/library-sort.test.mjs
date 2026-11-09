// Run with `pnpm run test:unit` (plain Node; it strips the TypeScript types).
import { test } from "node:test";
import assert from "node:assert/strict";
import { filterLibrary, sortLibrary } from "../../src/lib/utils/librarySort.ts";

const rows = [
    { name: "Mod 10", description: "late", installedAt: 300, updatedAt: 300 },
    { name: "Mod 2", description: "cape colors", installedAt: 100, updatedAt: 400 },
    { name: "Zebra", description: "no record", installedAt: null, updatedAt: null },
    { name: "alpha", description: "patched", installedAt: 200, updatedAt: 200 },
];

test("name sort is alphabetical and numeric, either way, and does not reorder the input", () => {
    const names = (dir) => sortLibrary(rows, "name", dir).map((row) => row.name);
    assert.deepEqual(names("asc"), ["alpha", "Mod 2", "Mod 10", "Zebra"]);
    assert.deepEqual(names("desc"), ["Zebra", "Mod 10", "Mod 2", "alpha"]);
    assert.equal(rows[0].name, "Mod 10");
});

test("date sorts put a missing date last in both directions and break ties by name", () => {
    const installed = (dir) => sortLibrary(rows, "installed", dir).map((row) => row.name);
    assert.deepEqual(installed("asc"), ["Mod 2", "alpha", "Mod 10", "Zebra"]);
    assert.deepEqual(installed("desc"), ["Mod 10", "alpha", "Mod 2", "Zebra"]);

    const tied = [
        { name: "B", description: "", installedAt: 50, updatedAt: 80 },
        { name: "A", description: "", installedAt: 50, updatedAt: 80 },
    ];
    assert.deepEqual(sortLibrary(tied, "updated", "desc").map((row) => row.name), ["A", "B"]);
    assert.deepEqual(sortLibrary(tied, "updated", "asc").map((row) => row.name), ["A", "B"]);
});

test("a blank search keeps the list, and a query matches the name or the description", () => {
    assert.equal(filterLibrary(rows, "  ").length, rows.length);
    assert.deepEqual(filterLibrary(rows, "CAPE").map((row) => row.name), ["Mod 2"]);
    assert.deepEqual(filterLibrary(rows, "patched").map((row) => row.name), ["alpha"]);
    assert.deepEqual(filterLibrary(rows, "nope"), []);
});
