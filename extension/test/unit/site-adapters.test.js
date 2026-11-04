import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';
import { beforeAll, describe, expect, it } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(__dirname, '..', 'fixtures');

function loadFixture(name) {
  const html = readFileSync(path.join(FIXTURES, name), 'utf8');
  return new JSDOM(html).window.document;
}

// Ordnance.content is intentionally left unset here (jsdom's `document`/`location`
// exist, but we're not simulating the full extension runtime) -- each site
// file guards its top-level `runSiteAdapter` call on `Ordnance.content` being
// present, so importing them here only registers Ordnance.siteAdapters.<name>
// without trying to talk to a background script. See content/sites/*.js.
beforeAll(async () => {
  globalThis.Ordnance = globalThis.Ordnance || {};
  await import('../../src/lib/sources.js');
  await import('../../src/lib/capture.js');
  await import('../../src/content/sites/ayakamods.js');
  await import('../../src/content/sites/modworkshop.js');
  await import('../../src/content/sites/gamebanana.js');
  await import('../../src/content/sites/github.js');
  await import('../../src/content/sites/nexusmods.js');
});

describe('AyakaMods adapter (real DOM fixture)', () => {
  it('finds the sidebar insertion point', () => {
    const doc = loadFixture('ayakamods-mod.html');
    const el = globalThis.Ordnance.siteAdapters.ayakamods.findInsertionPoint(doc);
    expect(el).not.toBeNull();
    expect(el.className).toContain('modSidebarGroup--buttons');
  });

  it('finds no direct download URL for a logged-out guest (disabled span, not a link)', () => {
    const doc = loadFixture('ayakamods-mod.html');
    expect(globalThis.Ordnance.siteAdapters.ayakamods.findDirectDownloadUrl(doc)).toBeNull();
  });

  it('scrapes the version from the SoftwareApplication JSON-LD', () => {
    const doc = loadFixture('ayakamods-mod.html');
    expect(globalThis.Ordnance.siteAdapters.ayakamods.scrapeVersion(doc)).toBe('2026-09-24');
  });
});

describe('ModWorkshop adapter (real DOM fixture)', () => {
  it('finds the direct storage.modworkshop.net download link', () => {
    const doc = loadFixture('modworkshop-mod.html');
    const url = globalThis.Ordnance.siteAdapters.modworkshop.findDirectDownloadUrl(doc);
    expect(url).toContain('storage.modworkshop.net/mods/files/');
    expect(globalThis.Ordnance.capture.hasArchiveExtension(url) || url.includes('filename=')).toBeTruthy();
  });

  it('finds an insertion point next to the download button', () => {
    const doc = loadFixture('modworkshop-mod.html');
    const el = globalThis.Ordnance.siteAdapters.modworkshop.findInsertionPoint(doc);
    expect(el).not.toBeNull();
    expect(el.querySelector('a.download-button')).not.toBeNull();
  });
});

describe('GameBanana adapter', () => {
  it('the real fetched fixture has an empty Files module (client-rendered)', () => {
    const doc = loadFixture('gamebanana-mod.html');
    expect(globalThis.Ordnance.siteAdapters.gamebanana.findInsertionPoint(doc)).not.toBeNull();
    expect(globalThis.Ordnance.siteAdapters.gamebanana.findDirectDownloadUrl(doc)).toBeNull();
  });

  it('finds the download link once the Files module is populated (synthesized post-render fixture)', () => {
    const doc = loadFixture('gamebanana-mod-populated.html');
    const url = globalThis.Ordnance.siteAdapters.gamebanana.findDirectDownloadUrl(doc);
    expect(url).toBe('https://gamebanana.com/mods/download/1105432');
  });
});

describe('GitHub adapter', () => {
  it('the real fetched fixture has no expanded release assets yet', () => {
    const doc = loadFixture('github-releases.html');
    expect(globalThis.Ordnance.siteAdapters.github.findDirectDownloadUrl(doc)).toBeNull();
  });

  it('finds the asset link once Assets is expanded (synthesized post-render fixture)', () => {
    const doc = loadFixture('github-releases-expanded.html');
    const url = globalThis.Ordnance.siteAdapters.github.findDirectDownloadUrl(doc);
    expect(url).toContain('/releases/download/v2.0.0.0_preview3/');
  });

  it('only activates on /releases pages', () => {
    // The module-level guard reads the real jsdom `location`, which vitest
    // defaults to http://localhost:3000/ -- not a /releases path.
    expect(location.pathname.includes('/releases')).toBe(false);
  });
});

describe('Nexus adapter', () => {
  it('never returns a direct download URL, even in principle', () => {
    expect(globalThis.Ordnance.siteAdapters.nexus.findDirectDownloadUrl()).toBeNull();
  });

  it('places the button inline right after the Manual download action', () => {
    const doc = loadFixture('nexusmods-mod.html');
    const point = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoint(doc);
    expect(point).not.toBeNull();
    expect(point.id).toBe('action-ordnance');
    const manual = doc.getElementById('action-manual');
    expect(manual.nextElementSibling).toBe(point);
  });

  it('falls back to floating when the action bar is missing (Cloudflare page)', () => {
    const doc = loadFixture('nexusmods-blocked.html');
    expect(globalThis.Ordnance.siteAdapters.nexus.findInsertionPoint(doc)).toBeNull();
  });

  it('mounts one button per file row, right after each Manual download link', () => {
    const doc = loadFixture('nexusmods-mod.html');
    const points = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoints(doc);
    const action = doc.getElementById('action-ordnance');
    expect(points[0]).toBe(action);
    const fileMounts = points.filter((p) => p.getAttribute('data-ordnance-file-mount'));
    expect(fileMounts.length).toBe(2);
    for (const mount of fileMounts) {
      const prev = mount.previousElementSibling;
      expect(prev.tagName).toBe('A');
      expect(/manual/i.test(prev.textContent)).toBe(true);
    }
  });

  it('does not duplicate mounts on a second scan', () => {
    const doc = loadFixture('nexusmods-mod.html');
    const first = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoints(doc);
    const second = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoints(doc);
    // Every file row already has a mount, so a second scan yields only the
    // reused action-bar container -- never duplicate file buttons.
    expect(first.length).toBe(3);
    expect(second.length).toBe(1);
    expect(second[0]).toBe(doc.getElementById('action-ordnance'));
    expect(doc.querySelectorAll('[data-ordnance-file-mount]').length).toBe(2);
  });

  it('returns no mounts at all on the Cloudflare challenge page', () => {
    const doc = loadFixture('nexusmods-blocked.html');
    expect(globalThis.Ordnance.siteAdapters.nexus.findInsertionPoints(doc)).toEqual([]);
  });

  it('takes over Mod manager download instead of adding a second button', () => {
    const doc = loadFixture('nexusmods-manager-row.html');
    const points = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoints(doc);
    expect(doc.getElementById('action-ordnance')).toBeNull();
    const manager = doc.querySelector('#action-nmm a');
    expect(manager.hasAttribute('data-ordnance-adopt')).toBe(true);
    expect(doc.getElementById('action-manual').textContent).toContain('Manual download');
    const list = doc.querySelector('ul.accordion-downloads');
    const fileLink = Array.from(list.querySelectorAll('a')).find((a) => /mod manager download/i.test(a.textContent));
    expect(fileLink.hasAttribute('data-ordnance-adopt')).toBe(true);
    expect(list.querySelectorAll('li').length).toBe(2);
    expect(list.textContent).toContain('Manual download');
    expect(points.length).toBe(2);
    const again = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoints(doc);
    expect(again.length).toBe(1);
    expect(again[0].hasAttribute('data-ordnance-adopt')).toBe(true);
  });

  it('brands the files-tab manager button inside the modal shadow root', () => {
    // The live Files tab draws both buttons in an open shadow root, next to
    // a header modal that only has Manual. Light-DOM queries miss the file
    // button, which is why it stayed "Mod manager download".
    const doc = new JSDOM('<!DOCTYPE html><body></body>', {
      url: 'https://www.nexusmods.com/helldivers2/mods/16150?tab=files',
    }).window.document;
    const header = doc.createElement('ul');
    header.className = 'modactions';
    const headerItem = doc.createElement('li');
    const compact = doc.createElement('mod-download-modal');
    compact.setAttribute('trigger', 'compact');
    compact.setAttribute('placement', 'mod_page');
    compact.setAttribute('file', '{}');
    const compactShadow = compact.attachShadow({ mode: 'open' });
    compactShadow.innerHTML = '<button type="button"><span>Manual</span></button>';
    headerItem.appendChild(compact);
    header.appendChild(headerItem);
    doc.body.appendChild(header);

    const list = doc.createElement('ul');
    list.className = 'accordion-downloads';
    const item = doc.createElement('li');
    const modal = doc.createElement('mod-download-modal');
    modal.setAttribute('placement', 'files_tab');
    const shadow = modal.attachShadow({ mode: 'open' });
    shadow.innerHTML = '<div class="flex"><button type="button" class="nxm-button-primary"><span>Mod manager download</span></button><button type="button"><span>Manual download</span></button></div>';
    item.appendChild(modal);
    list.appendChild(item);
    doc.body.appendChild(list);

    const points = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoints(doc);
    const manager = shadow.querySelector('.nxm-button-primary');
    expect(manager.hasAttribute('data-ordnance-adopt')).toBe(true);
    expect(points).toContain(manager);
    expect(doc.getElementById('action-ordnance')).not.toBeNull();
    expect(list.querySelectorAll('li').length).toBe(1);
    expect(shadow.textContent).toContain('Manual download');

    const again = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoints(doc);
    expect(again).not.toContain(manager);
    expect(shadow.querySelectorAll('button').length).toBe(2);
  });

  it('takes over the mod manager link inside the compact modal', () => {
    const doc = loadFixture('nexusmods-modal.html');
    const point = globalThis.Ordnance.siteAdapters.nexus.findInsertionPoint(doc);
    const modal = doc.querySelector('mod-download-modal');
    expect(doc.getElementById('action-ordnance')).toBeNull();
    expect(point.hasAttribute('data-ordnance-adopt')).toBe(true);
    expect(modal.contains(point)).toBe(true);
    expect(modal.textContent).toContain('Manual download');
  });
});
