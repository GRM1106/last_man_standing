import './maintenance.css';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './config.js';

export const maintenanceCopy = 'Last Man Standing is temporarily unavailable while an update is being applied. Please check back shortly.';

// Presentation only: database guards protect old bundles, direct callers and
// submissions between polls. A missing/unreadable state keeps this screen closed.
export function watchMaintenance(supabase, { fetchRequest = (...args) => fetch(...args), interval = 5000, reopen = () => window.location.reload() } = {}) {
  const panel = document.createElement('dialog');
  panel.className = 'maintenance-screen';
  panel.setAttribute('aria-labelledby', 'maintenance-title');
  panel.innerHTML = '<section><p class="maintenance-brand">LAST MAN STANDING</p><h1 id="maintenance-title">Checking availability</h1><p class="maintenance-copy" role="status" aria-live="polite"></p><div class="maintenance-actions"><button type="button" class="maintenance-retry">Check again</button><button type="button" class="maintenance-logout">Sign out</button></div></section>';
  document.body.append(panel);
  const title = panel.querySelector('h1'), copy = panel.querySelector('.maintenance-copy');
  const retry = panel.querySelector('.maintenance-retry'), logout = panel.querySelector('.maintenance-logout');
  let allowStartup; const ready = new Promise(resolve => { allowStartup = resolve; });
  let pending, stopped = false, blocked = true, wasOpen = false, lastKnownEnabled;
  function show(enabled, unavailable = false) {
    blocked = enabled;
    if (enabled) {
      title.textContent = unavailable ? 'We can’t check availability' : 'We’ll be back shortly';
      copy.textContent = unavailable ? 'Please check back shortly. Your actions are paused until we can confirm the service is available.' : maintenanceCopy;
      document.documentElement.classList.add('maintenance-active');
      if (!panel.open) {
        for (const dialog of document.querySelectorAll('dialog[open]')) if (dialog !== panel) dialog.close?.('cancel');
        if (panel.showModal) panel.showModal(); else panel.setAttribute('open', '');
      }
      wasOpen = true;
    } else {
      document.documentElement.classList.remove('maintenance-active');
      if (panel.open) { if (panel.close) panel.close(); else panel.removeAttribute('open'); }
    }
  }
  panel.addEventListener('cancel', event => event.preventDefault());
  async function check() {
    if (stopped) return blocked;
    if (pending) return pending;
    pending = (async () => {
      retry.disabled = true;
      try {
        const response = await fetchRequest(`${SUPABASE_URL}/rest/v1/rpc/get_lms_maintenance`, {
          method: 'POST', headers: { apikey: SUPABASE_PUBLISHABLE_KEY, 'Content-Type': 'application/json' },
          body: '{}', cache: 'no-store', signal: AbortSignal.timeout(8000),
        });
        const state = await response.json();
        if (!response.ok || typeof state?.enabled !== 'boolean') throw new Error('Availability unknown');
        if (!stopped) {
          if (lastKnownEnabled === true && state.enabled === false) reopen();
          lastKnownEnabled = state.enabled; show(state.enabled);
          if (!state.enabled) allowStartup();
        }
      } catch { if (!stopped) show(true, true); }
      finally { retry.disabled = false; pending = null; }
      return blocked;
    })();
    return pending;
  }
  retry.addEventListener('click', async () => { if (!await check()) window.location.reload(); });
  logout.addEventListener('click', async () => {
    logout.disabled = true;
    try {
      const { error } = await supabase.auth.signOut();
      if (error) { copy.textContent = 'Sign out did not complete. Please try again.'; return; }
      window.location.replace('/');
    } catch { copy.textContent = 'Sign out did not complete. Please try again.'; }
    finally { logout.disabled = false; }
  });
  // Cover startup before any asynchronous application requests can finish.
  show(true); title.textContent = 'Checking availability'; copy.textContent = 'Please wait a moment.';
  check();
  const timer = window.setInterval(check, interval);
  const focus = () => check(); window.addEventListener('focus', focus);
  return { ready, check, get blocked() { return blocked; }, stop() {
    stopped = true; window.clearInterval(timer); window.removeEventListener('focus', focus);
    panel.remove(); if (wasOpen) document.documentElement.classList.remove('maintenance-active');
  } };
}
