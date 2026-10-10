import { createClient } from '@supabase/supabase-js';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './config.js';

// A document belongs to one account. A replacement account gets a fresh document,
// so retained controls, previews and async callbacks cannot acquire its authority.
export function createAccountClient({ navigate = () => window.location.replace('/'), fetchRequest = (...args) => fetch(...args) } = {}) {
  let accountId = null, invalid = false, observedAccount, starting;
  const listeners = new Set();
  const changedResponse = () => new Response(JSON.stringify({
    code: 'LMS_ACCOUNT_CHANGED', message: 'Your account changed. Reloading…',
  }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  function invalidate(redirect = true) {
    if (invalid) return;
    invalid = true;
    accountId = null;
    document.body.inert = true;
    for (const dialog of document.querySelectorAll('dialog[open]')) dialog.close('cancel');
    for (const listener of listeners) listener();
    if (redirect) navigate();
  }
  async function currentSession() {
    if (invalid || !accountId) return null;
    const { data, error } = await supabase.auth.getSession();
    if (invalid) return null;
    if (error || data?.session?.user?.id !== accountId) {
      invalidate();
      return null;
    }
    return data.session;
  }
  const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    global: { fetch: async (input, init) => {
      const url = new URL(typeof input === 'string' ? input : input.url || input.href);
      // Auth must remain available to resolve sessions and complete logout.
      if (url.origin !== new URL(SUPABASE_URL).origin || url.pathname.startsWith('/auth/v1/')) {
        return fetchRequest(input, init);
      }
      const session = await currentSession();
      if (!session) return changedResponse();
      // Pin the request to the checked account, even if the SDK obtained its
      // token before a cross-tab auth event arrived. The server still authorises it.
      const headers = new Headers(init?.headers || input.headers);
      headers.set('Authorization', `Bearer ${session.access_token}`);
      const response = await fetchRequest(input, { ...init, headers });
      return await currentSession() ? response : changedResponse();
    } },
  });
  supabase.auth.onAuthStateChange((_event, session) => {
    observedAccount = session?.user?.id || null;
    if (accountId && observedAccount !== accountId) invalidate();
  });
  const accountContext = {
    start() {
      starting ||= (async () => {
        const { data, error } = await supabase.auth.getSession();
        const id = data?.session?.user?.id;
        if (invalid) return null;
        if (error || !id || (observedAccount !== undefined && observedAccount !== id)) {
          invalidate();
          return null;
        }
        accountId = id;
        return id;
      })();
      return starting;
    },
    async currentAccount() { return (await currentSession())?.user.id || null; },
    isCurrent(id) { return !invalid && !!id && id === accountId; },
    onInvalidate(listener) { listeners.add(listener); },
    async signOut() {
      invalidate(false);
      try { await supabase.auth.signOut(); }
      finally { navigate(); }
    },
  };
  return { supabase, accountContext };
}
