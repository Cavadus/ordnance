import { describe, expect, it } from 'vitest';
import '../../src/lib/button-state.js';

const { ButtonState } = globalThis.Ordnance;

describe('ButtonState', () => {
  it('starts in checking', () => {
    const s = new ButtonState();
    expect(s.state).toBe('checking');
    expect(s.label).toBe('Checking Ordnance…');
    expect(s.clickable).toBe(false);
  });

  it('goes to unreachable -> "Get Ordnance"', () => {
    const s = new ButtonState();
    s.setUnreachable();
    expect(s.label).toBe('Get Ordnance');
    expect(s.clickable).toBe(true);
  });

  it('not installed -> "Install with Ordnance"', () => {
    const s = new ButtonState();
    s.setQueryResult({ installed: false, updateAvailable: null });
    expect(s.label).toBe('Install with Ordnance');
  });

  it('installed, no update -> "Installed ✓"', () => {
    const s = new ButtonState();
    s.setQueryResult({ installed: true, updateAvailable: false });
    expect(s.label).toBe('Installed ✓');
  });

  it('installed with update available -> "Update with Ordnance"', () => {
    const s = new ButtonState();
    s.setQueryResult({ installed: true, updateAvailable: true });
    expect(s.label).toBe('Update with Ordnance');
  });

  it('installed with unknown update status is not treated as an update', () => {
    const s = new ButtonState();
    s.setQueryResult({ installed: true, updateAvailable: null });
    expect(s.label).toBe('Installed ✓');
  });

  it('installing -> "Installing…" and not clickable', () => {
    const s = new ButtonState();
    s.startInstalling();
    expect(s.label).toBe('Installing…');
    expect(s.clickable).toBe(false);
  });

  it('install success -> "Installed ✓"', () => {
    const s = new ButtonState();
    s.startInstalling();
    s.setInstalled();
    expect(s.label).toBe('Installed ✓');
    expect(s.clickable).toBe(true);
  });

  it('install error shows the friendly message', () => {
    const s = new ButtonState();
    s.startInstalling();
    s.setError("Ordnance couldn't be reached.");
    expect(s.state).toBe('error');
    expect(s.label).toBe("Ordnance couldn't be reached.");
    expect(s.clickable).toBe(true);
  });

  it('reset returns to checking', () => {
    const s = new ButtonState();
    s.setQueryResult({ installed: true, updateAvailable: false });
    s.reset();
    expect(s.state).toBe('checking');
  });

  it('Ordnance not running -> still "Install with Ordnance", with the "Ordnance will start" hint', () => {
    const s = new ButtonState();
    s.setAppNotRunning();
    expect(s.label).toBe('Install with Ordnance');
    expect(s.hint).toBe('Ordnance will start');
    expect(s.clickable).toBe(true);
    expect(s.updateAvailable).toBe(false);
  });

  it('clicking while Ordnance is not running -> "Starting Ordnance…", not clickable, busy', () => {
    const s = new ButtonState();
    s.setAppNotRunning();
    s.startInstalling();
    expect(s.state).toBe('starting');
    expect(s.label).toBe('Starting Ordnance…');
    expect(s.clickable).toBe(false);
    expect(s.busy).toBe(true);
    expect(s.hint).toBeNull();
    s.setInstalled();
    expect(s.label).toBe('Installed ✓');
    expect(s.appRunning).toBe(true);
  });

  it('clicking while Ordnance is running -> "Installing…" and no hint', () => {
    const s = new ButtonState();
    s.setQueryResult({ installed: false, updateAvailable: null });
    expect(s.hint).toBeNull();
    s.startInstalling();
    expect(s.label).toBe('Installing…');
    expect(s.busy).toBe(true);
  });
});

describe('ButtonState waiting (capture armed)', () => {
  it('shows "Click Download on this page…" at once, stays clickable, and holds off refreshes', () => {
    const s = new ButtonState();
    s.setQueryResult({ installed: false, updateAvailable: null });
    s.waitForDownload();
    expect(s.state).toBe('waiting');
    expect(s.label).toBe('Click Download on this page…');
    expect(s.hint).toBe(globalThis.Ordnance.buttonHints.WAITING_HINT);
    expect(s.clickable).toBe(true);
    expect(s.busy).toBe(true);
  });

  it('moves to Installing… once the download is caught', () => {
    const s = new ButtonState();
    s.setQueryResult({ installed: false, updateAvailable: null });
    s.waitForDownload();
    s.startInstalling();
    expect(s.label).toBe('Installing…');
  });

  it('moves to Starting Ordnance… when Ordnance was not running', () => {
    const s = new ButtonState();
    s.setAppNotRunning();
    s.waitForDownload();
    s.startInstalling();
    expect(s.label).toBe('Starting Ordnance…');
  });
});
