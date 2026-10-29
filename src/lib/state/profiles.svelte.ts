import type { Profile } from '$lib/models/profile';
import { saveProfiles } from '$lib/utils/commands';

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
            profiles = value;
            activeProfile = active;
            profilesLoaded = true;
        },
        setActive(index: number) {
            activeProfile = index;
        },
        add(name: string) {
            profiles.push({ Version: 'V1', Name: name, Configs: [] });
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

        async save() {
            await saveProfiles({ Profiles: profiles, Active: activeProfile });
        },
    };
}
