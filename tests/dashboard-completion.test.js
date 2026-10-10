import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const client = vi.hoisted(() => ({ auth: { getSession: vi.fn(), onAuthStateChange: vi.fn() }, rpc: vi.fn() }));
vi.mock('@supabase/supabase-js', () => ({ createClient: () => client }));
vi.mock('../config.js', () => ({ SUPABASE_URL: 'http://127.0.0.1:55321', SUPABASE_PUBLISHABLE_KEY: 'test' }));
vi.mock('../maintenance.js', () => ({ watchMaintenance: () => ({ ready: Promise.resolve() }) }));
vi.mock('../account-client.js', async original => {
  const actual = await original();
  return { createAccountClient: () => actual.createAccountClient({ navigate: vi.fn() }) };
});

const pot = { id: 'completed', name: 'Completed pot', status: 'complete', player_status: 'winner', entry_fee_pence: 1000, buy_back_fee_pence: 500 };
const original = { winner_count: 1, total_prize_pence: 2000, resolution_rule: 'gw38_survivors', winners: [{ name: 'Original winner', is_me: true, prize_share_pence: 2000 }] };
const revision = number => ({ revision: number, decided_at: '2026-09-27T12:00:00Z', total_prize_pence: 2000,
  winners: [{ name: `Revised winner ${number}`, is_me: false, prize_share_pence: 2000 }], reason: 'Private reason must never appear', evidence: 'private-evidence' });
let dom, ui, outcome, completion;
const reply = name => {
  if (name === 'get_my_dashboard') return { data: { pots: [pot] } };
  if (name === 'get_available_pots') return { data: [] };
  if (name === 'get_pot_completion') return completion;
  if (name === 'get_my_pot_review_outcome') return outcome;
  return { error: { message: 'Unrelated panel' } };
};
const panel = () => document.querySelector('.completion-summary');
const defer = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules();
  dom = new JSDOM(readFileSync(new URL('../dashboard.html', import.meta.url), 'utf8'), { url: 'http://localhost/dashboard.html' });
  vi.stubGlobal('window', dom.window); vi.stubGlobal('document', dom.window.document); vi.stubGlobal('Option', dom.window.Option);
  client.auth.getSession.mockResolvedValue({ data: { session: { user: { id: 'member' }, access_token: 'test' } } });
  client.auth.onAuthStateChange.mockClear(); client.rpc.mockClear();
  completion = { data: structuredClone(original) }; outcome = { data: null };
  client.rpc.mockImplementation(async name => reply(name));
  ui = await import('../dashboard.js');
  await vi.waitFor(() => expect(panel()?.textContent).toContain('Original winner'));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); dom.window.close(); vi.unstubAllGlobals(); });

describe('authoritative player completion', () => {
  it('checks for adjudication and displays the original only when no revision exists', () => {
    expect(client.rpc).toHaveBeenCalledWith('get_my_pot_review_outcome', { selected_pot_id: pot.id });
    expect(panel().textContent).toContain('Your share: £20.00');
    expect(panel().textContent).not.toContain('Revised result');
  });
  it('uses the latest safe winner decision without changing the original result', async () => {
    outcome = { data: revision(2) }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Revised winner 2'));
    expect(panel().textContent).not.toContain('Original winner');
    expect(panel().textContent).not.toContain('Your share');
    expect(panel().textContent).toContain('Revision 2');
    expect(panel().textContent).not.toMatch(/Private reason|private-evidence/);
    expect(completion.data).toEqual(original);
    expect(document.querySelector('.pot-player-status').textContent).toBe('Original result: Winner');
    expect(document.querySelector('.dashboard-summary').textContent).toContain('Original player status');
  });
  it('updates repeated corrections and revised prize shares', async () => {
    for (const number of [1, 2, 3]) {
      outcome = { data: { ...revision(number), winners: [{ name: 'First', is_me: true, prize_share_pence: 1000 }, { name: 'Second', is_me: false, prize_share_pence: 1000 }] } };
      await ui.loadDashboard(); await vi.waitFor(() => expect(panel()?.textContent).toContain(`Revision ${number}`));
      expect(panel().textContent).toContain('2 winners'); expect(panel().textContent).toContain('Your share: £10.00');
    }
    expect(completion.data).toEqual(original);
  });
  it.each(['returned error', 'rejected request'])('does not label originals current when adjudication lookup has a %s', async kind => {
    outcome = { error: { message: 'secret-token private review reason' } };
    if (kind === 'rejected request') client.rpc.mockImplementation(name => name === 'get_my_pot_review_outcome' ? Promise.reject(new Error('secret-token')) : Promise.resolve(reply(name)));
    await ui.loadDashboard(); await vi.waitFor(() => expect(panel()?.textContent).toContain('Couldn’t verify the current result'));
    expect(panel().textContent).not.toMatch(/Original winner|secret-token|private review/);
  });
  it('fails visibly on a malformed empty revision instead of falling back to superseded winners', async () => {
    outcome = { data: { ...revision(1), winners: [] } }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Couldn’t verify the current result'));
    expect(panel().textContent).not.toContain('Original winner');
  });
  it('requires an explicit successful null outcome before treating the original as current', async () => {
    outcome = {}; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Couldn’t verify the current result'));
    expect(panel().textContent).not.toContain('Original winner');
  });
  it.each([
    ['null entry', [null]], ['undefined entry', [undefined]],
    ['primitive entry', ['Winner']], ['array entry', [['Winner']]],
    ['missing name', [{ prize_share_pence: 2000 }]],
    ['missing share', [{ name: 'Invalid winner' }]],
    ['missing winners', undefined], ['null winners', null],
    ['object instead of array', { name: 'Invalid winner' }],
  ])('rejects malformed revised winners: %s', async (_label, winners) => {
    outcome = { data: { ...revision(1), winners } }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Couldn’t verify the current result'));
    expect(panel().textContent).not.toMatch(/Original winner|Invalid winner|Revision 1|Private reason|private-evidence/);
    expect(completion.data).toEqual(original);
  });
  it('rejects undefined outcome data rather than treating it as no adjudication', async () => {
    outcome = { data: undefined }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Couldn’t verify the current result'));
    expect(panel().textContent).not.toContain('Original winner');
  });
  it.each([false, 0, ''])('rejects a malformed falsy outcome (%s) when no original exists', async data => {
    completion = { data: null }; outcome = { data }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Couldn’t verify the current result'));
    expect(panel().textContent).not.toContain('Original winner');
  });
  it('removes the panel when both successful reads explicitly contain no result', async () => {
    outcome = { data: null }; completion = { data: null }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()).toBeNull());
    expect(document.querySelector('.dashboard-pot').textContent).not.toContain('Couldn’t verify');
  });
  it('recovers from malformed data to the latest safe decision without reviving originals', async () => {
    outcome = { data: { ...revision(1), winners: [null] } }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Couldn’t verify the current result'));
    outcome = { data: revision(3) }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Revised winner 3'));
    expect(panel().textContent).not.toMatch(/Couldn’t verify|Original winner|Private reason|private-evidence/);
    expect(completion.data).toEqual(original);
  });
  it('keeps a delayed current read pending until the authoritative reply arrives', async () => {
    const delayed = defer();
    client.rpc.mockImplementation(name => name === 'get_my_pot_review_outcome' ? delayed.promise : Promise.resolve(reply(name)));
    await ui.loadDashboard();
    expect(panel().textContent).toContain('Checking the current result');
    expect(panel().textContent).not.toContain('Original winner');
    delayed.resolve({ data: revision(2) }); await vi.advanceTimersByTimeAsync(0);
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Revised winner 2'));
    expect(panel().textContent).not.toContain('Original winner');
  });
  it('renders revised names as text and never imports private review fields into the DOM', async () => {
    outcome = { data: { ...revision(1), winners: [{ name: '<img src=x onerror=alert(1)>', is_me: true, prize_share_pence: 2000 }] } };
    await ui.loadDashboard(); await vi.waitFor(() => expect(panel()?.textContent).toContain('<img src=x onerror=alert(1)>'));
    expect(panel().querySelector('img')).toBeNull();
    expect(panel().textContent).not.toMatch(/Private reason|private-evidence/);
  });
  it('does not present a result when the original lookup is denied', async () => {
    completion = { error: { message: 'Private database detail' } }; await ui.loadDashboard();
    await vi.waitFor(() => expect(panel()?.textContent).toContain('Couldn’t verify the current result'));
    expect(panel().textContent).not.toContain('Private database detail');
  });
  it('discards delayed results after a newer dashboard refresh', async () => {
    const delayed = defer();
    client.rpc.mockImplementation(name => name === 'get_my_pot_review_outcome' ? delayed.promise : Promise.resolve(reply(name)));
    await ui.loadDashboard(); const oldPanel = panel();
    client.rpc.mockImplementation(async name => name === 'get_my_pot_review_outcome' ? { data: revision(3) } : reply(name));
    await ui.loadDashboard(); await vi.waitFor(() => expect(panel()?.textContent).toContain('Revision 3'));
    delayed.resolve({ data: revision(1) });
    // Drain the event loop and all released promise continuations, not just two microtasks.
    await vi.advanceTimersByTimeAsync(0);
    expect(panel().textContent).toContain('Revision 3'); expect(oldPanel.textContent).not.toContain('Revised winner 1');
  });
  it('discards a retained response when the account changes without a broadcast', async () => {
    const delayed = defer();
    client.rpc.mockImplementation(name => name === 'get_my_pot_review_outcome' ? delayed.promise : Promise.resolve(reply(name)));
    await ui.loadDashboard(); const oldPanel = panel();
    client.auth.getSession.mockResolvedValue({ data: { session: { user: { id: 'other-member' }, access_token: 'other' } } });
    delayed.resolve({ data: revision(1) });
    await vi.waitFor(() => expect(document.querySelector('#dashboard-content').hidden).toBe(true));
    expect(oldPanel.textContent).not.toContain('Revised winner 1');
  });
});
