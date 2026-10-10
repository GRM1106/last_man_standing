// Shared by Vite and the Edge Function; never reads or prints credentials.
export const LOCAL_SUPABASE_URL = "http://127.0.0.1:55321";
export const LOCAL_PROJECT_ID = "last_man_standing_local";

export function assertLocalKey(key, role) {
  let claims;
  try { claims = JSON.parse(atob(key.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); } catch { /* rejected below */ }
  if (!claims || claims.role !== role || claims.iss !== 'supabase-demo' || claims.ref) {
    throw new Error(`Local Supabase requires its CLI-generated ${role} key. Run npm run local:setup.`);
  }
  return key;
}

export function localBrowserConfig(env) {
  if (env.LMS_LOCAL_SUPABASE_URL !== LOCAL_SUPABASE_URL) {
    throw new Error('Local Supabase configuration is missing or unsafe. Run npm run local:start, then npm run local:setup. Expected http://127.0.0.1:55321.');
  }
  return { url: LOCAL_SUPABASE_URL, publishableKey: assertLocalKey(env.LMS_LOCAL_SUPABASE_ANON_KEY, 'anon') };
}

export function schedulerConfig(env) {
  const url = env.SUPABASE_URL;
  const anonKey = env.SUPABASE_ANON_KEY;
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !anonKey || !serviceKey) throw new Error('Scheduler configuration is incomplete.');
  if (!env.DENO_DEPLOYMENT_ID) {
    if (![LOCAL_SUPABASE_URL, 'http://kong:8000', `http://supabase_kong_${LOCAL_PROJECT_ID}:8000`].includes(url)) {
      throw new Error('Local scheduler refuses a hosted or unknown Supabase URL.');
    }
    assertLocalKey(anonKey, 'anon');
    assertLocalKey(serviceKey, 'service_role');
  }
  return { url, anonKey, serviceKey };
}
