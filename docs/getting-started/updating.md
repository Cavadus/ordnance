---
title: Updating Ordnance
---

# Updating Ordnance

Updating Ordnance doesn't touch your mods, settings, or profiles — those live in your
[data folder](download.md#data-location), separate from the app itself either way.

=== "Windows installer"

    Download and run the new `Ordnance-<version>-windows-x64-setup.exe` from the
    [releases page](https://github.com/Cavadus/ordnance/releases) — it installs over the
    existing one. Your data (in `%APPDATA%\com.cavadus.ordnance`) is untouched.

=== "Windows portable"

    1. Download the new `Ordnance-<version>-windows-x64-portable.zip`.
    2. Replace `ordnance.exe` in your existing portable folder with the new one (keep `portable.txt`,
       `settings.json`, `profiles.json`, `mods/`, and `logs/` where they are).
    3. Run it as usual.

=== "Linux .deb"

    ```sh
    sudo apt install ./Ordnance-<version>-linux-amd64.deb
    ```

    Your data (in `~/.local/share/com.cavadus.ordnance`) is untouched.

=== "Linux .rpm"

    ```sh
    sudo dnf install ./Ordnance-<version>-linux-x86_64.rpm
    ```

    (openSUSE: `sudo zypper install --allow-unsigned-rpm ./Ordnance-<version>-linux-x86_64.rpm`.) Your data (in
    `~/.local/share/com.cavadus.ordnance`) is untouched.

=== "Linux AppImage / tar.gz"

    Download the new file and replace the old one. If you're running it portably (a `portable.txt` sits next to
    it, or it already had `mods/`/`settings.json` next to it), keep those files alongside the new binary the same
    way as the Windows portable case above.

There is no in-app auto-updater; check the releases page for new versions.

!!! tip
    Not sure which case applies to you, or where your data actually lives? Open **Settings** and check
    **Data Folder** — see [Data location](download.md#data-location) for the full rules.
