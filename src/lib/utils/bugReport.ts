import type { Manifest } from "$lib/models/manifest";
import type { Config } from "$lib/models/profile";
import type { BugReportFacts } from "$lib/utils/commands";

const ISSUE_URL = "https://github.com/Cavadus/ordnance/issues/new";
/** GitHub rejects a new-issue link somewhere past this. Leave room for the title. */
const MAX_URL_LENGTH = 7500;

export type { BugReportFacts };

export type ReportMod = {
    name: string;
    version: string | null;
    guid: string;
    nexusId: string | null;
    optionsOn: string[];
};

export function buildBugReport(input: {
    message: string;
    error: string;
    facts: BugReportFacts | null;
    profileName: string | null;
    profileModCount: number | null;
    enabled: ReportMod[];
}): { body: string; url: string } {
    const title = `Bug report: ${input.message.split("\n")[0].slice(0, 80)}`;
    let log = input.facts?.LogTail ?? "";
    let patches = input.facts?.DeployedPatches.slice() ?? [];
    let enabled = input.enabled.slice();
    let truncated = input.facts?.PatchesTruncated ?? false;

    const bodyOf = () =>
        renderBody({
            message: input.message,
            error: input.error,
            facts: input.facts,
            profileName: input.profileName,
            profileModCount: input.profileModCount,
            enabled,
            patches,
            log,
            truncated,
        });

    let body = bodyOf();
    // Each pass must drop something. `slice(0)` on a one-character log, and
    // `slice(0, ceil(1/2))` on a one-entry list, leave the input unchanged,
    // so a report that is still too long spins forever and freezes the window.
    for (let step = 0; step < 40 && issueUrl(title, body).length > MAX_URL_LENGTH; step += 1) {
        if (log.length === 0 && patches.length === 0 && enabled.length === 0) break;
        truncated = true;
        if (log.length > 0) log = log.slice(Math.ceil(log.length / 2));
        else if (patches.length > 0) patches = patches.slice(0, Math.floor(patches.length / 2));
        else enabled = enabled.slice(0, Math.floor(enabled.length / 2));
        body = bodyOf();
    }
    if (issueUrl(title, body).length > MAX_URL_LENGTH) {
        body = body.slice(0, 2000) + "\n\n(Report truncated to fit GitHub's link limit.)";
    }
    return { body, url: issueUrl(title, body) };
}

export function reportMods(
    configs: Config[],
    mods: { guid: string; name: string; version: string | null; Manifest: Manifest }[],
): ReportMod[] {
    const byGuid = new Map(mods.map((mod) => [mod.guid, mod]));
    const enabled: ReportMod[] = [];
    for (const config of configs) {
        if (!config.Enabled) continue;
        const mod = byGuid.get(config.Guid);
        enabled.push(mod ? modLine(mod, config) : { name: config.Guid, version: null, guid: config.Guid, nexusId: null, optionsOn: [] });
    }
    return enabled;
}

function issueUrl(title: string, body: string): string {
    return `${ISSUE_URL}?title=${encodeURIComponent(title)}&body=${encodeURIComponent(body)}`;
}

function renderBody(input: {
    message: string;
    error: string;
    facts: BugReportFacts | null;
    profileName: string | null;
    profileModCount: number | null;
    enabled: ReportMod[];
    patches: string[];
    log: string;
    truncated: boolean;
}): string {
    const facts = input.facts;
    const lines = [
        "### What happened",
        input.message,
        "",
        "### Error details",
        "```",
        input.error,
        "```",
        "",
        "### Environment",
        facts ? `- Ordnance: ${facts.Version}` : "- Ordnance: (could not read the app)",
        facts ? `- OS: ${facts.Os}` : "- OS: (could not read the machine)",
        facts
            ? `- Game build: ${facts.GameBuild ?? "unknown"}`
            : "- Game build: unknown",
        facts ? `- Game path: ${facts.GamePath || "not set"}` : "- Game path: unknown",
        `- Profile: ${input.profileName ?? "not loaded"}`,
    ];
    if (input.profileModCount != null) {
        lines.push(`- Enabled mods: ${input.enabled.length} of ${input.profileModCount}`);
    }
    for (const mod of input.enabled) {
        const version = mod.version ? ` ${mod.version}` : "";
        const nexus = mod.nexusId ? ` nexus ${mod.nexusId}` : "";
        const options = mod.optionsOn.length > 0 ? ` — ${mod.optionsOn.join(", ")}` : "";
        lines.push(`  - ${mod.name}${version} (${mod.guid})${nexus}${options}`);
    }
    lines.push("- Deployed patches:");
    if (input.patches.length === 0) {
        lines.push("  - (none found)");
    } else {
        for (const name of input.patches) lines.push(`  - ${name}`);
    }
    if (input.truncated) {
        lines.push("- Some of this report was cut so the GitHub link would open.");
    }
    lines.push("", "### Recent log", "```", input.log || "(no log)", "```");
    return lines.join("\n");
}

function modLine(
    mod: { guid: string; name: string; version: string | null; Manifest: Manifest },
    config: Config,
): ReportMod {
    if (!mod) {
        return { name: config.Guid, version: null, guid: config.Guid, nexusId: null, optionsOn: [] };
    }
    return {
        name: mod.name,
        version: mod.version,
        guid: mod.guid,
        nexusId: nexusId(mod.Manifest),
        optionsOn: optionsOn(mod.Manifest, config),
    };
}

function nexusId(manifest: Manifest): string | null {
    if ("NexusData" in manifest && manifest.NexusData?.ModId != null) {
        return String(manifest.NexusData.ModId);
    }
    if ("Sources" in manifest) {
        const source = manifest.Sources?.find((item) => item.Provider === "nexus" && item.Id);
        if (source?.Id) return source.Id;
    }
    return null;
}

function optionsOn(manifest: Manifest, config: Config): string[] {
    const names = optionNames(manifest);
    if (config.For === "Legacy") {
        const name = names[config.Selected];
        return name ? [name] : [];
    }
    return config.Toggled.flatMap((on, index) => (on ? [names[index] ?? `#${index + 1}`] : []));
}

function optionNames(manifest: Manifest): string[] {
    if (!("Options" in manifest) || !manifest.Options) return [];
    return manifest.Options.map((option) => (typeof option === "string" ? option : option.Name));
}
