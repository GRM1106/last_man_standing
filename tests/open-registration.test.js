import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';
import { describe, it, expect, vi } from 'vitest';

const source = file => readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
const settle = async () => { for (let n = 0; n < 6; n++) await Promise.resolve(); };
function page(file, session = null, sessionError = null) {
  const dom = new JSDOM(source(file === 'app.js' ? 'index.html' : 'waiting.html'));
  const replace = vi.fn();
  const auth = {
    getSession: vi.fn().mockResolvedValue({ data: { session }, error: sessionError }),
    onAuthStateChange: vi.fn(),
    signUp: vi.fn().mockResolvedValue({ data: { session: { user: { id: 'new-player' } } } }),
    signInWithPassword: vi.fn().mockResolvedValue({ error: null }),
  };
  const client = { auth, rpc: vi.fn() };
  vm.runInNewContext(source(file).replace(/^import .*;\n/gm, ''), {
    document: dom.window.document, FormData: dom.window.FormData,
    window: { location: { replace, origin: 'http://127.0.0.1:5173' } },
    createClient: () => client, DEPLOY_TARGET: 'local',
    SUPABASE_URL: 'http://127.0.0.1:55321', SUPABASE_PUBLISHABLE_KEY: 'local-test-key',
  });
  return { dom, auth, client, replace };
}
function submit(p) {
  const form = p.dom.window.document.querySelector('#email-registration');
  for (const [name, value] of Object.entries({ firstName: ' New ', lastName: ' Player ', email: 'new@example.test', password: 'local-password', phone: '' })) form.elements[name].value = value;
  form.dispatchEvent(new p.dom.window.Event('submit', { bubbles: true, cancelable: true }));
}
describe('open registration', () => {
  it('routes a newly authenticated registration directly to its dashboard without approval RPCs', async () => {
    const p = page('app.js'); await settle(); submit(p); await settle();
    expect(p.auth.signUp).toHaveBeenCalledWith(expect.objectContaining({ options: { data: { first_name: 'New', last_name: 'Player', full_name: 'New Player', phone: null } } }));
    expect(p.replace).toHaveBeenCalledWith('/dashboard.html');
    expect(p.client.rpc).not.toHaveBeenCalled();
  });
  it('restores an existing session directly to the dashboard', async () => {
    const p = page('app.js', { user: { id: 'player' } }); await settle();
    expect(p.replace).toHaveBeenCalledWith('/dashboard.html');
  });
  it('routes a sign-in auth event directly to the dashboard', async () => {
    const p = page('app.js'); await settle();
    p.auth.onAuthStateChange.mock.calls[0][0]('SIGNED_IN', { user: { id: 'player' } });
    expect(p.replace).toHaveBeenCalledWith('/dashboard.html');
  });
  it('preserves email verification when Auth requires it', async () => {
    const p = page('app.js'); await settle();
    p.auth.signUp.mockResolvedValue({ data: { session: null } }); submit(p); await settle();
    expect(p.replace).not.toHaveBeenCalled();
    expect(p.dom.window.document.querySelector('#auth-message').textContent).toContain('Check your email');
  });
  it('shows rejected registration errors and re-enables submission', async () => {
    const p = page('app.js'); await settle();
    p.auth.signUp.mockResolvedValue({ data: {}, error: { message: 'User already registered' } }); submit(p); await settle();
    expect(p.replace).not.toHaveBeenCalled();
    expect(p.dom.window.document.querySelector('#auth-message').textContent).toBe('User already registered');
    expect(p.dom.window.document.querySelector('button[type=submit]').disabled).toBe(false);
  });
  it.each([null, { user: { id: 'player' } }])('keeps the old waiting URL as a session-aware redirect: %j', async session => {
    const p = page('waiting.js', session); await settle();
    expect(p.replace).toHaveBeenCalledWith(session ? '/dashboard.html' : '/');
    expect(p.client.rpc).not.toHaveBeenCalled();
  });
  it('reports session errors on the compatibility route without displaying a false competition lock', async () => {
    const p = page('waiting.js', null, { message: 'Session unavailable' }); await settle();
    expect(p.replace).not.toHaveBeenCalled();
    expect(p.dom.window.document.querySelector('#account-message').textContent).toContain('sign in again');
  });
  it('removes account approval controls while retaining unrelated buy-back decisions', () => {
    expect(source('admin.js')).not.toMatch(/set_player_approval|Approve player|Revoke access|player\.approved/);
    expect(source('admin.js')).toContain('set_buy_back_decision');
    expect(source('index.html') + source('waiting.html')).not.toMatch(/Competition locked|competition access will be released|We’ll open the competition/);
  });
});
