<!--
  @component
  The side bar for navigation and profile switching.
-->

<script lang="ts">
    import { page } from "$app/state";
    import {
        Boxes,
        Gear,
        Plus,
        PencilSquare,
        Trash3,
        Download,
        Upload,
    } from "svelte-bootstrap-icons";
    import { open, save } from "@tauri-apps/plugin-dialog";
    import { useLocalization } from "$lib/state/localization.svelte";
    import { useProfiles } from "$lib/state/profiles.svelte";
    import { useLibrary } from "$lib/state/library.svelte";
    import { usePopup } from "$lib/state/popup.svelte";
    import { InputPopup, ConfirmPopup, NotificationPopup } from "$lib/types/popup";
    import { buildProfileShare, planProfileImport, uniqueProfileName } from "$lib/utils/profileShare";
    import { readProfileShare, writeProfileShare } from "$lib/utils/commands";
    import { fitConfig } from "$lib/utils/profileEntries";
    import type { Config } from "$lib/models/profile";

    const { t } = useLocalization();
    const profilesStore = useProfiles();
    const library = useLibrary();
    const { show: showPopup } = usePopup();

    /** Two uppercase letters for the avatar: first letter of the first two
     * words, falling back to the first two letters of a single word. */
    function initials(name: string): string {
        const words = name.trim().split(/\s+/).filter(Boolean);
        if (words.length === 0) return "?";
        if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
        return (words[0][0] + words[1][0]).toUpperCase();
    }

    async function onSwitchProfile(index: number) {
        profilesStore.setActive(index);
        await profilesStore.save();
    }

    async function onAddProfile() {
        const name = await showPopup(new InputPopup(
            t("pages.mods.popup.input.add_profile.placeholder"),
            false,
            3,
        ));
        if (!name) return;
        profilesStore.add(name);
        await profilesStore.save();
    }

    async function onRenameProfile(index: number) {
        const current = profilesStore.profiles[index];
        if (!current) return;
        const name = await showPopup(new InputPopup(
            t("pages.mods.popup.input.add_profile.placeholder"),
            false,
            3,
        ));
        if (!name) return;
        profilesStore.rename(index, name);
        await profilesStore.save();
    }

    async function onRemoveProfile(index: number) {
        const confirmed = await showPopup(new ConfirmPopup(
            t("pages.mods.popup.confirm.remove_profile.title"),
            t("pages.mods.popup.confirm.remove_profile.question"),
        ));
        if (!confirmed) return;
        profilesStore.remove(index);
        await profilesStore.save();
    }

    async function onExportProfile() {
        const profile = profilesStore.profiles[profilesStore.activeProfile];
        if (!profile) return;
        const share = buildProfileShare(profile, library.mods);
        if (share.Entries.length === 0) {
            await showPopup(new NotificationPopup("warning", t("sidebar.profiles.export.empty")));
            return;
        }
        const path = await save({
            title: t("sidebar.profiles.export.tip"),
            defaultPath: `${profile.Name}.ordnance-profile.json`,
            filters: [{ name: "Ordnance profile", extensions: ["json"] }],
        });
        if (!path) return;
        const { skipped: _skipped, ...file } = share;
        await writeProfileShare(path, JSON.stringify(file, null, 2) + "\n");
        await showPopup(new NotificationPopup("info", t("sidebar.profiles.export.done", { name: profile.Name })));
    }

    async function onImportProfile() {
        const picked = await open({
            title: t("sidebar.profiles.import.tip"),
            multiple: false,
            filters: [{ name: "Ordnance profile", extensions: ["json"] }],
        });
        const path = typeof picked === "string" ? picked : null;
        if (!path) return;
        let share: unknown;
        try {
            share = JSON.parse(await readProfileShare(path));
        } catch (ex) {
            const message = ex instanceof Error ? ex.message : String(ex);
            await showPopup(new NotificationPopup("error", message));
            return;
        }
        let plan;
        try {
            plan = planProfileImport(share, library.mods);
        } catch (ex) {
            const message = ex instanceof Error ? ex.message : String(ex);
            await showPopup(new NotificationPopup("error", message));
            return;
        }
        const configs: Config[] = [];
        for (const config of plan.present) {
            const mod = library.mods.find((item) => item.guid === config.Guid);
            if (!mod) continue;
            configs.push(fitConfig(config, mod.Manifest).config);
        }
        const name = uniqueProfileName(plan.name, profilesStore.profiles.map((item) => item.Name));
        profilesStore.add(name);
        profilesStore.setConfigs(profilesStore.activeProfile, configs);
        await profilesStore.save();
        const missing = plan.missing.map((item) => item.nexusId ? `${item.name} (${item.nexusId})` : item.name).join(", ");
        const done = t("sidebar.profiles.import.done", { name });
        const message = missing ? `${done} ${t("sidebar.profiles.import.missing", { missing })}` : done;
        await showPopup(new NotificationPopup(missing ? "warning" : "info", message));
    }
</script>

<div class="w-52 bg-zinc-900 p-1.5 flex flex-col gap-1.5 border-r border-zinc-800">
    <!-- Nav -->
    <div class="flex flex-row gap-0.5">
        <a href="/">
            <button
                class="w-9 h-9 p-1.5 hover:bg-zinc-800 rounded-md border border-transparent transition
                    {page.url.pathname === '/'
                    ? 'text-yellow-300 border-yellow-300'
                    : 'text-zinc-300'}"
                aria-label={t("sidebar.mods_button.tip")}
                title={t("sidebar.mods_button.tip")}
            >
                <Boxes class="w-full h-full block ml-auto mr-auto" />
            </button>
        </a>
        <a href="/settings">
            <button
                class="w-9 h-9 p-1.5 hover:bg-zinc-800 rounded-md border border-transparent transition
                    {page.url.pathname === '/settings'
                    ? 'text-yellow-300 border-yellow-300'
                    : 'text-zinc-300'}"
                class:active={page.url.pathname === "/settings"}
                aria-label={t("sidebar.settings_button.tip")}
                title={t("sidebar.settings_button.tip")}
            >
                <Gear class="w-full h-full block ml-auto mr-auto" />
            </button>
        </a>
    </div>

    <div class="h-px bg-zinc-800"></div>

    <!-- Profiles -->
    <div class="flex-1 flex flex-col gap-1 min-h-0">
        <div class="flex flex-row items-center justify-between px-1">
            <span class="text-xs uppercase tracking-wider text-zinc-500">{t("sidebar.profiles.title")}</span>
            <div class="flex flex-row">
                <button
                    class="w-7 h-7 p-1 hover:bg-zinc-800 hover:text-yellow-300 rounded-md text-zinc-400 transition"
                    onclick={onExportProfile}
                    aria-label={t("sidebar.profiles.export.tip")}
                    title={t("sidebar.profiles.export.tip")}
                >
                    <Upload class="w-full h-full block ml-auto mr-auto" />
                </button>
                <button
                    class="w-7 h-7 p-1 hover:bg-zinc-800 hover:text-yellow-300 rounded-md text-zinc-400 transition"
                    onclick={onImportProfile}
                    aria-label={t("sidebar.profiles.import.tip")}
                    title={t("sidebar.profiles.import.tip")}
                >
                    <Download class="w-full h-full block ml-auto mr-auto" />
                </button>
                <button
                    class="w-7 h-7 p-1 hover:bg-zinc-800 hover:text-yellow-300 rounded-md text-zinc-400 transition"
                    onclick={onAddProfile}
                    aria-label={t("sidebar.profiles.add.tip")}
                    title={t("sidebar.profiles.add.tip")}
                >
                    <Plus class="w-full h-full block ml-auto mr-auto" />
                </button>
            </div>
        </div>

        <div class="flex-1 overflow-y-auto flex flex-col gap-0.5">
            {#each profilesStore.profiles as profile, i (i)}
                <div
                    class="group flex flex-row items-center gap-1 px-1 py-1 rounded-md cursor-pointer transition border border-transparent
                        {i === profilesStore.activeProfile
                        ? 'bg-zinc-800 border-amber-400/40'
                        : 'hover:bg-zinc-800'}"
                    role="button"
                    tabindex="0"
                    onclick={() => onSwitchProfile(i)}
                    onkeydown={(e) => { if (e.key === "Enter" || e.key === " ") onSwitchProfile(i); }}
                >
                    <span
                        class="w-7 h-7 rounded-md bg-amber-400 text-zinc-900 text-xs font-bold flex items-center justify-center shrink-0"
                    >
                        {initials(profile.Name)}
                    </span>
                    <span
                        class="flex-1 truncate text-sm
                            {i === profilesStore.activeProfile ? 'text-yellow-300' : 'text-zinc-300'}"
                    >
                        {profile.Name}
                    </span>
                    <button
                        class="w-6 h-6 p-1 rounded-md text-zinc-500 hover:text-yellow-300 hover:bg-zinc-700 transition
                            {i === profilesStore.activeProfile ? '' : 'opacity-0 group-hover:opacity-100'}"
                        onclick={(e) => { e.stopPropagation(); onRenameProfile(i); }}
                        aria-label={t("sidebar.profiles.rename.tip")}
                        title={t("sidebar.profiles.rename.tip")}
                    >
                        <PencilSquare class="w-full h-full block" />
                    </button>
                    <button
                        class="w-6 h-6 p-1 rounded-md text-zinc-500 hover:text-red-400 hover:bg-zinc-700 transition
                            {i === profilesStore.activeProfile ? '' : 'opacity-0 group-hover:opacity-100'}"
                        disabled={profilesStore.profiles.length <= 1}
                        onclick={(e) => { e.stopPropagation(); onRemoveProfile(i); }}
                        aria-label={t("sidebar.profiles.delete.tip")}
                        title={t("sidebar.profiles.delete.tip")}
                    >
                        <Trash3 class="w-full h-full block" />
                    </button>
                </div>
            {/each}
        </div>
    </div>
</div>
