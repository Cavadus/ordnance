<script lang="ts">
    import { openUrl } from "@tauri-apps/plugin-opener";
    import PopupBase from "./PopupBase.svelte";
    import { ErrorPopup } from "$lib/types/popup";
    import { useLocalization } from "$lib/state/localization.svelte";
    import { bugReportFacts, copyText, type BugReportFacts } from "$lib/utils/commands";
    import { buildBugReport, reportMods } from "$lib/utils/bugReport";
    import { useLibrary } from "$lib/state/library.svelte";
    import { useProfiles } from "$lib/state/profiles.svelte";
    
    const { t } = useLocalization();

    let { popup }: { popup: ErrorPopup } = $props();

    let copied = $state(false);
    let copyFailed = $state(false);

    async function currentReport(): Promise<{ body: string; url: string }> {
        let facts: BugReportFacts | null = null;
        try {
            facts = await bugReportFacts();
        } catch {
            facts = null;
        }
        const profiles = useProfiles();
        const library = useLibrary();
        const profile = profiles.profiles[profiles.activeProfile];
        return buildBugReport({
            message: popup.message,
            error: popup.errorMessage,
            facts,
            profileName: profile?.Name ?? null,
            profileModCount: profile ? profile.Configs.length : null,
            enabled: profile ? reportMods(profile.Configs, library.mods) : [],
        });
    }

    async function reportText(): Promise<string> {
        try {
            return (await currentReport()).body;
        } catch {
            return `${popup.message}\n\n${popup.errorMessage}`;
        }
    }

    async function onCopy() {
        // Never touch the webview clipboard. On Linux that call deadlocks
        // the page, and then every button in this dialog stops working.
        try {
            await copyText(await reportText());
            copied = true;
            copyFailed = false;
            setTimeout(() => (copied = false), 2000);
        } catch (ex) {
            console.error(ex);
            copied = false;
            copyFailed = true;
            setTimeout(() => (copyFailed = false), 3000);
        }
    }

    async function onReport() {
        const report = await currentReport();
        openUrl(report.url);
    }
</script>

<PopupBase>
    <span class="text-red-500 text-xl font-blockletter self-center">{t("popup.notification.title.error")}</span>
    <p class="min-w-40 text-sm self-start whitespace-pre-wrap">{popup.message}</p>
    <pre class="min-w-40 px-2 py-1 bg-zinc-800 rounded text-sm self-start whitespace-pre-wrap font-mono">{popup.errorMessage}</pre>
    <div class="flex flex-row gap-1 self-end">
        <button class="ordnance-button" onclick={onCopy}>{copyFailed ? t("popup.notification.copy_button.failed") : copied ? t("popup.notification.copy_button.copied") : t("popup.notification.copy_button.text")}</button>
        <button class="ordnance-button" onclick={onReport}>{t("popup.notification.report_button.text")}</button>
        <button class="ordnance-button" onclick={() => popup.close()}>{t("popup.notification.ok_button.text")}</button>
    </div>
</PopupBase>