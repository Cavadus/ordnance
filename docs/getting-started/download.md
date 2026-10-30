---
title: Download & install
---

# Download & install

## Get the download

All releases are published on the
[GitHub Releases page](https://github.com/Cavadus/ordnance/releases).

!!! warning "Release candidate"
    Releases are marked as pre-releases (`2.0.0-rc.17` and similar). Expect some rough edges, and back up any
    manually edited mod files before updating.

=== "Windows"

    Two options — pick one:

    - **Installer** (`Ordnance-<version>-windows-x64-setup.exe`): a normal per-user install with a Start Menu
      shortcut and a proper uninstaller. No administrator prompt — it installs for your user account only.
    - **Portable** (`Ordnance-<version>-windows-x64-portable.zip`): unzip it anywhere and run `ordnance.exe` directly, no
      install step. See [Data location](#data-location) below for what "portable" actually means here.

    Windows SmartScreen will likely warn about an unrecognized publisher the first time you run either one — these
    builds aren't code-signed yet. Click **"More info" → "Run anyway"**; this is expected for an unsigned
    community build, see [Troubleshooting](../help/troubleshooting.md#windows-smartscreen-warns-about-an-unknown-publisher).

    Either way, Ordnance needs [WebView2](https://developer.microsoft.com/microsoft-edge/webview2/) at runtime, which
    ships with Windows 11 and most up-to-date Windows 10 installs already. If it's missing, the installer offers
    to download it automatically.

=== "Linux"

    Four options, all for 64-bit x86. **[Installing on Linux](linux.md) has the full per-distro guide**, with the
    exact commands, dependencies, and fixes for a blank window or AppImage/FUSE errors.

    - **.rpm** (`Ordnance-<version>-linux-x86_64.rpm`): for Fedora, Nobara and openSUSE.

      ```sh
      sudo dnf install ./Ordnance-*-linux-x86_64.rpm
      ```

    - **.deb** (`Ordnance-<version>-linux-amd64.deb`): for Debian, Ubuntu, Mint and other `apt`-based distributions.

      ```sh
      sudo apt install ./Ordnance-*-linux-amd64.deb
      ```

    - **AppImage** (`Ordnance-<version>-linux-x86_64.AppImage`): the fallback for other distributions. It carries
      WebKitGTK itself and uses your desktop's graphics and font libraries. Make it executable and run it:

      ```sh
      chmod +x Ordnance-*-linux-x86_64.AppImage
      ./Ordnance-*-linux-x86_64.AppImage
      ```

    - **tar.gz** (`Ordnance-<version>-linux-x64.tar.gz`): just the `ordnance` binary plus a quick-start text file, for
      Arch/CachyOS or anyone who wants the plain binary. It needs your distribution's WebKitGTK 4.1 package
      (Arch: `webkit2gtk-4.1`, Fedora: `webkit2gtk4.1`, Debian/Ubuntu: `libwebkit2gtk-4.1-0`, openSUSE:
      `libwebkit2gtk-4_1-0`).

    The `.rpm` and `.deb` pull in their dependencies automatically. If Ordnance doesn't start, run it from a terminal
    to see why; see [Installing on Linux](linux.md#seeing-errors-run-it-from-a-terminal).

Check `SHA256SUMS.txt` on the release page if you want to verify your download.

## Data location

Where Ordnance keeps your mods, settings, profiles and logs depends on how you're running it:

- **Installed** (the Windows installer, the `.rpm`/`.deb`, or an AppImage run from a location that isn't writable) —
  Ordnance uses your OS's normal per-user application data directory: `%APPDATA%\com.cavadus.ordnance` on Windows,
  `~/.local/share/com.cavadus.ordnance` on Linux.
- **Portable** — Ordnance keeps everything in the same folder as its own executable instead. This is used
  automatically when either is true, *and* that folder is writable:
    - a `portable.txt` file sits next to the executable (already the case if you downloaded the Windows portable
      zip — it's included inside), or
    - the folder already has a `mods/` directory or `settings.json` file in it, from an older portable-only
      release.

  For an AppImage, "the same folder as its own executable" means the folder containing the `.AppImage` file
  itself, not the temporary location it's mounted at while running.

You can always check which one is active, and where, without guessing: open **Settings** and look at
**Data Folder**, which has an **Open Folder** button. The choice (and why) is also written to the
[log file](../help/logs.md) every time Ordnance starts.

Either way, you can move the data to any other folder or drive with **Change...** next to **Data Folder**. Ordnance
remembers that choice and uses it from then on; see [Data folder](../using/data-folder.md).

Moving to portable mode later: create an empty `portable.txt` next to the executable (or copy the one from a
portable download) and restart Ordnance — it'll start using that folder from then on. Note this does *not* move your
existing mods/settings for you; do that by hand first if you want to keep them (see **Open Folder** in Settings
to find where they currently are).

## Next step

Continue to [First-time setup](setup.md).
