import assert from "node:assert/strict";
import test from "node:test";
import { buildProfileShare, planProfileImport, uniqueProfileName } from "../../src/lib/utils/profileShare.ts";

const oneTwo = {
    guid: "11111111-1111-4111-8111-111111111111",
    Manifest: {
        Guid: "11111111-1111-4111-8111-111111111111",
        Name: "One-Two",
        NexusData: { ModId: 42, Version: "1" },
    },
};

test("a share keeps the manifest and the option choices, not a second copy of a missing mod", () => {
    const share = buildProfileShare({
        Name: "Default",
        Configs: [
            { For: "V1", Guid: oneTwo.guid, Enabled: true, Toggled: [true, false], Selected: [0, 0] },
            { For: "V1", Guid: "missing", Enabled: true, Toggled: [], Selected: [] },
        ],
    }, [oneTwo]);
    assert.equal(share.Entries.length, 1);
    assert.equal(share.Entries[0].Manifest.Name, "One-Two");
    assert.deepEqual(share.Entries[0].Config.Toggled, [true, false]);
    assert.deepEqual(share.skipped, ["missing"]);
});

test("import turns on mods the library has and names the ones it does not", () => {
    const share = buildProfileShare({
        Name: "Squad",
        Configs: [
            { For: "V1", Guid: oneTwo.guid, Enabled: false, Toggled: [true], Selected: [0] },
            { For: "V1", Guid: "22222222-2222-4222-8222-222222222222", Enabled: true, Toggled: [], Selected: [] },
        ],
    }, [oneTwo, {
        guid: "22222222-2222-4222-8222-222222222222",
        Manifest: { Guid: "22222222-2222-4222-8222-222222222222", Name: "Chef", Sources: [{ Provider: "nexus", Id: "99" }] },
    }]);
    const plan = planProfileImport(share, [oneTwo]);
    assert.equal(plan.name, "Squad");
    assert.equal(plan.present.length, 1);
    assert.equal(plan.present[0].Enabled, false);
    assert.deepEqual(plan.missing, [{ guid: "22222222-2222-4222-8222-222222222222", name: "Chef", nexusId: "99" }]);
});

test("an imported name gets a number when that profile already exists", () => {
    assert.equal(uniqueProfileName("Default", ["Default"]), "Default 2");
    assert.equal(uniqueProfileName("Default", ["Default", "Default 2"]), "Default 3");
});

test("a file that is not a profile share is refused", () => {
    assert.throws(() => planProfileImport({ Version: 2, Entries: [] }, []), /not an Ordnance profile/);
});
