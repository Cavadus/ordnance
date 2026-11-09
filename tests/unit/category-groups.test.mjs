// Run with `pnpm run test:unit` (plain Node; it strips the TypeScript types).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    assignedCategory,
    categoryColor,
    gatherByKey,
    gatherConfigs,
    inkOn,
    moveBlock,
    nextPaletteColor,
    runBounds,
} from "../../src/lib/utils/categoryGroups.ts";

const keyOf = (name) => (name.startsWith("u") ? null : name[0]);

test("a scattered category is pulled up to its first mod, and uncategorized mods stay put", () => {
    const items = ["u1", "a1", "u2", "a2", "b1"];
    const gathered = gatherByKey(items, keyOf);
    assert.deepEqual(gathered, ["u1", "a1", "a2", "u2", "b1"]);
    assert.deepEqual(gatherByKey(gathered, keyOf), gathered);
});

test("an assignment to a deleted category is uncategorized", () => {
    const ids = new Set(["audio"]);
    assert.equal(assignedCategory("mod", { mod: "audio" }, ids), "audio");
    assert.equal(assignedCategory("mod", { mod: "gone" }, ids), null);
    assert.equal(assignedCategory("mod", {}, ids), null);
});

test("an empty color falls back to the palette, a real color is kept", () => {
    assert.equal(categoryColor("", 0), "#eab308");
    assert.equal(categoryColor(undefined, 1), "#60a5fa");
    assert.equal(categoryColor("#112233", 0), "#112233");
    assert.equal(categoryColor("red", 3), "#f87171");
});

test("the next profile color skips colors already showing, including empty ones", () => {
    assert.equal(nextPaletteColor([undefined, ""]), "#4ade80");
    assert.equal(nextPaletteColor(["#112233"]), "#eab308");
    assert.equal(inkOn("#eab308"), "#18181b");
    assert.equal(inkOn("#112233"), "#fafafa");
});

test("moving a category swaps its whole block with the neighboring run", () => {
    const items = ["u1", "a1", "a2", "u2", "b1"];
    const keys = items.map(keyOf);
    assert.deepEqual(runBounds(keys, 1), { start: 1, end: 2 });
    assert.equal(moveBlock(items, keys, 1, 1), true);
    assert.deepEqual(items, ["u1", "u2", "a1", "a2", "b1"]);
    // The two uncategorized mods are now one run, so the next move up
    // swaps with both of them, not just the one it passed on the way down.
    assert.equal(moveBlock(items, items.map(keyOf), 2, -1), true);
    assert.deepEqual(items, ["a1", "a2", "u1", "u2", "b1"]);

    const paired = ["a1", "a2", "u2", "b1"];
    const pairedKeys = paired.map(keyOf);
    assert.equal(moveBlock(paired, pairedKeys, 0, 1), true);
    assert.deepEqual(paired, ["u2", "a1", "a2", "b1"]);
    assert.equal(moveBlock(paired, paired.map(keyOf), 1, -1), true);
    assert.deepEqual(paired, ["a1", "a2", "u2", "b1"]);
    assert.equal(moveBlock(paired, paired.map(keyOf), 0, -1), false);
    assert.equal(moveBlock(paired, paired.map(keyOf), 3, 1), false);
});

test("gathering a profile pulls one category together and leaves the array's identity", () => {
    const configs = [
        { Guid: "u1" },
        { Guid: "a1" },
        { Guid: "u2" },
        { Guid: "a2" },
    ];
    const changed = gatherConfigs(configs, ["audio"], { a1: "audio", a2: "audio" });
    assert.equal(changed, true);
    assert.deepEqual(configs.map((c) => c.Guid), ["u1", "a1", "a2", "u2"]);
    assert.equal(gatherConfigs(configs, ["audio"], { a1: "audio", a2: "audio" }), false);
    assert.equal(gatherConfigs(configs, [], { a1: "audio" }), false);
});
