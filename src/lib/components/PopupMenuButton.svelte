<script lang="ts">
    import type { Snippet } from "svelte";
    import { ThreeDotsVertical } from "svelte-bootstrap-icons";
    import { windowResize, portal } from "$lib/actions";

    let isOpen = $state<boolean>(false);
    let x = $state<number>(0);
    let y = $state<number>(0);
    let button = $state<HTMLElement | null>(null);
    let popup = $state<HTMLElement | null>(null);

    let { children, insertTarget }: { children: Snippet, insertTarget?: string | HTMLElement } = $props();

    $effect(() => {
        if (!isOpen) return;
        function onPointerDown(e: PointerEvent) {
            const target = e.target as Node;
            if (button?.contains(target) || popup?.contains(target)) return;
            isOpen = false;
        }
        function onKeydown(e: KeyboardEvent) {
            if (e.key === "Escape") isOpen = false;
        }
        document.addEventListener("pointerdown", onPointerDown);
        document.addEventListener("keydown", onKeydown);
        return () => {
            document.removeEventListener("pointerdown", onPointerDown);
            document.removeEventListener("keydown", onKeydown);
        };
    });

    $effect(() => {
        if (!popup) return;
        const rect = popup.getBoundingClientRect();
        x = Math.min(x, window.innerWidth - rect.width - 8);
        y = Math.min(y, window.innerHeight - rect.height - 8);
    });

    function toggle() {
        isOpen = !isOpen;
        if (isOpen && button) {
            const rect = button.getBoundingClientRect();
            x = rect.left;
            y = rect.bottom + 4;
        }
    }
</script>

<button
    bind:this={button}
    class="hd2mm-button-nop p-2"
    class:border-yellow-300={isOpen}
    onclick={toggle}
>
    <ThreeDotsVertical class="block mx-auto" />
</button>
{#if isOpen}
    <div
        bind:this={popup}
        use:windowResize={() => isOpen = false}
        use:portal={insertTarget ?? "body"}
        class="fixed border-2 border-zinc-500 bg-zinc-800 drop-shadow-xl/50 transform-none m-0 z-40"
        style:top="{y}px"
        style:left="{x}px"
        onclickcapture={() => isOpen = false}
    >
        <div class="flex flex-col items-stretch popup-content">
            {@render children()}
        </div>
    </div>
{/if}
