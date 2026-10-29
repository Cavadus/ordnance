/** One user-defined grouping. GUID is a UUID string. */
export type Category = {
    Guid: string;
    Name: string;
};

/** The whole categories store, mirroring categories.json on disk. */
export type Categories = {
    Version: "V1";
    Categories: Category[];
    /** Mod manifest GUID -> category GUID. Uncategorized mods have no entry. */
    Assignments: Record<string, string>;
};

export const EMPTY_CATEGORIES: Categories = {
    Version: "V1",
    Categories: [],
    Assignments: {},
};
