/**
 * @vitest-environment jsdom
 * @vitest-environment-options {"url": "https://www.nexusmods.com/helldivers2/mods/123"}
 */
import { beforeAll, describe, expect, it } from 'vitest';

// Nexus pages mount several "Install with Ordnance" buttons: the action bar
// plus one per file row. They share one state machine, and the armed hint
// ("click the file's download button") shows only under the button the user
// clicked -- not under every one of them.

const onMessage = [];
const sent = [];
const clickListeners = [];

beforeAll(async () => {
  globalThis.chrome = {
    runtime: {
      sendMessage: async (msg) => {
        sent.push(msg.type);
        if (msg.type === 'ordnance:hello') return { ok: true };
        if (msg.type === 'ordnance:query') return { ok: true, installed: false };
        if (msg.type === 'ordnance:armCapture') return { ok: true, claimed: false };
        return { ok: true };
      },
      onMessage: { addListener: (fn) => onMessage.push(fn) },
    },
    storage: { local: {} },
  };
  const addEventListener = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function patched(type, fn, opts) {
    if (type === 'click' && this.classList && this.classList.contains('ordnance-btn')) {
      clickListeners.push(fn);
    }
    return addEventListener.call(this, type, fn, opts);
  };
  for (const lib of ['browser-shim.js', 'sources.js', 'errors.js', 'button-state.js', 'capture.js']) {
    await import('../../src/lib/' + lib);
  }
  await import('../../src/content/common.js');

  // Mirrors the real nexus adapter's mounts: the action-bar list item plus
  // one container per file row in the Files accordion.
  document.body.innerHTML =
    '<ul><li id="action-manual"></li></ul>' +
    '<div class="accordion-downloads"><dl>' +
    '<dd data-id="1"><a href="#">Manual download</a></dd>' +
    '<dd data-id="2"><a href="#">Manual download</a></dd>' +
    '</dl></div>';
  globalThis.Ordnance.content.runTestAdapter({
    name: 'nexus',
    findInsertionPoints: (doc) => {
      const li = doc.createElement('li');
      li.id = 'action-ordnance';
      doc.getElementById('action-manual').insertAdjacentElement('afterend', li);
      const mounts = [];
      for (const dd of doc.querySelectorAll('dd[data-id]')) {
        const span = doc.createElement('span');
        span.setAttribute('data-ordnance-file-mount', dd.dataset.id);
        dd.querySelector('a').insertAdjacentElement('afterend', span);
        mounts.push(span);
      }
      return [li, ...mounts];
    },
    findDirectDownloadUrl: () => null,
  });
  await flush();
});

const flush = () => new Promise((r) => setTimeout(r, 20));
const labels = () =>
  [...document.querySelectorAll('[data-ordnance-root]')].map(
    (host) => host.shadowRoot.querySelector('.ordnance-label').textContent,
  );
const visibleHints = () =>
  [...document.querySelectorAll('[data-ordnance-root]')]
    .map((host) => host.shadowRoot.querySelector('.ordnance-hint'))
    .filter((hint) => !hint.hidden);

describe('multiple buttons on one page', () => {
  it('mounts one button per container, sharing one state', () => {
    expect(labels()).toEqual([
      'Install with Ordnance',
      'Install with Ordnance',
      'Install with Ordnance',
    ]);
  });

  it('shows the armed hint only under the clicked button', async () => {
    await clickListeners[1]({ isTrusted: true }); // first file row
    await flush();
    expect(labels()).toEqual([
      'Click Download on this page…',
      'Click Download on this page…',
      'Click Download on this page…',
    ]);
    expect(visibleHints().length).toBe(1);
  });

  it('still installs and updates every button together', async () => {
    onMessage.forEach((fn) =>
      fn({
        type: 'ordnance:captureStarted',
        site: 'nexus',
        broadcast: true,
        pageUrl: 'https://www.nexusmods.com/helldivers2/mods/123',
      }),
    );
    await flush();
    expect(labels()).toEqual(['Installing…', 'Installing…', 'Installing…']);
  });
});
