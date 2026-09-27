// A preference is only a hint: current, authorised memberships remain the source of truth.
const keyFor = accountId => `lms:selected-pot:${accountId}`;
export function readPotPreference(accountId) {
  if (!accountId) return '';
  try { return window.localStorage.getItem(keyFor(accountId)) || ''; }
  catch { return ''; }
}
export function savePotPreference(accountId, potId) {
  if (!accountId) return;
  try {
    if (potId) window.localStorage.setItem(keyFor(accountId), potId);
    else window.localStorage.removeItem(keyFor(accountId));
  } catch { /* Browsers can disable storage; in-page selection still works. */ }
}
export function preferredPot(pots, currentId, savedId) {
  const valid = id => pots.some(pot => pot.id === id);
  return valid(currentId) ? currentId : valid(savedId) ? savedId : pots[0]?.id || '';
}
