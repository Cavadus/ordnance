import { beforeAll, describe, expect, it } from 'vitest';

// The emblem used to be hard-coded Ordnance yellow, the same color as the
// button behind it, so it was invisible. It must follow the label color.
beforeAll(async () => {
  globalThis.chrome = { runtime: {}, storage: { local: {} } };
  await import('../../src/lib/browser-shim.js');
  await import('../../src/lib/sources.js');
  await import('../../src/lib/button-state.js');
  await import('../../src/content/common.js');
});

describe('Install with Ordnance button emblem', () => {
  it('brands Nexus\'s Mod manager download link in place', () => {
    const link = document.createElement('a');
    link.href = 'https://www.nexusmods.com/Core/Libs/Common/Widgets/ModRequirementsPopUp?id=1&nmm=1';
    const text = document.createElement('span');
    text.className = 'flex-label';
    text.textContent = 'Mod manager download';
    link.appendChild(text);
    link.setAttribute('data-ordnance-adopt', '');
    const widget = globalThis.Ordnance.content.createButtonWidget({ branded: true, adopt: link });
    expect(widget.host).toBe(link);
    expect(link.classList.contains('ordnance-download-btn')).toBe(true);
    expect(link.querySelector('.ordnance-emblem')).not.toBeNull();
    expect(link.hasAttribute('data-ordnance-adopt')).toBe(false);
    widget.render({ state: 'install', label: 'Ordnance download', clickable: true });
    expect(link.querySelector('.ordnance-label').textContent).toBe('Ordnance download');
    expect(link.getAttribute('href')).not.toMatch(/nmm=/);
    expect(link.getAttribute('href')).not.toMatch(/^nxm:/i);
  });

  it('uses the manual download url so the file is not handed to nxm', () => {
    const list = document.createElement('ul');
    const manager = document.createElement('a');
    manager.href = '/popup?id=9&nmm=1';
    manager.textContent = 'Mod manager download';
    manager.setAttribute('data-ordnance-adopt', '');
    const manual = document.createElement('a');
    manual.href = '/popup?id=9';
    manual.textContent = 'Manual download';
    list.append(manager, manual);
    const widget = globalThis.Ordnance.content.createButtonWidget({ branded: true, adopt: manager });
    expect(widget.host.getAttribute('href')).toBe('/popup?id=9');
  });

  it('lets Nexus open its download page from the adopted link', () => {
    const seen = [];
    const original = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function patched(type, fn, opts) {
      if (type === 'click') seen.push({ el: this, fn });
      return original.call(this, type, fn, opts);
    };
    try {
      const link = document.createElement('a');
      link.href = 'https://www.nexusmods.com/Core/Libs/Common/Widgets/ModRequirementsPopUp?id=1&nmm=1';
      link.setAttribute('data-ordnance-adopt', '');
      const widget = globalThis.Ordnance.content.createButtonWidget({ branded: true, adopt: link });
      widget.onClick(() => {});
      const ours = seen.find((entry) => entry.el === link);
      const event = {
        isTrusted: true,
        preventDefault() { this.defaultPrevented = true; },
        stopPropagation() { this.stopped = true; },
      };
      ours.fn(event);
      expect(event.defaultPrevented).toBeUndefined();
      expect(event.stopped).toBeUndefined();

      const created = globalThis.Ordnance.content.createButtonWidget({ branded: true });
      created.onClick(() => {});
      const createdListener = seen.find((entry) => entry.el === created.host);
      const blocked = {
        isTrusted: true,
        preventDefault() { this.defaultPrevented = true; },
        stopPropagation() { this.stopped = true; },
      };
      createdListener.fn(blocked);
      expect(blocked.defaultPrevented).toBe(true);
      expect(blocked.stopped).toBe(true);
    } finally {
      EventTarget.prototype.addEventListener = original;
    }
  });

  it('nexus button is an in-page anchor with the emblem and Ordnance download', () => {
    const widget = globalThis.Ordnance.content.createButtonWidget({ branded: true });
    expect(widget.host.tagName).toBe('A');
    expect(widget.host.shadowRoot).toBeNull();
    expect(widget.host.classList.contains('ordnance-download-btn')).toBe(true);
    expect(widget.host.querySelector('.ordnance-label').textContent).toBe('Ordnance download');
    const strokes = [...widget.host.querySelectorAll('[stroke]')].map((el) => el.getAttribute('stroke'));
    expect(strokes.length).toBeGreaterThan(0);
    for (const stroke of strokes) expect(stroke).toBe('currentColor');
    document.body.appendChild(widget.host);
    expect(document.getElementById('ordnance-branded-style')).not.toBeNull();
  });

  it.each([false, true])('is drawn in currentColor, never the button yellow (floating: %s)', (floating) => {
    const widget = globalThis.Ordnance.content.createButtonWidget({ floating });
    const svg = widget.host.shadowRoot.querySelector('.ordnance-btn svg');
    expect(svg).not.toBeNull();
    const strokes = [...svg.querySelectorAll('[stroke]')].map((el) => el.getAttribute('stroke'));
    expect(strokes.length).toBeGreaterThan(0);
    for (const stroke of strokes) expect(stroke).toBe('currentColor');
    expect(svg.outerHTML).not.toMatch(/#FFC61A/i);
  });
});
