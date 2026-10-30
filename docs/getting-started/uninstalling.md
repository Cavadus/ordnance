---
title: Uninstalling
---

# Uninstalling

How you uninstall Ordnance depends on how you installed it — see [Data location](download.md#data-location) if
you're not sure which of these applies to you.

## Installed with the Windows installer

1. If you have mods deployed, click **Purge** in Ordnance first to remove them from your Helldivers 2 `data` folder
   cleanly. (See [Deploy & purge](../using/deploy-purge.md) for exactly what this deletes.)
2. Uninstall Ordnance the normal Windows way — Start Menu → right-click Ordnance → Uninstall, or **Settings → Apps →
   Ordnance Mod Manager → Uninstall**.
3. The uninstaller removes the app itself, but *not* your data directory
   (`%APPDATA%\com.cavadus.ordnance`) — that's deliberate, in case you reinstall later. Delete that folder by
   hand afterward if you want your mods, settings and logs gone too. **Open Folder** next to **Data Folder** in
   Settings will take you straight there before you uninstall, if you want to check what's in it first.

## Installed with the .deb or .rpm (Linux)

1. **Purge** first, as above.
2. Remove the package. It's called `ordnance-mod-manager`, not `ordnance`:
    - .deb: `sudo apt remove ordnance-mod-manager`
    - .rpm: `sudo dnf remove ordnance-mod-manager` (openSUSE: `sudo zypper remove ordnance-mod-manager`)
3. As with the Windows installer, this doesn't delete `~/.local/share/com.cavadus.ordnance`. Remove it by hand
   if you want a completely clean removal.

## Portable (Windows zip, or an AppImage/tar.gz you didn't move to app data)

Ordnance doesn't run an installer in this case, so there's nothing to "uninstall" beyond removing the files:

1. **Purge** first, as above.
2. Close Ordnance and delete the folder you put it in — the executable, `portable.txt`, `mods/`, `settings.json`,
   `profiles.json`, and `logs/` all live there, so deleting the folder removes everything Ordnance created.

## If you moved the data folder

If you picked your own data folder with **Change...** in Settings (see [Data folder](../using/data-folder.md)),
your mods and settings are in *that* folder instead: delete it too if you want them gone. **Settings → Data
Folder** shows where it is. The small `ordnance-data-location.json` file that remembers the choice is next to the
executable (portable) or in `%APPDATA%\com.cavadus.ordnance.location` / `~/.config/com.cavadus.ordnance`
(installed), and on Windows possibly a second copy in `%APPDATA%\com.cavadus.ordnance`; delete them as well for a
completely clean removal.

In every case, your Helldivers 2 installation itself is never touched beyond the `data` folder changes
Deploy/Purge make (the deployed patch files and Ordnance's `.ordnance-deployed.json` record of them, both removed by Purge).
