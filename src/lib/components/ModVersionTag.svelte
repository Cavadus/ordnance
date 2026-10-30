<script lang="ts">
    import { BoxArrowUpRight } from "svelte-bootstrap-icons";
    import { openUrl } from "@tauri-apps/plugin-opener";
    import { useLocalization } from "$lib/state/localization.svelte";
    import type { Mod } from "$lib/models/mod";

    const { t } = useLocalization();

    let { mod }: { mod: Mod } = $props();

    const source = $derived(mod.sourceLink);
</script>

{#if mod.version}
    <span class="text-xs font-medium rounded px-1.5 py-0.5 bg-zinc-700/60 text-zinc-300 shrink-0">{mod.version}</span>
{/if}
{#if source}
    <button
        type="button"
        class="inline-flex items-center gap-1 text-xs rounded px-1.5 py-0.5 bg-zinc-700/60 text-zinc-300 hover:bg-zinc-600/60 hover:text-white shrink-0 transition-colors"
        title={t("pages.mods.open_source_page", { name: source.name })}
        onclick={() => openUrl(source.url)}
    >
        <BoxArrowUpRight width="11" height="11" />
        <span>{source.name}</span>
    </button>
{/if}
