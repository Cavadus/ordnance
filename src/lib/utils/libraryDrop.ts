// Where a mod dragged out of the library tray lands in the profile.
// No runtime imports, so tests/unit can run this with plain Node.

export type LibraryDropTarget = {
    /** Insert index in the profile's load order. */
    index: number;
    /** Category the mod joins. Null leaves it uncategorized. */
    categoryGuid: string | null;
    /** What to light up while the pointer is over the list. */
    mark:
        | { type: "row"; index: number; side: "before" | "after" }
        | { type: "run"; start: number; categoryGuid: string | null }
        | { type: "list" };
};

function clampIndex(index: number, length: number): number {
    if (index < 0) return 0;
    if (index > length) return length;
    return index;
}

/** Top half of a row inserts before it. Bottom half inserts after it. */
export function dropOnRow(
    profileIndex: number,
    categoryGuid: string | null,
    before: boolean,
    length: number,
): LibraryDropTarget {
    const index = clampIndex(before ? profileIndex : profileIndex + 1, length);
    return {
        index,
        categoryGuid,
        mark: { type: "row", index: profileIndex, side: before ? "before" : "after" },
    };
}

/**
 * Drop on a category (or an uncategorized run). The mod goes at the end of
 * that run, so it wins inside the group. An empty category has `start < 0`
 * and lands at the end of the list.
 */
export function dropOnRun(
    start: number,
    end: number,
    categoryGuid: string | null,
    length: number,
): LibraryDropTarget {
    const index = start < 0 ? length : clampIndex(end + 1, length);
    return {
        index,
        categoryGuid,
        mark: { type: "run", start, categoryGuid },
    };
}

/** Drop on the list background. Appends, and does not file a category. */
export function dropOnList(length: number): LibraryDropTarget {
    return { index: length, categoryGuid: null, mark: { type: "list" } };
}

/**
 * Insert `config` at the drop. Returns the assignments to store, or null
 * when that mod is already in the profile. Mutates `configs` in place.
 */
export function insertLibraryMod<T extends { Guid: string }>(
    configs: T[],
    config: T,
    assignments: Readonly<Record<string, string>>,
    target: LibraryDropTarget,
): Record<string, string> | null {
    if (configs.some((item) => item.Guid === config.Guid)) return null;
    const index = clampIndex(target.index, configs.length);
    configs.splice(index, 0, config);
    if (!target.categoryGuid) return { ...assignments };
    return { ...assignments, [config.Guid]: target.categoryGuid };
}
