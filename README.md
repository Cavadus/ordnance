# Ordnance

*One sealed swap. Every enabled mod.*

Ordnance is a Helldivers 2 mod manager for the game after the October 2026 Easy Anti-Cheat update. Version **0.1.0**.

It reads the mods you have enabled, copies their patch files into `data/`, and merges settings-table edits into **one sealed `.dl_bin` per table**. A later mod wins when two edits hit the same field. Purge restores the game files from the stock backup. It does not delete them.

The window mark is a brass cartridge, crimped shut, on a black square.

Linux build: [ordnance-0.1.0-linux-x64.tar.gz](https://47th.info/hd2-mods/ordnance-0.1.0-linux-x64.tar.gz). Unpack it, `chmod +x ordnance`, and run it. It needs WebKitGTK 4.1.

## What it deploys

- **Patch files.** `<hex>.patch_N`, plus the matching `.gpu_resources` and `.stream` sidecars, are copied into the game `data/` tree.
- **Settings tables.** Edits to `generated_*.dl_bin` (entities, projectiles, damage, explosions, stratagems, and the rest) are applied onto stock, hash-corrected, and resealed. Two mods that change the same table become one file.
- **Boot scripts.** The game runs one `boot` resource, from the highest patch that carries it. If a loader such as Chef Shared Loader is enabled, that loader stays the highest boot and the other boot scripts stay below it. With no loader, two or more boot scripts are joined into one so the highest patch still runs all of them.

A mesh, a bank, or a LuaJIT bundle that only shares a filename with the boot archive is copied beside it. It is not pasted into the boot script.

## Installing mods

Add a `.zip`, `.7z`, or `.rar`, a plain folder, or a direct download link. No mod-site account is required.

The browser extension puts an **Install with Ordnance** button on AyakaMods, Nexus Mods, ModWorkshop, GameBanana, and GitHub mod pages.

- [Chrome, Brave, and Edge](https://47th.info/hd2-mods/ordnance-extension-chrome-1.0.1.zip)
- [Firefox](https://47th.info/hd2-mods/ordnance-extension-firefox-1.0.1.zip)

Load the unpacked extension. A mod page that does not serve the archive directly opens in the browser, and Ordnance picks the file up from your Downloads folder when it lands.

A mod's `manifest.json` may list where it lives:

```json
{
  "Version": 1,
  "Guid": "d9a4b449-98de-4a9e-b20e-28a188e57054",
  "Name": "Example Mod",
  "Options": [{ "Name": "Default", "Include": ["files"] }],
  "Sources": [
    { "Provider": "nexus", "Id": "123" },
    { "Provider": "github", "Id": "someone/example-mod" }
  ]
}
```

A version 4 manifest with that same shape is read as version 1. The `Guid` has to be a real UUID. The legacy `NexusData` field is still accepted.

An install from a URL records the origin in `.hd2mm-origin.json` next to the manifest. That name is kept so older tools still find it. Deleting the sidecar does not change the mod.

## Building

[pnpm](https://pnpm.io/), a stable [Rust toolchain](https://rustup.rs/), and on Linux the Tauri packages:

```sh
sudo apt install -y libwebkit2gtk-4.1-dev build-essential curl wget file libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev
```

```sh
pnpm install
pnpm tauri build
```

`pnpm tauri dev` runs it with hot reload. The crate is still named `ordnance`, so the raw build output is `ordnance` (`ordnance.exe` on Windows). The published Linux archive renames that binary to `ordnance`.

## Credits and license

Apache-2.0.

Ordnance is a fork of [Democracy Defender Mod Manager](https://github.com/katsyk/DemocracyDefenderModManager) by katsyk, which is derived from [Helldivers 2 Mod Manager](https://github.com/teutinsa/Helldivers2ModManager) by teutinsa. Both are Apache-2.0.

Original site: https://teutinsa.github.io/hd2mm-site · https://ko-fi.com/teutinsa
