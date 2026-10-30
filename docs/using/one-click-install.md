---
title: One-click install (browser extension)
---

# One-click install (browser extension)

The Ordnance browser extension adds an **Install with Ordnance** button to mod pages, so you never have to download a
file and then separately open Ordnance to add it — including on sites that require being logged in, like Nexus Mods
and AyakaMods. It talks to Ordnance over a private, local-only connection; the full technical contract is in
[Browser bridge protocol](../development/bridge-protocol.md) if you want the details.

## Install the browser extension

The Ordnance browser extension adds an **Install with Ordnance** button to mod pages on AyakaMods, Nexus
Mods, ModWorkshop, GameBanana and GitHub, plus a right-click **Install with Ordnance** on any download
link, on any site. It never collects any data -- see the extension's
[privacy policy](https://github.com/Cavadus/ordnance/blob/main/extension/PRIVACY.md)
for the details.

### Chrome, Edge, Brave

The extension isn't in the Chrome Web Store yet. Until it is:

1. Download `ordnance-extension-chrome-<version>.zip` from the [latest release](https://github.com/Cavadus/ordnance/releases).
2. Unzip it somewhere you'll keep it (don't delete the folder afterwards -- the browser loads the
   extension from it directly).
3. Open `chrome://extensions` (or `edge://extensions`, `brave://extensions`).
4. Turn on **Developer mode** (top right).
5. Click **Load unpacked** and select the unzipped folder.

The extension icon appears in your toolbar. Click it any time to check Ordnance's connection status.

### Firefox

The extension isn't signed by Mozilla (AMO) yet, so for now it can only be loaded **temporarily**
-- it disappears when Firefox restarts, and you'll need to reload it each session. Permanent
installation needs the AMO-signed version, which is coming soon.

1. Download `ordnance-extension-firefox-<version>.zip` from the [latest release](https://github.com/Cavadus/ordnance/releases) and unzip it.
2. Open `about:debugging#/runtime/this-firefox`.
3. Click **Load Temporary Add-on...** and select the `manifest.json` inside the unzipped folder.

### Using it

- **The button.** On a mod page, look for the **Install with Ordnance** button (near the site's own
  download button where possible; otherwise a small yellow-and-black button in the bottom corner of
  the page). Click it and Ordnance installs the mod. If the site needs you to click its own download
  control (a login-gated file, or Nexus's download buttons), the button changes straight away to
  **Click Download on this page...** -- start the download and Ordnance picks it up once it finishes.
  It doesn't matter how the download is started or whether it opens in another tab: the next mod
  file that site downloads within 10 minutes is the one installed. If the file already finished
  downloading just before you clicked the button, Ordnance picks that one up too, as long as the
  download itself shows it's this page's mod.
- **Right-click any download link**, on any site, and choose **Install with Ordnance** to send that
  file straight to Ordnance.
- **Auto-capture.** Open the extension popup and turn on auto-capture for a site to have every
  archive you download from it install automatically, with no button click at all. It's off by
  default everywhere.

### Button states

| Label | Meaning |
| --- | --- |
| Install with Ordnance | Not installed yet -- click to install. With the hint "Ordnance will start", Ordnance is closed: clicking starts it and installs in one go |
| Click Download on this page... | Waiting for the site's download -- start it on the page. Clicking again restarts the 10-minute wait |
| Starting Ordnance... | Ordnance is starting up for the install you clicked |
| Installing... | Working on it |
| Installed (check mark) | Already installed -- click to reinstall |
| Update with Ordnance | A newer version is available -- click to update |
| Get Ordnance | The extension can't find Ordnance on this computer -- click for setup help |

Just visiting a mod page never starts Ordnance. Only clicking the button (or **Start Ordnance** in the
extension's popup) does.

### Troubleshooting

**"Ordnance not found" / the button always says "Get Ordnance":** Open Ordnance at least once so it can
register itself with your browser, then in Ordnance go to **Settings -> Browser integration -> Repair**.
"Get Ordnance" means the browser couldn't find Ordnance's browser integration at all. A Ordnance that's
installed but closed shows "Install with Ordnance" with "Ordnance will start" instead.

**The button never appears on a mod page:** Make sure you're on an actual mod page (not a search or
listing page), and that the extension is enabled for that site in your browser's extension settings.
As a fallback, right-click the mod's download link and choose **Install with Ordnance**.

**A download never gets picked up:** Capture only lasts 10 minutes after you click the button, and
only recognizes archive files (`.zip`, `.7z`, `.rar`) from that site (including its known CDN
domains). If your download is a different format, use the right-click **Install with Ordnance** on the
link, or add the file manually in Ordnance.

**"The download didn't finish, so nothing was installed":** The browser download was cancelled
(for example by closing the "Save as" dialog), failed, or was blocked by the browser, so Ordnance never
got a file. Click the button again to retry. If you resume the download from your browser's
downloads list instead, Ordnance still installs it once it finishes. For a right-clicked link to a
different mod than the page you're on, this message appears as a notification instead of on the
page's button.

**Auto-capture results:** An auto-captured install shows its result on the button of that mod's own
page, when Ordnance can tell which page it came from. Otherwise, for example when the file came from a
CDN with no link back to a mod page, the result appears only as a notification, and other open
pages of the site just re-check their own status.

## How it works

1. You click **Install with Ordnance** (or **Update with Ordnance**, if a newer version is available) on a supported mod
   page.
2. The extension downloads the file using *your own, already-logged-in browser session* — Ordnance never asks for,
   stores, or sees your login for any site.
3. Once the download finishes, the extension hands the file to Ordnance through a native-messaging connection local
   to your machine.
4. **The first time** a site does this, Ordnance asks:

   > **Allow Browser Install?** — Allow the Ordnance browser extension to install mods from &lt;site&gt;?

   with **Always Allow**, **Just This Once**, and **Deny**. Choosing **Always Allow** skips this prompt for that
   site from then on — revocable any time in
   [Settings → Sites Allowed to Install Through the Extension](settings.md#sites-allowed-to-install-through-the-extension).
   A download the extension can't tie to any website is always asked about, naming the file, with no
   **Always Allow**.
5. Ordnance installs the mod exactly like [Add URL](adding-mods.md#add-url) would — if you already have this same file
   of the mod installed (an older version of it), it's updated in place instead of duplicated. Another file from the
   same mod page (a GameBanana variant, a Nexus Mods optional file) is installed alongside, never over the one you
   have.
6. Depending on [Settings → After a Browser Install](settings.md#after-a-browser-install), Ordnance then adds the mod
   to your library only, adds it to your active profile, or adds it and deploys immediately.
7. A small notification in the corner of the window reports what happened — installed, added to a profile,
   deployed, or (rarely) installed but with something to look at, like Helldivers 2 currently running.

## `ordnance://install` links

Any web page — a mod author's own site, a Discord message, a forum post — can link directly to an install without
needing the extension at all:

```
ordnance://install?url=https%3A%2F%2Fexample.com%2Fmods%2Fcool-mod.zip
```

Clicking one always shows a confirmation first ("A link wants to install a mod from &lt;site&gt;. Install?") —
unlike the extension, there's no "always allow" for these, since any page could contain one. Only `https://`
links are accepted; anything else is silently ignored. See
[For mod authors → Install button for your mod page](../authors/install-button.md) if you want to add one of
these to your own mod's page.

## Auto-import from Downloads

A separate, **opt-in, off by default** option: turn on
[Settings → Auto-import from Downloads](settings.md#auto-import-from-downloads) and Ordnance watches your Downloads
folder the whole time it's running (not just during a [browser handoff](mod-sites.md#how-the-browser-handoff-works))
for anything that looks like a Helldivers 2 mod archive — useful for sites the extension doesn't have a button on
yet. It never installs anything without you clicking **Install** (or **Install & Deploy**) on the notification
first, and it doesn't offer files the browser extension has already handed to Ordnance.

## Browser integration

Ordnance registers itself with your installed browsers automatically, every time it starts, so the extension can find
it. If a browser stops recognizing Ordnance (for example, after moving a portable install to a new folder), use
**Repair** next to that browser in
[Settings → Browser Integration](settings.md#browser-integration) — no reinstall needed.
