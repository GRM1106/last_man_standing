import { JSDOM } from 'jsdom';
import { beforeEach, afterEach, expect, it, vi } from 'vitest';
import { createAccountClient } from '../account-client.js';
const sdk = vi.hoisted(() => ({ create: vi.fn() }));
vi.mock('@supabase/supabase-js', () => ({ createClient: (...args) => sdk.create(...args) }));
vi.mock('../config.js', () => ({ SUPABASE_URL: 'http://127.0.0.1:55321', SUPABASE_PUBLISHABLE_KEY: 'test' }));
let dom, session, notify, send, nativeFetch, navigate, context, auth;
const signedIn = id => ({ user: { id }, access_token: `token-${id}` });
const response = () => new Response(JSON.stringify({ ok: true }));
const endpoint = 'http://127.0.0.1:55321/rest/v1/rpc/confirm_team_pick';
beforeEach(async () => {
  dom = new JSDOM('<main><button>Action</button></main>', { url: 'http://localhost/' });
  vi.stubGlobal('window', dom.window); vi.stubGlobal('document', dom.window.document);
  session = signedIn('alice'); navigate = vi.fn(); nativeFetch = vi.fn(async () => response());
  auth = { getSession: vi.fn(async () => ({ data: { session } })), signOut: vi.fn(async () => { session = null; notify('SIGNED_OUT', null); }),
    onAuthStateChange: vi.fn(callback => { notify = callback; }) };
  sdk.create.mockImplementation((_url, _key, options) => { send = options.global.fetch; return { auth }; });
  context = createAccountClient({ navigate, fetchRequest: nativeFetch }).accountContext;
  await context.start();
});
afterEach(() => { dom.window.close(); vi.unstubAllGlobals(); });
it('keeps a same-account token refresh and pins requests to its current token', async () => {
  session = { ...signedIn('alice'), access_token: 'refreshed-token' }; notify('TOKEN_REFRESHED', session);
  expect(await context.currentAccount()).toBe('alice');
  expect((await send(endpoint, { method: 'POST', headers: { Authorization: 'Bearer older-token' } })).status).toBe(200);
  expect(nativeFetch.mock.calls[0][1].headers.get('Authorization')).toBe('Bearer refreshed-token');
  expect(navigate).not.toHaveBeenCalled();
});
it.each([['alice', 'bob'], ['bob', 'alice']])('invalidates a %s → %s replacement before notifying retained controls', async (from, to) => {
  if (from !== 'alice') { session = signedIn(from); context = createAccountClient({ navigate, fetchRequest: nativeFetch }).accountContext; await context.start(); }
  const cleared = vi.fn(() => expect(context.isCurrent(from)).toBe(false)); context.onInvalidate(cleared);
  session = signedIn(to); notify('SIGNED_IN', session);
  expect(cleared).toHaveBeenCalledOnce(); expect(document.body.inert).toBe(true);
  expect(await context.currentAccount()).toBe(null); expect(navigate).toHaveBeenCalledOnce();
});
it('detects a replacement from shared storage before the broadcast reaches this tab', async () => {
  session = signedIn('bob');
  expect(await context.currentAccount()).toBe(null);
  expect(navigate).toHaveBeenCalledOnce();
});
it('blocks a pending session read after logout arrives', async () => {
  let finish; auth.getSession.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const checking = context.currentAccount(); notify('SIGNED_OUT', null);
  finish({ data: { session: signedIn('alice') } });
  expect(await checking).toBe(null);
});
it('invalidates immediately when local logout starts, before the auth request finishes', async () => {
  let finish; auth.signOut.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const logout = context.signOut();
  expect(await context.currentAccount()).toBe(null); expect(context.isCurrent('alice')).toBe(false);
  finish(); await logout; expect(navigate).toHaveBeenCalledOnce();
});
it.each(['confirm_team_pick', 'request_pot_membership', 'claim_pot_payment', 'claim_buy_back', 'resolve_lms_review_case', 'set_pot_status'])(
  'does not dispatch a retained %s action as another account', async action => {
    session = signedIn('bob'); // Deliberately withhold the broadcast.
    const result = await send(`http://127.0.0.1:55321/rest/v1/rpc/${action}`, { method: 'POST', body: '{"selected_pot_id":"old-pot"}' });
    expect(result.status).toBe(401); expect(nativeFetch).not.toHaveBeenCalled();
  });
it('also blocks stale administrator edge-function invocations', async () => {
  session = signedIn('bob');
  expect((await send('http://127.0.0.1:55321/functions/v1/lms-scheduler', { method: 'POST' })).status).toBe(401);
  expect(nativeFetch).not.toHaveBeenCalled();
});
it('rejects a response from the previous account even before its auth event arrives', async () => {
  let finish; nativeFetch.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const request = send(endpoint, { method: 'POST' });
  await vi.waitFor(() => expect(finish).toBeTypeOf('function'));
  session = signedIn('bob'); finish(response());
  expect((await request).status).toBe(401);
  expect(nativeFetch.mock.calls[0][1].headers.get('Authorization')).toBe('Bearer token-alice');
});
it('leaves authentication requests available during invalidation', async () => {
  notify('SIGNED_OUT', null);
  expect((await send('http://127.0.0.1:55321/auth/v1/logout', { method: 'POST' })).status).toBe(200);
  expect(nativeFetch).toHaveBeenCalledOnce();
});
it('fails closed when session resolution returns an error', async () => {
  auth.getSession.mockResolvedValueOnce({ error: { message: 'Unavailable' }, data: { session: null } });
  expect(await context.currentAccount()).toBe(null); expect(navigate).toHaveBeenCalledOnce();
});
it('does not bind a stale initial session if a replacement event arrived while loading it', async () => {
  let finish; auth.getSession.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  context = createAccountClient({ navigate, fetchRequest: nativeFetch }).accountContext;
  const initialising = context.start(); notify('SIGNED_IN', signedIn('bob'));
  finish({ data: { session: signedIn('alice') } });
  expect(await initialising).toBe(null); expect(context.isCurrent('alice')).toBe(false);
});
