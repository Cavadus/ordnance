// How a profile's load order sits once mods are grouped by category.
// No imports but types, so tests/unit can run this with plain Node.
//
// A category becomes one contiguous block, parked where its first mod
// already was. Mods of that category that were scattered further down are
// pulled up into the block. Uncategorized mods stay where they are, so a
// mod you just added at the bottom still wins until you file it.
// Keep `CATEGORY_PALETTE` in step with `Categories::next_color`.

import type { Config } from "../models/profile";

export const CATEGORY_PALETTE = [
    "#eab308",
    "#60a5fa",
    "#4ade80",
    "#f87171",
    "#c084fc",
    "#fb923c",
    "#22d3ee",
    "#f472b6",
] as const;

export function categoryColor(color: string | undefined, index: number): string {
    if (color && /^#[0-9a-fA-F]{6}$/.test(color)) return color;
    const safe = index < 0 ? 0 : index;
    return CATEGORY_PALETTE[safe % CATEGORY_PALETTE.length];
}

/** Text color that stays readable on `color` when that color is a badge fill. */
export function inkOn(color: string): "#18181b" | "#fafafa" {
    const match = /^#([0-9a-fA-F]{6})$/.exec(color);
    if (!match) return "#18181b";
    const n = Number.parseInt(match[1], 16);
    const r = (n >> 16) & 255;
    const g = (n >> 8) & 255;
    const b = n & 255;
    const luma = (r * 299 + g * 587 + b * 114) / 1000;
    return luma < 150 ? "#fafafa" : "#18181b";
}

/** Next palette entry that is not already showing on one of `existing`.
 * An empty color counts as the palette color for that position. */
export function nextPaletteColor(existing: readonly (string | undefined)[]): string {
    const used = new Set(existing.map((color, index) => categoryColor(color, index).toLowerCase()));
    const free = CATEGORY_PALETTE.find((color) => !used.has(color.toLowerCase()));
    return free ?? CATEGORY_PALETTE[existing.length % CATEGORY_PALETTE.length];
}

/** The category a mod belongs to, or null when it has none (or the
 * assignment points at a category that was deleted). */
export function assignedCategory(
    guid: string,
    assignments: Record<string, string>,
    categoryIds: ReadonlySet<string>,
): string | null {
    const assigned = assignments[guid];
    if (!assigned || !categoryIds.has(assigned)) return null;
    return assigned;
}

export function sameGuidOrder(a: readonly { Guid: string }[], b: readonly { Guid: string }[]): boolean {
    return a.length === b.length && a.every((item, i) => item.Guid === b[i]?.Guid);
}

/**
 * One block per category key. `null` (uncategorized) is not a block: those
 * mods stay put, and a category's later mods are pulled up to its first one.
 * Running it twice changes nothing.
 */
export function gatherByKey<T>(items: readonly T[], keyOf: (item: T) => string | null): T[] {
    const out: T[] = [];
    const seen = new Set<string>();
    for (const item of items) {
        const key = keyOf(item);
        if (key === null) {
            out.push(item);
            continue;
        }
        if (seen.has(key)) continue;
        seen.add(key);
        for (const other of items) {
            if (keyOf(other) === key) out.push(other);
        }
    }
    return out;
}

/** Inclusive bounds of the contiguous run that contains `index`.
 * A `null` key only runs through neighboring `null`s. */
export function runBounds(keys: readonly (string | null)[], index: number): { start: number; end: number } {
    const key = keys[index];
    let start = index;
    let end = index;
    while (start > 0 && keys[start - 1] === key) start--;
    while (end + 1 < keys.length && keys[end + 1] === key) end++;
    return { start, end };
}

/**
 * Swap the run containing `indexInBlock` with the neighboring run.
 * `-1` moves it up (loads earlier). `1` moves it down (wins over the run
 * it swaps with). No-op at the ends of the list.
 */
export function moveBlock<T>(
    items: T[],
    keys: readonly (string | null)[],
    indexInBlock: number,
    direction: -1 | 1,
): boolean {
    if (items.length !== keys.length || indexInBlock < 0 || indexInBlock >= items.length) return false;
    const { start, end } = runBounds(keys, indexInBlock);
    if (direction === -1) {
        if (start === 0) return false;
        const block = items.splice(start, end - start + 1);
        const prev = runBounds(keys, start - 1);
        items.splice(prev.start, 0, ...block);
        return true;
    }
    if (end >= items.length - 1) return false;
    const next = runBounds(keys, end + 1);
    const neighbor = items.splice(next.start, next.end - next.start + 1);
    items.splice(start, 0, ...neighbor);
    return true;
}

/** Regroup `configs` in place. Returns whether the order changed. */
export function gatherConfigs(
    configs: Config[],
    categoryIds: readonly string[],
    assignments: Record<string, string>,
): boolean {
    if (categoryIds.length === 0) return false;
    const ids = new Set(categoryIds);
    const next = gatherByKey(configs, (config) => assignedCategory(config.Guid, assignments, ids));
    if (sameGuidOrder(next, configs)) return false;
    configs.splice(0, configs.length, ...next);
    return true;
}
