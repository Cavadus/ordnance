// Run with `pnpm run test:unit` (plain Node; it strips the TypeScript types).
import { test } from "node:test";
import assert from "node:assert/strict";
import { reorderLineSide } from "../../src/lib/utils/reorderDrop.ts";

test("dragging down marks the line under the row the pointer is on", () => {
    // [A, B, C, D], drag A onto C. Remove A, insert at 2: [B, C, A, D].
    assert.equal(reorderLineSide(2, 0, 2), "below");
    assert.equal(reorderLineSide(1, 0, 2), null);
    assert.equal(reorderLineSide(3, 0, 2), null);
});

test("dragging up marks the line above the row the pointer is on", () => {
    // [A, B, C, D], drag D onto B. Remove D, insert at 1: [A, D, B, C].
    assert.equal(reorderLineSide(1, 3, 1), "above");
    assert.equal(reorderLineSide(0, 3, 1), null);
    assert.equal(reorderLineSide(2, 3, 1), null);
});

test("a drag that has not moved has no line", () => {
    assert.equal(reorderLineSide(1, 1, 1), null);
});
