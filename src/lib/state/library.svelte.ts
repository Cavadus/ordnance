import type { Mod } from "$lib/models/mod";

/** The installed library, mirrored from the Mods page so the sidebar can
 * export a profile without packing the mod files. */
let mods = $state<Mod[]>([]);

export function useLibrary() {
    return {
        get mods(): Mod[] {
            return mods;
        },
        set(value: Mod[]) {
            mods = value;
        },
    };
}
