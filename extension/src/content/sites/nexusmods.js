/**
 * @file Nexus Mods content script.
 *
 * Nexus already draws a "Mod manager download" control (`#action-nmm`, and
 * the same label on each file). That is the button we brand: shield,
 * Ordnance yellow, and our label. Adding a second button left the Nexus
 * one reading "Mod manager download". Pages with only "Manual download"
 * still get a new list item after that link.
 *
 * The Files tab now draws those two buttons inside the open shadow root of
 * `<mod-download-modal placement="files_tab">`. They are real `<button>`s
 * with no href, so a light-DOM query never sees them. The header "Manual"
 * button is a different modal (`trigger="compact"`) and still gets the
 * sibling Ordnance button.
 *
 * These selectors were cross-checked against Arsenal's extension and
 * against Nexus's own button markup rather than a live fetch, because
 * nexusmods.com still serves Cloudflare's interactive challenge to
 * headless clients (see extension/test/fixtures/nexusmods-blocked.html).
 *
 * When neither anchor can be found (challenge page, logged-out variants,
 * modals), the mounts come back empty and the shared driver falls back to
 * the floating corner button.
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
  /** @param {Element} link */
  function isManualLink(link) {
    return /manual/i.test(link.textContent ?? '');
  }

  /** @param {Element} link */
  function inFileList(link) {
    if (link.closest && link.closest('.accordion-downloads')) return true;
    // The files-tab buttons live in the modal's shadow root. closest()
    // stops at that boundary, so check the host element too.
    const root = link.getRootNode && link.getRootNode();
    const host = root && root.host;
    if (!host || !host.closest) return false;
    if (host.closest('.accordion-downloads')) return true;
    return host.getAttribute('placement') === 'files_tab';
  }

  /**
   * Light-DOM querySelector does not enter an open shadow root. Nexus
   * paints the per-file buttons there.
   * @param {ParentNode} root
   * @returns {Element[]}
   */
  function collectControls(root) {
    const found = [];
    const visit = (node) => {
      if (!node || typeof node.querySelectorAll !== 'function') return;
      for (const el of node.querySelectorAll('a, button')) found.push(el);
      for (const el of node.querySelectorAll('*')) {
        if (el.shadowRoot) visit(el.shadowRoot);
      }
    };
    visit(root);
    return found;
  }

  /**
   * Nexus's mod-manager control. Already-claimed links are skipped so a
   * rescan does not brand them twice.
   * @param {Element} link
   */
  function isManagerLink(link) {
    if (!link || (link.tagName !== 'A' && link.tagName !== 'BUTTON')) return false;
    if (link.hasAttribute('data-ordnance-root') || link.hasAttribute('data-ordnance-adopt')) return false;
    if (link.closest('#action-ordnance')) return false;
    const li = link.closest('li');
    if (li && (li.id === 'action-nmm' || li.id === 'action-vortex')) return true;
    return /mod manager download/i.test(link.textContent ?? '');
  }

  /** @param {Document} doc @returns {HTMLElement|null} */
  function findAdoptedAction(doc) {
    const marked = doc.querySelector(
      '#action-nmm a[data-ordnance-root], #action-nmm a[data-ordnance-adopt], #action-nmm button[data-ordnance-root], #action-nmm button[data-ordnance-adopt], #action-vortex a[data-ordnance-root], #action-vortex a[data-ordnance-adopt], #action-vortex button[data-ordnance-root], #action-vortex button[data-ordnance-adopt]',
    );
    if (marked) return marked;
    return Array.from(doc.querySelectorAll('a[data-ordnance-adopt], a[data-ordnance-root], button[data-ordnance-adopt], button[data-ordnance-root]')).find((el) => !inFileList(el)) || null;
  }

  /** @param {Document} doc @returns {HTMLElement|null} */
  function findActionManager(doc) {
    const byId = doc.querySelector('#action-nmm a, #action-nmm button, #action-vortex a, #action-vortex button');
    if (byId && isManagerLink(byId)) return byId;
    return collectControls(doc).find((el) => isManagerLink(el) && !inFileList(el)) || null;
  }

  function findManualAction(doc) {
    const byId = doc.getElementById('action-manual');
    if (byId) return byId;
    const bars = new Set();
    for (const el of doc.querySelectorAll('[id^="action-"]')) {
      if (el.parentElement) bars.add(el.parentElement);
    }
    for (const bar of bars) {
      const link = Array.from(bar.querySelectorAll('a, button')).find((a) =>
        isManualLink(a),
      );
      if (link) return link;
    }
    const compact = doc.querySelector('mod-download-modal[trigger="compact"][file]');
    if (!compact) return null;
    const manual = Array.from(compact.querySelectorAll('a, button')).find(isManualLink);
    return manual || compact;
  }

  /**
   * The action-bar mount. Prefers Nexus's existing mod-manager link, which
   * the widget brands in place. Falls back to a new list item after Manual
   * download when that link is absent.
   * @param {Document} doc
   * @returns {HTMLElement|null}
   */
  function findInsertionPoint(doc) {
    if (!doc) return null;
    const existing = doc.getElementById('action-ordnance');
    if (existing) return existing;
    const adopted = findAdoptedAction(doc);
    if (adopted) return adopted;
    const manager = findActionManager(doc);
    if (manager) {
      manager.setAttribute('data-ordnance-adopt', '');
      return manager;
    }
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

  /**
   * File rows. Each "Mod manager download" link is claimed in place. A
   * row that only has Manual download gets a mount after that link, which
   * is the older Nexus markup.
   * @param {Document} doc
   * @returns {Array<HTMLElement>}
   */
  function findFileRowMounts(doc) {
    const mounts = [];
    for (const link of collectControls(doc)) {
      if (!isManagerLink(link) || !inFileList(link)) continue;
      link.setAttribute('data-ordnance-adopt', '');
      mounts.push(link);
    }
    const sections = Array.from(
      doc.querySelectorAll('.accordion-downloads dd[data-id]'),
    );
    for (const section of sections) {
      if (section.querySelector('[data-ordnance-file-mount], [data-ordnance-adopt], [data-ordnance-root]')) continue;
      const manual = Array.from(section.querySelectorAll('a, button')).find(isManualLink);
      if (!manual) continue;
      const mount = doc.createElement('span');
      mount.setAttribute('data-ordnance-file-mount', section.dataset.id || '');
      mount.style.cssText = 'display:inline-flex;align-items:center;';
      manual.insertAdjacentElement('afterend', mount);
      mounts.push(mount);
    }
    for (const list of doc.querySelectorAll('ul.accordion-downloads')) {
      if (list.querySelector('[data-ordnance-file-mount], [data-ordnance-adopt], [data-ordnance-root]')) continue;
      const manual = Array.from(list.querySelectorAll('a, button')).find(isManualLink);
      if (!manual) continue;
      const fileId = list.closest('dd[data-id]')?.dataset.id || '';
      const item = doc.createElement('li');
      item.setAttribute('data-ordnance-file-mount', fileId);
      list.prepend(item);
      mounts.push(item);
    }
    return mounts;
  }

  /**
   * All inline mounts for this page: the action bar's list item plus one
   * per file row. Empty when neither exists, in which case the shared
   * driver falls back to the floating corner button.
   * @param {Document} doc
   * @returns {Array<HTMLElement>}
   */
  function findInsertionPoints(doc) {
    if (!doc) return [];
    const points = [];
    const action = findInsertionPoint(doc);
    if (action) points.push(action);
    for (const mount of findFileRowMounts(doc)) points.push(mount);
    return points;
  }

  const adapter = {
    name: 'nexus',
    // Nexus paints `li > a` and ignores a shadow host in the row. The
    // branded anchor is what makes the button read as Ordnance.
    branded: true,
    findInsertionPoint,
    findInsertionPoints,
    // Deliberately never returns a URL: Nexus free downloads must be a
    // manual, human click on Nexus's own "Slow download" button.
    findDirectDownloadUrl: () => null,
  };
  Ordnance.siteAdapters = Ordnance.siteAdapters || {};
  Ordnance.siteAdapters.nexus = adapter;

  if (Ordnance.content) {
    // The action bar is server-rendered, but slow loads or page variants
    // can mean it isn't there the moment this script runs. Wait for it
    // briefly, then fall back to the floating corner button. Either way,
    // keep watching afterwards: Nexus renders the Files accordion
    // client-side, and each file row gets its own button as it appears.
    let started = false;
    let observer = null;
    let fallbackTimer = null;
    const start = () => {
      if (started) return;
      started = true;
      if (fallbackTimer) clearTimeout(fallbackTimer);
      Ordnance.content.runSiteAdapter(adapter);
      observer = new MutationObserver(() => {
        const mounts = findFileRowMounts(document);
        if (mounts.length) Ordnance.content.addSiteWidgets(adapter, mounts);
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
      // File buttons are created inside a shadow root after the modal tag
      // is already in the page. A document observer does not see that.
      const pullFiles = () => {
        const mounts = findFileRowMounts(document);
        if (mounts.length) Ordnance.content.addSiteWidgets(adapter, mounts);
      };
      const watchModal = (modal) => {
        if (!modal || modal.__ordnanceWatch) return;
        modal.__ordnanceWatch = true;
        const arm = () => {
          if (!modal.shadowRoot || modal.shadowRoot.__ordnanceWatch) return;
          modal.shadowRoot.__ordnanceWatch = true;
          const inner = new MutationObserver(pullFiles);
          inner.observe(modal.shadowRoot, { childList: true, subtree: true });
          pullFiles();
        };
        arm();
        let tries = 0;
        const timer = setInterval(() => {
          tries += 1;
          arm();
          if ((modal.shadowRoot && modal.shadowRoot.__ordnanceWatch) || tries > 40) clearInterval(timer);
        }, 250);
      };
      const watchModals = () => {
        for (const modal of document.querySelectorAll('mod-download-modal')) watchModal(modal);
      };
      watchModals();
      const modalObserver = new MutationObserver(watchModals);
      modalObserver.observe(document.documentElement, { childList: true, subtree: true });
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
