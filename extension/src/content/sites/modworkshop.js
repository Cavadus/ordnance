/**
 * @file ModWorkshop content script.
 *
 * Real DOM verified against a live fetch of
 * https://modworkshop.net/mod/50187 (a Nuxt SSR page -- unlike GameBanana,
 * the interesting content is server-rendered, not client-fetched). See
 * extension/test/fixtures/modworkshop-mod.html.
 *
 * Findings:
 *   - `a.download-button[href]` is a *direct* file link straight to
 *     `storage.modworkshop.net`, present in the initial HTML with no login
 *     required for this mod. Ordnance triggers `downloads.download()` on it
 *     directly -- no capture-arm needed here.
 *   - No machine-readable version field was found on the page (no
 *     JSON-LD `softwareVersion` equivalent), so `pageVersion` is left null
 *     for this site.
 */
/* global Ordnance */
(function initModWorkshop() {
  'use strict';

  /** @param {Document} doc @returns {Element|null} */
  function findDownloadAnchor(doc) {
    return doc.querySelector('a.download-button[href]');
  }

  /** @param {Document} doc @returns {Element|null} */
  function findInsertionPoint(doc) {
    const anchor = findDownloadAnchor(doc);
    return anchor ? anchor.parentElement : null;
  }

  /** @param {Document} doc @returns {string|null} */
  function findDirectDownloadUrl(doc) {
    const anchor = findDownloadAnchor(doc);
    return anchor ? anchor.href : null;
  }

  const adapter = { name: 'modworkshop', findInsertionPoint, findDirectDownloadUrl };
  Ordnance.siteAdapters = Ordnance.siteAdapters || {};
  Ordnance.siteAdapters.modworkshop = adapter;

  if (Ordnance.content) Ordnance.content.runSiteAdapter(adapter);
})();
