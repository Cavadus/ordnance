import type { UUID } from "$lib/types/uuid";
import type { Manifest } from "./manifest";
import { modImageSrc } from "$lib/utils/modImages";

/** Where a {@link ResolvedSource} came from. */
export type SourceOrigin = "Manifest" | "Install";

/** A {@link import("./manifest").Source} resolved into something directly renderable. */
export type ResolvedSource = {
    readonly Provider: string;
    readonly DisplayName: string;
    readonly PageUrl?: string;
    readonly Version?: string;
    readonly Origin: SourceOrigin;
};

export class Mod {
    constructor(
        public readonly Manifest: Manifest,
        public readonly Directory: string,
        public readonly Sources: ResolvedSource[] = []
    ) {}

    get guid(): UUID {
        return this.Manifest.Guid;
    }

    get name(): string {
        return this.Manifest.Name;
    }

    get description(): string {
        return this.Manifest.Description;
    }

    /**
     * The mod's installed version, preferring the install-origin source and
     * falling back to the first source that carries a version. `null` when
     * no source records one.
     */
    get version(): string | null {
        const install = this.Sources.find((s) => s.Origin === "Install" && s.Version);
        if (install?.Version) return install.Version;
        return this.Sources.find((s) => s.Version)?.Version ?? null;
    }

    /**
     * The mod's tracked source page, preferring the install-origin source
     * and falling back to the first source that records a page URL. `null`
     * when no source records one.
     */
    get sourceLink(): { name: string; url: string } | null {
        const install = this.Sources.find((s) => s.Origin === "Install" && s.PageUrl);
        const source = install ?? this.Sources.find((s) => s.PageUrl);
        if (!source?.PageUrl) return null;
        return { name: source.DisplayName, url: source.PageUrl };
    }

    async iconPath(): Promise<string | null> {
        if (!this.Manifest.IconPath) return null;
        return modImageSrc(this.Directory, this.Manifest.IconPath);
    }
}