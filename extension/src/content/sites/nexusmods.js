/**
 * @file Nexus Mods content script.
 *
 * Button placement mirrors Arsenal's production extension (read from a
 * working install): the action bar on every mod page holds the "Manual
 * download" action as an `<li id="action-manual">` with an `<a>` inside,
 * and the one-click button belongs in a list item right after it. These
 * selectors were cross-checked against that verified markup rather than a
 * live fetch, because nexusmods.com still serves Cloudflare's interactive
 * challenge to headless clients (see extension/test/fixtures/
 * nexusmods-blocked.html for what those fetches return).
 *
 * When the action bar can't be found (challenge page, logged-out variants,
 * modals), `findInsertionPoint` returns null and the shared driver falls
 * back to the floating corner button.
 *
 * The download itself is still never automated: free Nexus downloads must
 * be a manual, human click on Nexus's own "Slow download" button. The
 * button arms capture the moment it's clicked, and the background installs
 * the next Nexus archive the browser downloads (see lib/capture.js),
 * however the user chooses to fetch it.
 */
/* global Ordnance */
(function initNexusMods() {
  'use strict';

  /**
   * Arsenal-verified lookup: the manual download action is
   * `<li id="action-manual">`. Page variants without the id are found by
   * scanning action-bar containers (elements holding an `id="action-*"`
   * sibling, such as the Download/Vortex buttons) for a link whose text
   * says "manual".
   * @param {Document} doc
   * @returns {HTMLElement|null}
   */
  function findManualAction(doc) {
    const byId = doc.getElementById('action-manual');
    if (byId) return byId;
    const bars = new Set();
    for (const el of doc.querySelectorAll('[id^="action-"]')) {
      if (el.parentElement) bars.add(el.parentElement);
    }
    for (const bar of bars) {
      const link = Array.from(bar.querySelectorAll('a')).find((a) =>
        /manual/i.test(a.textContent ?? ''),
      );
      if (link) return link;
    }
    return null;
  }

  /**
   * Places the button widget's container right after the manual download
   * action, matching Arsenal's own placement (`insertAdjacentElement`
   * "afterend" on the manual `<li>`).
   * @param {Document} doc
   * @returns {HTMLElement|null}
   */
  function findInsertionPoint(doc) {
    if (!doc) return null;
    const manual = findManualAction(doc);
    if (!manual) return null;
    const anchorPoint =
      manual.tagName === 'LI' ? manual : manual.closest('li') || manual;
    const li = doc.createElement('li');
    li.id = 'action-ordnance';
    li.style.cssText = 'display:inline-flex;align-items:center;';
    anchorPoint.insertAdjacentElement('afterend', li);
    return li;
  }

  const adapter = {
    name: 'nexus',
    findInsertionPoint,
    // Deliberately never returns a URL: Nexus free downloads must be a
    // manual, human click on Nexus's own "Slow download" button.
    findDirectDownloadUrl: () => null,
  };
  Ordnance.siteAdapters = Ordnance.siteAdapters || {};
  Ordnance.siteAdapters.nexus = adapter;

  if (Ordnance.content) {
    // The action bar is server-rendered, but slow loads or page variants
    // can mean it isn't there the moment this script runs. Wait for it
    // briefly, then fall back to the floating corner button.
    let started = false;
    let observer = null;
    let fallbackTimer = null;
    const start = () => {
      if (started) return;
      started = true;
      if (observer) observer.disconnect();
      if (fallbackTimer) clearTimeout(fallbackTimer);
      Ordnance.content.runSiteAdapter(adapter);
    };
    if (findManualAction(document)) {
      start();
    } else {
      observer = new MutationObserver(() => {
        if (findManualAction(document)) start();
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
      fallbackTimer = setTimeout(start, 4000);
    }
  }
})();
