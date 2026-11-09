/** How the library tray orders mods that are not in the profile. */
export type LibrarySortKey = "name" | "installed" | "updated";

export type SortDir = "asc" | "desc";

export type LibraryRow = {
    name: string;
    description: string;
    installedAt?: number | null;
    updatedAt?: number | null;
};

const NAME_OPTIONS: Intl.CollatorOptions = { numeric: true, sensitivity: "base" };

function byName(a: LibraryRow, b: LibraryRow): number {
    return a.name.localeCompare(b.name, undefined, NAME_OPTIONS);
}

function knownTime(value: number | null | undefined): number | null {
    return typeof value === "number" && value > 0 ? value : null;
}

/** Mods whose name or description contains `query`. A blank query keeps every mod. */
export function filterLibrary<T extends Pick<LibraryRow, "name" | "description">>(
    mods: readonly T[],
    query: string,
): T[] {
    const needle = query.trim().toLowerCase();
    if (needle.length === 0) return [...mods];
    return mods.filter((mod) =>
        mod.name.toLowerCase().includes(needle) || mod.description.toLowerCase().includes(needle),
    );
}

/**
 * Name, install date, or update date. Missing dates stay at the bottom in
 * either direction. Equal dates (and equal names, for a name sort that
 * somehow ties) break the tie by name, A to Z.
 */
export function sortLibrary<T extends LibraryRow>(
    mods: readonly T[],
    key: LibrarySortKey,
    dir: SortDir,
): T[] {
    const sign = dir === "desc" ? -1 : 1;
    const timeOf = (mod: T): number | null =>
        knownTime(key === "installed" ? mod.installedAt : mod.updatedAt);

    return [...mods].sort((a, b) => {
        if (key === "name") return sign * byName(a, b);
        const left = timeOf(a);
        const right = timeOf(b);
        if (left === null && right === null) return byName(a, b);
        if (left === null) return 1;
        if (right === null) return -1;
        if (left !== right) return sign * (left - right);
        return byName(a, b);
    });
}
