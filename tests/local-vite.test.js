import { afterEach, describe, expect, it, vi } from 'vitest';
import { resolveConfig, preview } from 'vite';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LOCAL_SUPABASE_URL } from '../server/environment.js';
const scratches = [];
const anon = `header.${Buffer.from(JSON.stringify({ role: 'anon', iss: 'supabase-demo' })).toString('base64url')}.test-signature`;
const input = () => ({ configFile: fileURLToPath(new URL('../vite.config.js', import.meta.url)), mode: 'isolation-test' });
function local() {
  vi.stubEnv('LMS_BUILD_TARGET', 'local');
  vi.stubEnv('LMS_LOCAL_SUPABASE_URL', LOCAL_SUPABASE_URL);
  vi.stubEnv('LMS_LOCAL_SUPABASE_ANON_KEY', anon);
}
afterEach(() => { vi.unstubAllEnvs(); for (const path of scratches.splice(0)) rmSync(path, { recursive: true, force: true }); });
describe('real Vite environment routing', () => {
  it('defaults to local and fails without local configuration', async () => {
    vi.stubEnv('LMS_BUILD_TARGET', '');
    vi.stubEnv('LMS_LOCAL_SUPABASE_URL', '');
    await expect(resolveConfig(input(), 'serve')).rejects.toThrow(/npm run local:start/);
  });
  it('injects only local public configuration and limits browser connections', async () => {
    local(); vi.stubEnv('VITE_SERVICE_ROLE_KEY', 'private-test-sentinel');
    const config = await resolveConfig(input(), 'serve');
    expect(config.define.__LMS_DEPLOY_TARGET__).toBe('"local"');
    expect(config.define.__LMS_SUPABASE_URL__).toBe(JSON.stringify(LOCAL_SUPABASE_URL));
    expect(config.env).not.toHaveProperty('VITE_SERVICE_ROLE_KEY');
    expect(JSON.stringify(config.define)).not.toContain('private-test-sentinel');
    expect(config.server.host).toBe('127.0.0.1');
    expect(config.server.headers['Content-Security-Policy']).not.toContain('supabase.co');
    expect(config.server.headers['Content-Security-Policy']).toContain(LOCAL_SUPABASE_URL);
  });
  it('refuses accidental hosted development even with a declared production target', async () => {
    vi.stubEnv('LMS_BUILD_TARGET', 'production'); vi.stubEnv('LMS_ALLOW_HOSTED_DEV', '');
    await expect(resolveConfig(input(), 'serve')).rejects.toThrow(/Hosted development requires/);
  });
  it('keeps an explicitly selected production build available', async () => {
    vi.stubEnv('LMS_BUILD_TARGET', 'production');
    const config = await resolveConfig({ ...input(), build: { outDir: join(tmpdir(), 'lms-production-verification') } }, 'build');
    expect(config.define.__LMS_DEPLOY_TARGET__).toBe('"production"');
  });
  it('refuses to preview an old hosted bundle as local', async () => {
    local(); vi.stubEnv('LMS_PREVIEW_TARGET', '');
    const dir = mkdtempSync(join(tmpdir(), 'lms-preview-guard-')); scratches.push(dir);
    writeFileSync(join(dir, 'lms-environment.json'), '{"target":"production"}');
    await expect(preview({ ...input(), build: { outDir: dir } })).rejects.toThrow(/Preview target does not match/);
  });
});
