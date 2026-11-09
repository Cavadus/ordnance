// Run with `pnpm run test:unit` (plain Node; it strips the TypeScript types).
import { test } from "node:test";
import assert from "node:assert/strict";
import { dropOnList, dropOnRow, dropOnRun, insertLibraryMod } from "../../src/lib/utils/libraryDrop.ts";
import { gatherConfigs } from "../../src/lib/utils/categoryGroups.ts";

const mod = (guid) => ({ Guid: guid });

test("a row drop inserts before or after that mod and keeps its category", () => {
    const before = dropOnRow(1, "audio", true, 3);
    assert.deepEqual(before, {
        index: 1,
        categoryGuid: "audio",
        mark: { type: "row", index: 1, side: "before" },
    });
    const after = dropOnRow(2, null, false, 3);
    assert.equal(after.index, 3);
    assert.equal(after.categoryGuid, null);
    assert.equal(dropOnRow(0, "audio", true, 3).index, 0);
});

test("a category drop lands at the end of that run, and an empty one at the end of the list", () => {
    const filed = dropOnRun(1, 2, "audio", 5);
    assert.equal(filed.index, 3);
    assert.equal(filed.categoryGuid, "audio");
    assert.deepEqual(filed.mark, { type: "run", start: 1, categoryGuid: "audio" });
    const empty = dropOnRun(-1, -1, "visuals", 4);
    assert.equal(empty.index, 4);
    assert.equal(empty.categoryGuid, "visuals");
    assert.equal(dropOnList(4).index, 4);
    assert.equal(dropOnList(4).categoryGuid, null);
});

test("dropping into the middle of a category stays there after the list regroups", () => {
    const configs = [mod("a1"), mod("a2"), mod("u1")];
    const assignments = { a1: "audio", a2: "audio" };
    const target = dropOnRow(1, "audio", true, configs.length);
    const next = insertLibraryMod(configs, mod("new"), assignments, target);
    assert.deepEqual(configs.map((item) => item.Guid), ["a1", "new", "a2", "u1"]);
    gatherConfigs(configs, ["audio"], next);
    assert.deepEqual(configs.map((item) => item.Guid), ["a1", "new", "a2", "u1"]);
    assert.equal(next.new, "audio");
});

test("dropping on an empty category files it there, at the end", () => {
    const configs = [mod("a1")];
    const assignments = { a1: "audio" };
    const target = dropOnRun(-1, -1, "visuals", configs.length);
    const next = insertLibraryMod(configs, mod("new"), assignments, target);
    gatherConfigs(configs, ["audio", "visuals"], next);
    assert.deepEqual(configs.map((item) => item.Guid), ["a1", "new"]);
    assert.equal(next.new, "visuals");
});

test("a mod already in the profile is not inserted again", () => {
    const configs = [mod("a1")];
    assert.equal(insertLibraryMod(configs, mod("a1"), {}, dropOnList(1)), null);
    assert.deepEqual(configs.map((item) => item.Guid), ["a1"]);
});
