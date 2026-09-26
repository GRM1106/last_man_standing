import { describe, it, expect } from 'vitest';
import { localBrowserConfig, schedulerConfig, assertLocalKey, LOCAL_SUPABASE_URL } from '../server/environment.js';
const key = (role, extra = {}) => `header.${Buffer.from(JSON.stringify({ iss: 'supabase-demo', role, ...extra })).toString('base64url')}.local-test-signature`;
const local = { LMS_LOCAL_SUPABASE_URL: LOCAL_SUPABASE_URL, LMS_LOCAL_SUPABASE_ANON_KEY: key('anon') };
const server = { SUPABASE_URL: LOCAL_SUPABASE_URL, SUPABASE_ANON_KEY: key('anon'), SUPABASE_SERVICE_ROLE_KEY: key('service_role') };

describe('local environment isolation', () => {
  it('uses only the local URL and public anonymous key', () => {
    expect(localBrowserConfig({ ...local, SUPABASE_SERVICE_ROLE_KEY: 'private', VITE_SECRET: 'private' })).toEqual({ url: LOCAL_SUPABASE_URL, publishableKey: local.LMS_LOCAL_SUPABASE_ANON_KEY });
  });
  it('fails actionably without local configuration', () => {
    expect(() => localBrowserConfig({})).toThrow(/npm run local:start/);
  });
  it.each(['https://enzdvsppduyqtpdeseyh.supabase.co', 'https://evhiixndiuwwodsouyhf.supabase.co', 'http://127.0.0.1:54321', 'http://127.0.0.1:55321@evil.test', 'http://localhost.evil.test:55321'])('refuses non-local browser URL %s', url => {
    expect(() => localBrowserConfig({ ...local, LMS_LOCAL_SUPABASE_URL: url })).toThrow();
  });
  it.each([undefined, '', 'sb_secret_private', 'sb_publishable_hosted', key('service_role'), key('anon', { ref: 'hosted-ref' }), key('anon', { iss: 'hosted' })])('refuses a missing, secret or hosted browser credential', candidate => {
    expect(() => localBrowserConfig({ ...local, LMS_LOCAL_SUPABASE_ANON_KEY: candidate })).toThrow(/local:setup/);
  });
  it('validates the privileged local key independently', () => {
    expect(() => assertLocalKey(key('anon'), 'service_role')).toThrow();
    expect(assertLocalKey(key('service_role'), 'service_role')).toBe(key('service_role'));
  });
  it.each([LOCAL_SUPABASE_URL, 'http://kong:8000', 'http://supabase_kong_last_man_standing_local:8000'])('permits CLI local scheduler routing %s', url => {
    expect(schedulerConfig({ ...server, SUPABASE_URL: url }).url).toBe(url);
  });
  it.each(['https://enzdvsppduyqtpdeseyh.supabase.co', 'https://evhiixndiuwwodsouyhf.supabase.co', 'https://unknown.test'])('blocks local scheduler routing to %s', url => {
    expect(() => schedulerConfig({ ...server, SUPABASE_URL: url })).toThrow(/Local scheduler refuses/);
  });
  it('blocks hosted credentials even with a local scheduler URL', () => {
    expect(() => schedulerConfig({ ...server, SUPABASE_SERVICE_ROLE_KEY: key('service_role', { ref: 'hosted' }) })).toThrow();
  });
  it('fails closed for incomplete backend configuration', () => {
    expect(() => schedulerConfig({})).toThrow(/incomplete/);
  });
  it('retains platform-injected configuration for genuinely deployed functions', () => {
    expect(schedulerConfig({ DENO_DEPLOYMENT_ID: 'platform-deployment', SUPABASE_URL: 'https://enzdvsppduyqtpdeseyh.supabase.co', SUPABASE_ANON_KEY: 'public', SUPABASE_SERVICE_ROLE_KEY: 'server-only' }).url).toBe('https://enzdvsppduyqtpdeseyh.supabase.co');
  });
});
