<script lang="ts">
    import PopupBase from "./PopupBase.svelte";
    import { WaitPopup } from "$lib/types/popup";
    import { deployProgress } from "$lib/state/deployProgress.svelte";
    
    let { popup }: { popup: WaitPopup } = $props();
</script>

<PopupBase>
    <div
        class="w-6 h-6 rounded-full border-4 border-transparent border-b-yellow-300 animate-spin self-center"
    ></div>
    <span class="self-center">{popup.message}</span>
    {#if popup.live && deployProgress.text}
        <span class="self-center text-sm text-zinc-400 max-w-md text-center">{deployProgress.text}</span>
    {/if}
</PopupBase>