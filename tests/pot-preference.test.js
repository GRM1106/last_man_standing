import { JSDOM } from 'jsdom';
import { beforeEach, afterEach, it, expect, vi } from 'vitest';
import { readPotPreference, savePotPreference, preferredPot } from '../pot-preference.js';
let dom;
beforeEach(() => { dom = new JSDOM('', {url:'http://localhost'}); vi.stubGlobal('window', dom.window); });
afterEach(() => { dom.window.close(); vi.unstubAllGlobals(); });
it('restores a valid saved pot after a new page has no current selection', () => {
  savePotPreference('alice', 'second');
  expect(preferredPot([{id:'first'},{id:'second'}], '', readPotPreference('alice'))).toBe('second');
});
it('isolates the saved preference between accounts and signed-out pages', () => {
  savePotPreference('alice', 'second');
  expect(readPotPreference('bob')).toBe('');
  expect(readPotPreference(null)).toBe('');
});
it('ignores a stale membership and removes preferences when no pots remain', () => {
  savePotPreference('alice', 'removed');
  expect(preferredPot([{id:'first'}], 'removed', readPotPreference('alice'))).toBe('first');
  savePotPreference('alice', preferredPot([], '', 'removed'));
  expect(readPotPreference('alice')).toBe('');
});
it('keeps an in-flight user selection ahead of an older saved preference', () => {
  expect(preferredPot([{id:'a'},{id:'b'}], 'b', 'a')).toBe('b');
});
it('works without browser storage', () => {
  Object.defineProperty(dom.window, 'localStorage', {get() { throw new Error('Storage disabled'); }});
  expect(() => savePotPreference('alice', 'a')).not.toThrow();
  expect(readPotPreference('alice')).toBe('');
  expect(preferredPot([{id:'a'}], '', '')).toBe('a');
});
