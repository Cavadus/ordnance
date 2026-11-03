/**
 * @file Shared "Install with Ordnance" button: shadow-DOM widget, state
 * rendering, and the per-page driver that wires a site adapter (see
 * content/sites/*.js) up to the background script.
 *
 * Ordnance brand: #FFC61A (yellow) on #0B0B0C (near-black), compact, obviously
 * not part of the host page. Isolated in a shadow root so no mod site's CSS
 * can bleed in (or be bled on).
 */
/* global Ordnance */
(function initContentCommon(root) {
  'use strict';

  const ORDNANCE_NS = (root.Ordnance = root.Ordnance || {});

  const DOCS_INSTALL_URL = 'https://github.com/Cavadus/ordnance#readme';

  const SVG_NS = 'http://www.w3.org/2000/svg';

  /**
   * Builds a small inline version of the shield-and-chevrons emblem, drawn
   * in `currentColor` so it always matches the button's label color (dark
   * on the yellow/green/blue/red buttons, yellow on the dark "Get Ordnance"
   * one), as real SVG DOM nodes (not `innerHTML`, so
   * there's nothing here for a store reviewer -- or `web-ext lint` -- to
   * flag as an unsanitized dynamic-markup assignment, even though every
   * value involved is a static constant).
   * @returns {SVGSVGElement}
   */
  function buildEmblem(size) {
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 512 512');
    svg.setAttribute('width', String(size));
    svg.setAttribute('height', String(size));
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('focusable', 'false');
    svg.setAttribute('class', 'ordnance-emblem');

    const shield = document.createElementNS(SVG_NS, 'path');
    shield.setAttribute('d', 'M256 40 L440 100 V250 C440 362 358 436 256 478 C154 436 72 362 72 250 V100 Z');
    shield.setAttribute('fill', 'none');
    shield.setAttribute('stroke', 'currentColor');
    shield.setAttribute('stroke-width', '28');
    svg.appendChild(shield);

    const chevrons = document.createElementNS(SVG_NS, 'g');
    chevrons.setAttribute('fill', 'none');
    chevrons.setAttribute('stroke', 'currentColor');
    chevrons.setAttribute('stroke-width', '30');
    chevrons.setAttribute('stroke-linejoin', 'miter');
    chevrons.setAttribute('stroke-linecap', 'butt');
    for (const points of ['164,282 256,226 348,282', '164,334 256,278 348,334']) {
      const chevron = document.createElementNS(SVG_NS, 'polyline');
      chevron.setAttribute('points', points);
      chevrons.appendChild(chevron);
    }
    svg.appendChild(chevrons);

    return svg;
  }

  const STYLE = `
    :host { all: initial; }
    .ordnance-btn {
      all: initial;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font: 600 13px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #FFC61A;
      color: #0B0B0C;
      border: 2px solid #0B0B0C;
      border-radius: 6px;
      padding: 7px 12px;
      cursor: pointer;
      white-space: nowrap;
      user-select: none;
      box-shadow: 0 1px 0 rgba(0,0,0,0.4);
    }
    .ordnance-emblem { flex: none; color: inherit; }
    .ordnance-btn:hover { background: #ffd24d; }
    .ordnance-btn:active { background: #e6b117; }
    .ordnance-btn[data-state="installing"],
    .ordnance-btn[data-state="checking"] { cursor: progress; opacity: 0.85; }
    .ordnance-btn[data-state="installed"] { background: #2ecc71; color: #0B0B0C; }
    .ordnance-btn[data-state="update"] { background: #3ba7ff; color: #0B0B0C; }
    .ordnance-btn[data-state="error"] { background: #ff5555; color: #1a0000; }
    .ordnance-btn[data-state="unreachable"] { background: #0B0B0C; color: #FFC61A; border-color: #FFC61A; }
    .ordnance-hint {
      all: initial;
      display: block;
      margin-top: 4px;
      font: 500 11px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      color: #cfcfcf;
      background: #0B0B0C;
      border: 1px solid #FFC61A;
      border-radius: 4px;
      padding: 4px 6px;
      max-width: 240px;
    }
    /* "all: initial; display: block" above would otherwise override the
       hidden attribute, leaving an empty hint bar under every button. */
    .ordnance-hint[hidden] { display: none; }
    .ordnance-floating {
      position: fixed;
      right: 16px;
      bottom: 16px;
      z-index: 2147483647;
      display: flex;
      flex-direction: column;
      align-items: flex-end;
    }
  `;

  /**
   * Nexus styles `li > a` as the action button and ignores anything else in
   * the row, which is why a shadow-DOM widget there never read as ours.
   * This is the in-page button, same shape Arsenal uses: a real anchor,
   * the emblem, and our own label.
   */
  const BRANDED_STYLE = `
    .ordnance-download-btn {
      display: inline-flex !important;
      flex-wrap: wrap;
      align-items: center !important;
      justify-content: flex-start !important;
      gap: 6px !important;
      background: #FFC61A !important;
      color: #0B0B0C !important;
      border: none !important;
      border-radius: 5px !important;
      font: 600 14px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif !important;
      padding: 7px 9px !important;
      text-decoration: none !important;
      text-shadow: none !important;
      cursor: pointer;
      position: relative;
      overflow: hidden;
      white-space: nowrap;
      user-select: none;
    }
    .ordnance-download-btn::before {
      content: '';
      position: absolute;
      inset: 0;
      background: #fff;
      opacity: 0;
      transition: opacity 0.2s ease-in-out;
    }
    .ordnance-download-btn:hover::before { opacity: 0.22; }
    .ordnance-download-btn:hover { box-shadow: 0 2px 4px rgba(0, 0, 0, 0.2); }
    .ordnance-download-btn > svg:not(.ordnance-emblem) { display: none !important; }
    .ordnance-download-btn .ordnance-emblem,
    .ordnance-download-btn .ordnance-label {
      position: relative;
      z-index: 1;
    }
    .ordnance-download-btn .ordnance-emblem {
      width: 18px !important;
      height: 18px !important;
      flex: none;
    }
    .ordnance-download-btn[data-state="installing"],
    .ordnance-download-btn[data-state="checking"] { cursor: progress; opacity: 0.85; }
    .ordnance-download-btn[data-state="installed"] { background: #2ecc71 !important; }
    .ordnance-download-btn[data-state="update"] { background: #3ba7ff !important; }
    .ordnance-download-btn[data-state="error"] { background: #ff5555 !important; color: #1a0000 !important; }
    .ordnance-download-btn[data-state="unreachable"] {
      background: #0B0B0C !important;
      color: #FFC61A !important;
    }
    .ordnance-download-btn .ordnance-hint {
      flex-basis: 100%;
      position: relative;
      z-index: 1;
      font: 500 11px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif !important;
      color: inherit !important;
      white-space: normal;
    }
    .ordnance-download-btn .ordnance-hint[hidden] { display: none !important; }
  `;

  function ensureBrandedStyle() {
    if (document.getElementById('ordnance-branded-style')) return;
    const style = document.createElement('style');
    style.id = 'ordnance-branded-style';
    style.textContent = BRANDED_STYLE;
    (document.head || document.documentElement).appendChild(style);
  }

  /**
   * `nmm=1` is Nexus telling the browser to hand the file to whatever app
   * registered the `nxm://` protocol. On this machine that app is Arsenal.
   * Drop the flag so the same popup does a normal browser download, which
   * is the one Ordnance captures.
   * @param {string} href
   * @returns {string|null}
   */
  function stripModManagerFlag(href) {
    if (!href || /^nxm:/i.test(href)) return null;
    let url;
    try {
      url = new URL(href, document.baseURI || 'https://www.nexusmods.com/');
    } catch {
      return null;
    }
    if (url.protocol === 'nxm:') return null;
    url.searchParams.delete('nmm');
    if (/^https?:/i.test(href)) return url.href;
    return `${url.pathname}${url.search}${url.hash}`;
  }

  /**
   * Prefer the nearby Manual download link. It is the same popup without
   * the mod-manager handoff. Otherwise use this link with `nmm` removed.
   * @param {HTMLElement} link
   * @returns {string|null}
   */
  function browserDownloadHref(link) {
    const scope = link.closest('ul, dd, mod-download-modal') || link.parentElement;
    if (scope) {
      for (const other of scope.querySelectorAll('a[href]')) {
        if (other === link) continue;
        if (!/manual/i.test(other.textContent || '')) continue;
        const href = stripModManagerFlag(other.getAttribute('href'));
        if (href) return href;
      }
    }
    return stripModManagerFlag(link.getAttribute('href') || '');
  }

  /** @param {HTMLElement} link */
  function pointAtBrowserDownload(link) {
    if (!link || link.tagName !== 'A') return;
    const href = browserDownloadHref(link);
    if (href) link.setAttribute('href', href);
  }

  /**
   * In-page Nexus button. `adopt` is Nexus's own "Mod manager download"
   * link: we brand that element instead of inserting a second one, and
   * point it at a normal browser download so `nxm://` does not open Arsenal.
   * With no element to adopt, the host is a new anchor.
   * @param {HTMLElement|null} adopt
   * @returns {ButtonWidget}
   */
  function createBrandedButton(adopt) {
    ensureBrandedStyle();
    const host = adopt || document.createElement('a');
    if (!adopt) host.href = '#';
    else pointAtBrowserDownload(host);
    host.classList.add('ordnance-download-btn');
    host.setAttribute('data-ordnance-root', '');
    host.removeAttribute('data-ordnance-adopt');
    if (!host.querySelector('.ordnance-emblem')) {
      host.insertBefore(buildEmblem(18), host.firstChild);
    }
    let label = host.querySelector('.ordnance-label') || host.querySelector('.flex-label');
    if (!label) {
      label = document.createElement('span');
      label.className = 'ordnance-label';
      host.appendChild(label);
    }
    label.classList.add('ordnance-label');
    if (!adopt) label.textContent = 'Ordnance download';
    let hint = host.querySelector('.ordnance-hint');
    if (!hint) {
      hint = document.createElement('span');
      hint.className = 'ordnance-hint';
      hint.hidden = true;
      host.appendChild(hint);
    }

    return {
      host,
      render(state) {
        host.dataset.state = state.state;
        label.textContent = state.label;
        host.setAttribute('aria-disabled', state.clickable ? 'false' : 'true');
      },
      setHint(text) {
        if (text) {
          hint.textContent = text;
          hint.hidden = false;
        } else {
          hint.hidden = true;
        }
      },
      onClick(handler) {
        host.addEventListener('click', (event) => {
          if (!event.isTrusted) return;
          // A link we created has nowhere to go. Nexus's own link must keep
          // its click, or the slow/fast page never opens. Rewrite it first:
          // `nmm=1` would hand the file to the registered nxm app.
          if (adopt) pointAtBrowserDownload(host);
          else {
            event.preventDefault();
            event.stopPropagation();
          }
          handler(event);
        }, true);
      },
    };
  }

  /**
   * @typedef {object} ButtonWidget
   * @property {HTMLElement} host - The element inserted into the page (a shadow host).
   * @property {(state: import('../lib/button-state.js').ButtonState) => void} render
   * @property {(hint: string|null) => void} setHint
   * @property {(handler: (event: MouseEvent) => void) => void} onClick
   */

  /**
   * Builds the shadow-DOM button widget. Does not insert it into the page.
   * @param {{floating?: boolean, branded?: boolean}} [opts]
   *   `branded` is the Nexus action-bar button: a real anchor with the
   *   emblem, not a shadow widget. Nexus paints `li > a` and skips the rest.
   * @returns {ButtonWidget}
   */
  function createButtonWidget(opts = {}) {
    if (opts.branded) return createBrandedButton(opts.adopt || null);
    const host = document.createElement('div');
    host.setAttribute('data-ordnance-root', '');
    if (opts.floating) host.className = 'ordnance-floating-host';

    // 'open' (not 'closed'): the shadow root still fully isolates the host
    // page's CSS from ours (and ours from it), which is the actual
    // isolation goal here. What 'closed' would additionally hide is JS
    // access to `.shadowRoot` itself -- but the real defense against a page
    // script driving our button is the `event.isTrusted` check in
    // onClick() below, which stops a synthetic/dispatched click regardless
    // of shadow mode. 'open' is also what lets devtools and test tooling
    // (Playwright's locators, which cannot pierce a closed root) inspect
    // the button normally.
    const shadow = host.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    style.textContent = STYLE;
    shadow.appendChild(style);

    const wrapper = document.createElement('div');
    if (opts.floating) wrapper.className = 'ordnance-floating';
    shadow.appendChild(wrapper);

    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'ordnance-btn';
    button.appendChild(buildEmblem(14));
    const label = document.createElement('span');
    label.className = 'ordnance-label';
    label.textContent = 'Ordnance download';
    button.appendChild(label);
    wrapper.appendChild(button);

    const hint = document.createElement('div');
    hint.className = 'ordnance-hint';
    hint.hidden = true;
    wrapper.appendChild(hint);

    return {
      host,
      render(state) {
        button.dataset.state = state.state;
        label.textContent = state.label;
        button.disabled = !state.clickable;
      },
      setHint(text) {
        if (text) {
          hint.textContent = text;
          hint.hidden = false;
        } else {
          hint.hidden = true;
        }
      },
      onClick(handler) {
        button.addEventListener('click', (event) => {
          // Security rule (bridge-protocol.md): only synthetic-click-proof,
          // user-generated clicks may drive an install. A page script
          // dispatching a fake click on our button (it can't reach inside
          // the shadow root anyway, but defense in depth) must be ignored.
          if (!event.isTrusted) return;
          handler(event);
        });
      },
    };
  }

  /**
   * @typedef {object} SiteAdapter
   * @property {string} name - Key into Ordnance.capture.SITE_HOSTS.
   * @property {(doc: Document) => Element|null} findInsertionPoint - Where
   *   to place the button inline; `null` means "use the floating fallback".
   * @property {(doc: Document) => string|null} [findDirectDownloadUrl] - A
   *   direct file URL already present on the page, if any.
   * @property {(doc: Document) => string|null} [scrapeVersion]
   */

  /**
   * Drives one mod page: detects it, builds the button, queries Ordnance, and
   * wires up clicks. No-ops if the current URL isn't a mod page for this
   * adapter.
   * @param {SiteAdapter} adapter
   */
  function runSiteAdapter(adapter) {
    const source = ORDNANCE_NS.sources.sourceFromPageUrl(location.href);
    if (!source || source.provider !== adapter.name) return;
    driveAdapter(adapter);
  }

  /**
   * Same driver as {@link runSiteAdapter}, without the
   * `sourceFromPageUrl` gate -- used only by the localhost
   * test-fixture adapter (never shipped in a release build; see
   * `includeLocalhost` in scripts/manifest.mjs) so the Playwright smoke
   * test can exercise the real button/query/install pipeline against a
   * page that isn't one of the five real mod-site hosts.
   * @param {SiteAdapter} adapter
   */
  function runTestAdapter(adapter) {
    driveAdapter(adapter);
  }

  /** Running drives, keyed by adapter object (one per adapter per page). */
  const drives = new Map();

  /**
   * A running drive: one shared state machine for every button an adapter
   * mounts on a page (the action bar plus one per file row on Nexus), a
   * single message listener, and one initial Ordnance check. Extra buttons
   * mounted later (client-side file lists) join the same drive.
   * @param {SiteAdapter} adapter
   */
  function createDrive(adapter) {
    const state = new ORDNANCE_NS.ButtonState();
    /** @type {Array<{widget: object, container: HTMLElement|null}>} */
    const widgets = [];
    const mountedContainers = new WeakSet();
    let armedWidget = null;
    /** @type {ReturnType<typeof setTimeout>|undefined} */
    let armExpiryTimer;
    let refreshed = false;

    const pageVersion = adapter.scrapeVersion ? adapter.scrapeVersion(document) : null;

    /** @param {object} message @returns {Promise<object>} */
    function send(message) {
      return ORDNANCE_NS.browserApi.runtime.sendMessage(message);
    }

    /**
     * Render the state, including its own hint ("Ordnance will start").
     * On pages with several buttons the hint belongs under the one the
     * user clicked; a lone button always shows it, exactly as before.
     */
    function render() {
      for (const entry of widgets) {
        entry.widget.render(state);
        const hint = widgets.length === 1 || entry.widget === armedWidget ? state.hint : null;
        entry.widget.setHint(hint);
      }
    }

    /** @param {string|null|undefined} pageUrl @returns {boolean} Whether it names this page's mod. */
    function isThisPagesMod(pageUrl) {
      const sources = ORDNANCE_NS.sources;
      return Boolean(pageUrl) && sources.isSameMod(sources.sourceFromPageUrl(pageUrl), sources.sourceFromPageUrl(location.href));
    }

    /**
     * Label the buttons from Ordnance's current state. Only ever *checks* --
     * hello/query never start Ordnance (the host launches it only for
     * install/open), so merely browsing a mod page can't pop Ordnance open.
     */
    async function refresh() {
      const hello = await send({ type: 'ordnance:hello' });
      // An install the user already clicked owns the buttons until its
      // result arrives; a late check must not overwrite that.
      if (state.busy) return;
      if (!hello || !hello.ok) {
        const code = hello && hello.error && hello.error.code;
        if (code === 'NATIVE_HOST_MISSING') {
          state.setUnreachable();
        } else {
          state.setAppNotRunning();
        }
        render();
        return;
      }
      const result = await send({ type: 'ordnance:query', pageUrl: location.href, pageVersion });
      if (state.busy) return;
      if (result && result.ok) {
        state.setQueryResult(result);
      } else {
        state.setAppNotRunning();
      }
      render();
    }

    /**
     * The armed install never happened; release the buttons and re-check.
     * Also driven from here (not only by the background's
     * `ordnance:captureExpired`), because a restarted service worker has lost
     * its timers.
     */
    function releaseArm() {
      clearTimeout(armExpiryTimer);
      if (state.state !== 'waiting') return;
      armedWidget = null;
      state.reset();
      render();
      refresh();
    }

    /** @param {object} widget @returns {Promise<void>} The click flow for one button. */
    async function click(widget) {
      if (state.state === 'unreachable') {
        window.open(DOCS_INSTALL_URL, '_blank', 'noopener');
        return;
      }
      if (!state.clickable) return;
      armedWidget = widget;

      const directUrl = adapter.findDirectDownloadUrl ? adapter.findDirectDownloadUrl(document) : null;
      if (directUrl) {
        state.startInstalling();
        render();
        await send({
          type: 'ordnance:installDirect',
          url: directUrl,
          pageUrl: location.href,
          pageVersion,
        });
        // The result arrives asynchronously via the 'ordnance:installResult'
        // runtime message once the browser download finishes.
        return;
      }

      // No direct link: arm capture. The label changes right away -- the
      // user can start the download at once, and however it's started
      // (the site's own button or any tool of theirs), the next archive
      // from this site is the one installed.
      state.waitForDownload();
      render();
      clearTimeout(armExpiryTimer);
      armExpiryTimer = setTimeout(releaseArm, ORDNANCE_NS.capture.DEFAULT_ARM_WINDOW_MS);
      const reply = await send({ type: 'ordnance:armCapture', site: adapter.name, pageUrl: location.href, pageVersion });
      if (reply && reply.claimed && state.state === 'waiting') {
        // The file had already finished downloading; it's installing now.
        state.startInstalling();
        render();
      }
    }

    ORDNANCE_NS.browserApi.runtime.onMessage.addListener((message) => {
      if (!message) return;
      if (message.broadcast && message.type === 'ordnance:captureStarted' && !isThisPagesMod(message.pageUrl)) {
        return;
      }
      if (message.type === 'ordnance:captureStarted' && message.site === adapter.name) {
        clearTimeout(armExpiryTimer);
        if (state.state === 'waiting') {
          state.startInstalling();
          render();
        }
      } else if (message.type === 'ordnance:installResult') {
        if (message.broadcast && !isThisPagesMod(message.pageUrl)) {
          // This result is for a different mod on the same site, not this
          // page's mod: re-check rather than showing it here.
          if (!state.busy) refresh();
          return;
        }
        clearTimeout(armExpiryTimer);
        if (message.reply && message.reply.ok) {
          state.setInstalled();
        } else {
          const err = message.reply && message.reply.error;
          state.setError(ORDNANCE_NS.errors.describeError(err && err.code, err && err.message));
        }
        render();
      } else if (message.type === 'ordnance:captureExpired' && message.site === adapter.name) {
        releaseArm();
      }
    });

    return {
      /** @returns {number} How many buttons this drive currently mounts. */
      count() {
        return widgets.length;
      },
      /**
       * Mounts one more button into a page container (or floats it when
       * the container is null). No-ops for a container that is already
       * mounted.
       * @param {HTMLElement|null} container
       */
      mount(container) {
        if (container && mountedContainers.has(container)) return;
        if (container) mountedContainers.add(container);
        const adopt = Boolean(container && container.hasAttribute('data-ordnance-adopt'));
        const widget = createButtonWidget({
          floating: !container,
          branded: Boolean(adapter.branded) && Boolean(container),
          adopt: adopt ? container : null,
        });
        if (adopt) {
          // The page already has this link. Branding it is the mount.
        } else if (container) container.appendChild(widget.host);
        else document.documentElement.appendChild(widget.host);
        widget.onClick(() => { void click(widget); });
        widgets.push({ widget, container });
        render();
      },
      /** Runs the first Ordnance check once, however buttons mount later. */
      start() {
        if (refreshed) return;
        refreshed = true;
        refresh();
      },
    };
  }

  /**
   * Drives one mod page: mounts the adapter's buttons (inline where the
   * adapter found page anchors, otherwise one floating button), queries
   * Ordnance, and wires up clicks. Re-driving the same adapter reuses the
   * running drive instead of creating duplicate buttons or listeners.
   * @param {SiteAdapter} adapter
   */
  function driveAdapter(adapter) {
    let drive = drives.get(adapter);
    if (!drive) {
      drive = createDrive(adapter);
      drives.set(adapter, drive);
    }
    const points = adapter.findInsertionPoints ? adapter.findInsertionPoints(document) : null;
    if (points && points.length) {
      for (const point of points) drive.mount(point);
    } else if (drive.count() === 0) {
      const single = adapter.findInsertionPoint ? adapter.findInsertionPoint(document) : null;
      drive.mount(single);
    }
    drive.start();
  }

  /**
   * Mounts additional page containers into an adapter's running drive --
   * for pages whose button anchors render after the first pass (Nexus's
   * client-side file list). Containers already mounted are skipped, and a
   * drive that never started (URL gate) is created through the same path
   * as {@link runSiteAdapter}.
   * @param {SiteAdapter} adapter
   * @param {Array<HTMLElement|null>} containers
   */
  function addSiteWidgets(adapter, containers) {
    let drive = drives.get(adapter);
    if (!drive) {
      runSiteAdapter(adapter);
      drive = drives.get(adapter);
    }
    if (!drive) return;
    for (const container of containers) drive.mount(container);
  }
  ORDNANCE_NS.content = { createButtonWidget, runSiteAdapter, runTestAdapter, addSiteWidgets, DOCS_INSTALL_URL };
})(typeof globalThis !== 'undefined' ? globalThis : this);
