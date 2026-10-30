<script lang="ts">
    import { openUrl } from "@tauri-apps/plugin-opener";
    import PopupBase from "./PopupBase.svelte";
    import { ErrorPopup } from "$lib/types/popup";
    import { useLocalization } from "$lib/state/localization.svelte";
    
    const { t } = useLocalization();

    let { popup }: { popup: ErrorPopup } = $props();

    let copied = $state(false);

    const fullError = $derived(`${popup.message}\n\n${popup.errorMessage}`);

    async function onCopy() {
        let ok = false;
        try {
            if (navigator.clipboard && window.isSecureContext) {
                await navigator.clipboard.writeText(fullError);
                ok = true;
            }
        } catch {
            // Fall through to the hidden-textarea trick.
        }
        if (!ok) {
            ok = fallbackCopy(fullError);
        }
        if (ok) {
            copied = true;
            setTimeout(() => (copied = false), 2000);
        }
    }

    function fallbackCopy(text: string): boolean {
        try {
            const ta = document.createElement("textarea");
            ta.value = text;
            ta.style.position = "fixed";
            ta.style.opacity = "0";
            document.body.appendChild(ta);
            ta.select();
            const ok = document.execCommand("copy");
            document.body.removeChild(ta);
            return ok;
        } catch {
            return false;
        }
    }

    function onReport() {
        const title = encodeURIComponent(`Bug report: ${popup.message.split("\n")[0].slice(0, 80)}`);
        const body = encodeURIComponent(
            `### What happened\n${popup.message}\n\n### Error details\n\`\`\`\n${popup.errorMessage}\n\`\`\``
        );
        openUrl(`https://github.com/Cavadus/ordnance/issues/new?title=${title}&body=${body}`);
    }
</script>

<PopupBase>
    <span class="text-red-500 text-xl font-blockletter self-center">{t("popup.notification.title.error")}</span>
    <p class="min-w-40 text-sm self-start whitespace-pre-wrap">{popup.message}</p>
    <pre class="min-w-40 px-2 py-1 bg-zinc-800 rounded text-sm self-start whitespace-pre-wrap font-mono">{popup.errorMessage}</pre>
    <div class="flex flex-row gap-1 self-end">
        <button class="ordnance-button" onclick={onCopy}>{copied ? t("popup.notification.copy_button.copied") : t("popup.notification.copy_button.text")}</button>
        <button class="ordnance-button" onclick={onReport}>{t("popup.notification.report_button.text")}</button>
        <button class="ordnance-button" onclick={() => popup.close()}>{t("popup.notification.ok_button.text")}</button>
    </div>
</PopupBase>