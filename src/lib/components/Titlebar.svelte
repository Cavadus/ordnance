<!--
  @component
  A window titlebar providing the standard buttons and drag functionality.
-->

<script lang="ts">
    import { getCurrentWindow } from "@tauri-apps/api/window";
    import { useLocalization } from "$lib/state/localization.svelte";
    import {
        DashLg,
        Fullscreen,
        XLg
    } from "svelte-bootstrap-icons";

    const { t } = useLocalization();
    const appWindow = getCurrentWindow();

    function close() {
        if (import.meta.env.DEV) appWindow.minimize();
        else appWindow.close();
    }
</script>

<div
    class="h-12 flex items-center justify-between pl-3 bg-zinc-950 border-b border-zinc-800"
    data-tauri-drag-region
>
    <div class="flex items-center h-full gap-1" data-tauri-drag-region>
        <img
            class="w-8 h-8 object-contain"
            src="images/ordnance.png"
            alt="Ordnance"
            data-tauri-drag-region
        />
        <span
            class="text-2xl leading-none text-amber-400 font-blockletter tracking-wide"
            data-tauri-drag-region>{t("app.title")}</span
        >
    </div>

    <div class="flex h-8 self-start">
        <button
            class="w-12 h-8 text-zinc-400 border-zinc-700 border-b border-l hover:border-amber-400 active:text-zinc-900 active:border-amber-400 active:bg-amber-400"
            onclick={() => appWindow.minimize()}
            aria-label="Minimize"
        >
            <DashLg class="block ml-auto mr-auto" width="24" height="24" />
        </button>
        <button
            class="w-12 h-8 text-zinc-400 border-zinc-700 border-b border-l hover:border-amber-400 active:text-zinc-900 active:border-amber-400 active:bg-amber-400"
            onclick={() => appWindow.toggleMaximize()}
            aria-label="Maximize"
        >
            <Fullscreen class="block ml-auto mr-auto" width="24" height="24" />
        </button>
        <button
            class="w-12 h-8 text-zinc-400 border-zinc-700 border-b border-l hover:border-red-500 active:text-zinc-100 active:border-red-500 active:bg-red-500"
            onclick={close}
            aria-label="Close"
        >
            <XLg class="block ml-auto mr-auto" width="24" height="24" />
        </button>
    </div>
</div>
