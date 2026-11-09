import type { Profile } from '$lib/models/profile';
import { saveProfiles } from '$lib/utils/commands';
import { categoryColor, nextPaletteColor } from '$lib/utils/categoryGroups';

/**
 * Shared profile state for the mod list and the sidebar. Profiles live in
 * `profiles.json`; the page's `init()` loads them and calls
 * `setProfiles`, and both the page and the sidebar mutate them through the
 * actions below so a switch made in the sidebar re-syncs the page's working
 * config list.
 */
let profiles = $state<Profile[]>([]);
let activeProfile = $state<number>(0);
let profilesLoaded = $state<boolean>(false);

export function useProfiles() {
    return {
        get profiles(): Profile[] {
            return profiles;
        },
        get activeProfile(): number {
            return activeProfile;
        },
        get profilesLoaded(): boolean {
            return profilesLoaded;
        },

        /** Replace the whole list (after loading/dedup in init()). */
        setProfiles(value: Profile[], active: number) {
            // An old profile has no color. Give it the palette color it is
            // already showing so deleting another profile does not repaint it.
            profiles = value.map((profile, index) => {
                if (profile.Version !== 'V1') return profile;
                if (profile.Color && /^#[0-9a-fA-F]{6}$/.test(profile.Color)) return profile;
                return { ...profile, Color: categoryColor(profile.Color, index) };
            });
            activeProfile = active;
            profilesLoaded = true;
        },
        setActive(index: number) {
            activeProfile = index;
        },
        add(name: string) {
            const color = nextPaletteColor(profiles.map((profile) => profile.Color));
            profiles.push({ Version: 'V1', Name: name, Configs: [], Color: color });
            activeProfile = profiles.length - 1;
        },
        remove(index: number) {
            profiles.splice(index, 1);
            if (index < activeProfile) {
                activeProfile--;
            } else if (index === activeProfile && activeProfile >= profiles.length) {
                activeProfile = profiles.length - 1;
            }
        },
        rename(index: number, name: string) {
            const p = profiles[index];
            if (p && p.Version === 'V1') p.Name = name;
        },
        setColor(index: number, color: string) {
            const p = profiles[index];
            if (p && p.Version === 'V1') p.Color = color;
        },
        setConfigs(index: number, configs: Profile['Configs']) {
            const p = profiles[index];
            if (p && p.Version === 'V1') p.Configs = configs;
        },

        async save() {
            await saveProfiles({ Profiles: profiles, Active: activeProfile });
        },
    };
}
