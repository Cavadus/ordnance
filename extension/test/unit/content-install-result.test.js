/**
 * @vitest-environment jsdom
 * @vitest-environment-options {"url": "https://www.nexusmods.com/helldivers2/mods/123"}
 */
import { beforeAll, describe, expect, it } from 'vitest';

// With auto-capture on, the background sends an install's result to every
// open tab of the site. Only the tab of the mod that was installed may show
// it: a second Nexus tab for another mod must not turn "Installed ✓".

const onMessage = [];
const sent = [];
/** The button's click listener: jsdom can't make a trusted click, so tests call it directly. */
let clickListener;
let installed = false;

beforeAll(async () => {
  globalThis.chrome = {
    runtime: {
      sendMessage: async (msg) => {
        sent.push(msg.type);
        if (msg.type === 'ordnance:hello') return { ok: true };
        if (msg.type === 'ordnance:query') return { ok: true, installed };
        if (msg.type === 'ordnance:armCapture') return { ok: true, claimed: false };
        return { ok: true };
      },
      onMessage: { addListener: (fn) => onMessage.push(fn) },
    },
    storage: { local: {} },
  };
  const addEventListener = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function patched(type, fn, opts) {
    if (type === 'click' && this.classList && this.classList.contains('ordnance-btn')) clickListener = fn;
    return addEventListener.call(this, type, fn, opts);
  };
  for (const lib of ['browser-shim.js', 'sources.js', 'errors.js', 'button-state.js', 'capture.js']) {
    await import(`../../src/lib/${lib}`);
  }
  await import('../../src/content/common.js');
  globalThis.Ordnance.content.runTestAdapter({ name: 'nexus', findInsertionPoint: () => null, findDirectDownloadUrl: () => null });
  await flush();
});

const flush = () => new Promise((r) => setTimeout(r, 20));
const label = () => document.querySelector('[data-ordnance-root]').shadowRoot.querySelector('.ordnance-label').textContent;
const deliver = (message) => onMessage.forEach((fn) => fn(message));

describe('install results sent to every tab of a site', () => {
  it("leave another mod's tab alone, re-checking it instead", async () => {
    expect(label()).toBe('Install with Ordnance');
    const queries = sent.filter((t) => t === 'ordnance:query').length;
    deliver({
      type: 'ordnance:installResult',
      broadcast: true,
      pageUrl: 'https://www.nexusmods.com/helldivers2/mods/999',
      reply: { ok: true, type: 'installed', mod: { name: 'Other Mod' } },
    });
    await flush();
    expect(label()).toBe('Install with Ordnance');
    expect(sent.filter((t) => t === 'ordnance:query').length).toBe(queries + 1);

    deliver({ type: 'ordnance:installResult', broadcast: true, pageUrl: 'https://www.nexusmods.com/helldivers2/mods/999', reply: { ok: false, error: { code: 'DECLINED' } } });
    await flush();
    expect(label()).toBe('Install with Ordnance');
  });

  it("are shown on this mod's own tab", async () => {
    deliver({
      type: 'ordnance:installResult',
      broadcast: true,
      pageUrl: 'https://www.nexusmods.com/helldivers2/mods/123?tab=files',
      reply: { ok: true, type: 'installed', mod: { name: 'Cool Mod' } },
    });
    await flush();
    expect(label()).toBe('Installed ✓');
  });

  it('results sent to this tab alone are always shown', async () => {
    deliver({ type: 'ordnance:installResult', reply: { ok: false, error: { code: 'DECLINED' } } });
    await flush();
    expect(label()).toBe('You chose not to install this mod.');
  });
});

describe('while this tab waits on its own install', () => {
  const OTHER = 'https://www.nexusmods.com/helldivers2/mods/999';

  it("another mod's broadcast neither re-checks nor changes the button", async () => {
    await clickListener({ isTrusted: true });
    await flush();
    expect(label()).toBe('Click Download on this page…');
    const before = sent.length;
    deliver({ type: 'ordnance:installResult', broadcast: true, pageUrl: OTHER, reply: { ok: true, type: 'installed' } });
    await flush();
    expect(label()).toBe('Click Download on this page…');
    expect(sent.length).toBe(before);
  });

  it("another mod's broadcast capture doesn't move it to Installing, its own does", async () => {
    deliver({ type: 'ordnance:captureStarted', site: 'nexus', broadcast: true, pageUrl: OTHER });
    await flush();
    expect(label()).toBe('Click Download on this page…');
    deliver({ type: 'ordnance:captureStarted', site: 'nexus', broadcast: true, pageUrl: 'https://www.nexusmods.com/helldivers2/mods/123' });
    await flush();
    expect(label()).toBe('Installing…');
  });
});
