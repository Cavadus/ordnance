import assert from "node:assert/strict";
import test from "node:test";
import { buildBugReport, reportMods } from "../../src/lib/utils/bugReport.ts";

const guid = "11111111-1111-4111-8111-111111111111";

const facts = {
    Os: "Ubuntu 24.04 (kernel 6.8.0, x86_64)",
    Version: "0.4.4",
    GamePath: "/games/Helldivers 2",
    GameBuild: "26251122",
    DeployedPatches: ["9ba626afa44a3aa3.patch_0"],
    PatchesTruncated: false,
    LogTail: "file swap generated_stratagem_settings.dl_bin: Stratagem",
};

test("a report names the version, the game build, the enabled mod, and the patch", () => {
    const enabled = reportMods(
        [{ For: "V1", Guid: guid, Enabled: true, Toggled: [true, false], Selected: [0] },
         { For: "V1", Guid: "off", Enabled: false, Toggled: [], Selected: [] }],
        [{
            guid,
            name: "Stratagem Balls Stay Put",
            version: "1.0.3",
            Manifest: {
                Version: 1,
                Guid: guid,
                Name: "Stratagem Balls Stay Put",
                Description: "",
                NexusData: { ModId: 77 },
                Options: [
                    { Name: "Stay put", Description: "" },
                    { Name: "Uninstall helper", Description: "" },
                ],
            },
        }],
    );
    const report = buildBugReport({
        message: "Deployment failed!",
        error: "paint generated_stratagem_settings.dl_bin: reseal failed",
        facts,
        profileName: "Default",
        profileModCount: 2,
        enabled,
    });
    assert.match(report.body, /Ordnance: 0\.4\.4/);
    assert.match(report.body, /Game build: 26251122/);
    assert.match(report.body, /Enabled mods: 1 of 2/);
    assert.match(report.body, /Stratagem Balls Stay Put 1\.0\.3/);
    assert.match(report.body, /nexus 77/);
    assert.match(report.body, /Stay put/);
    assert.doesNotMatch(report.body, /Uninstall helper/);
    assert.match(report.body, /9ba626afa44a3aa3\.patch_0/);
    assert.match(report.body, /reseal failed/);
    assert.ok(report.url.startsWith("https://github.com/Cavadus/ordnance/issues/new?"));
    assert.ok(report.url.length < 7500);
});

test("a huge log is cut so the GitHub link still fits", () => {
    const report = buildBugReport({
        message: "Deployment failed!",
        error: "reseal failed",
        facts: { ...facts, LogTail: "x".repeat(20000) },
        profileName: "Default",
        profileModCount: 0,
        enabled: [],
    });
    assert.ok(report.url.length <= 7500);
    assert.match(report.body, /cut so the GitHub link would open/);
});

test("a long patch list still finishes once the log is down to one character", () => {
    const patches = Array.from({ length: 400 }, (_, i) => `patch_${i}_${"n".repeat(60)}`);
    const enabled = Array.from({ length: 80 }, (_, i) => ({
        name: `Mod ${i} ${"m".repeat(30)}`,
        version: "1.0.0",
        guid,
        nexusId: "123456",
        optionsOn: ["a", "b", "c", "d"],
    }));
    const report = buildBugReport({
        message: "Deployment failed!",
        error: "Install was built against a different generated_stratagem_settings.dl_bin",
        facts: { ...facts, LogTail: "line\n".repeat(30), DeployedPatches: patches },
        profileName: "Default",
        profileModCount: enabled.length,
        enabled,
    });
    assert.ok(report.url.length <= 7500);
    assert.match(report.body, /cut so the GitHub link would open/);
});
