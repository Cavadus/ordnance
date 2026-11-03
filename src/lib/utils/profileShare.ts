import type { Config } from "$lib/models/profile";
import type { Manifest } from "$lib/models/manifest";
import type { Mod } from "$lib/models/mod";

export type ProfileShare = {
    Version: 1;
    Name: string;
    Entries: { Manifest: Manifest; Config: Config }[];
    skipped: string[];
};

type ShareManifest = {
    Guid?: string;
    Name?: string;
    NexusData?: { ModId?: number };
    Sources?: { Provider?: string; Id?: string }[];
};

type ShareEntry = {
    Manifest?: ShareManifest;
    Config?: Config;
};

/** A profile share is the profile's order and option choices plus each mod's
 * manifest. It does not contain the mod's files. */
export function buildProfileShare(
    profile: { Name: string; Configs: Config[] },
    mods: Pick<Mod, "guid" | "Manifest">[],
): ProfileShare {
    const byGuid = new Map(mods.map((mod) => [mod.guid, mod.Manifest]));
    const entries: ProfileShare["Entries"] = [];
    const skipped: string[] = [];
    for (const config of profile.Configs ?? []) {
        const manifest = byGuid.get(config.Guid);
        if (!manifest) {
            skipped.push(config.Guid);
            continue;
        }
        entries.push({ Manifest: manifest, Config: config });
    }
    return { Version: 1, Name: profile.Name, Entries: entries, skipped };
}

export function planProfileImport(share: unknown, installed: { guid: string }[]): {
    name: string;
    present: Config[];
    missing: { guid: string; name: string; nexusId: string | null }[];
} {
    if (!isShare(share)) throw new Error("That file is not an Ordnance profile.");
    const name = share.Name.trim() ? share.Name.trim() : "Shared profile";
    const have = new Set(installed.map((mod) => mod.guid));
    const present: Config[] = [];
    const missing: { guid: string; name: string; nexusId: string | null }[] = [];
    for (const entry of share.Entries) {
        const guid = entry?.Config?.Guid ?? entry?.Manifest?.Guid;
        if (!guid || !entry.Config) continue;
        if (have.has(guid)) {
            present.push(entry.Config);
            continue;
        }
        missing.push({
            guid,
            name: entry.Manifest?.Name || guid,
            nexusId: nexusIdOf(entry.Manifest),
        });
    }
    return { name, present, missing };
}

/** A name that does not collide with profiles the library already has. */
export function uniqueProfileName(name: string, existing: string[]): string {
    if (!existing.includes(name)) return name;
    let n = 2;
    while (existing.includes(`${name} ${n}`)) n += 1;
    return `${name} ${n}`;
}

function isShare(share: unknown): share is { Version: 1; Name: string; Entries: ShareEntry[] } {
    if (!share || typeof share !== "object") return false;
    const value = share as { Version?: unknown; Name?: unknown; Entries?: unknown };
    return value.Version === 1 && typeof value.Name === "string" && Array.isArray(value.Entries);
}

function nexusIdOf(manifest: ShareManifest | undefined): string | null {
    if (manifest?.NexusData?.ModId != null) return String(manifest.NexusData.ModId);
    const source = manifest?.Sources?.find((item) => item?.Provider === "nexus" && item.Id);
    return source?.Id ?? null;
}
