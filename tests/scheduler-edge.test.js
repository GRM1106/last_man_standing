import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const sdk = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('npm:@supabase/supabase-js@2.112.3', () => ({ createClient: () => sdk }));
vi.mock('../server/environment.js', () => ({ schedulerConfig: () => ({ url: 'http://127.0.0.1:55321', anonKey: 'synthetic-public', serviceKey: 'synthetic-service' }) }));
let handler, logs;
beforeEach(async () => {
  vi.resetModules(); sdk.rpc.mockReset();
  vi.stubGlobal('Deno', { env: { toObject: () => ({}), get: key => key === 'LMS_SCHEDULER_SECRET' ? 'synthetic-scheduler-secret' : undefined }, serve: callback => { handler = callback; } });
  vi.stubGlobal('fetch', vi.fn(async () => new Response('private provider response', { status: 403 })));
  logs = vi.spyOn(console, 'error').mockImplementation(() => {});
  await import('../supabase/functions/lms-scheduler/index.ts');
});
afterEach(() => { logs.mockRestore(); vi.unstubAllGlobals(); });
const request = () => new Request('http://localhost/lms-scheduler', { method: 'POST', headers: { 'x-scheduler-secret': 'synthetic-scheduler-secret' }, body: JSON.stringify({ source: 'scheduler', season: '2026/27' }) });

it('returns failure and sanitised dual-failure diagnostics from the actual Edge handler', async () => {
  sdk.rpc.mockImplementation(async name => name === 'claim_lms_provider_run'
    ? { data: { acquired: true, run_id: '00000000-0000-0000-0000-000000049099' }, error: null }
    : { data: null, error: { message: 'private database-password', details: 'secret-token' } });
  const response = await handler(request());
  expect(response.status).toBe(502);
  expect(await response.json()).toEqual({ error: 'Football data refresh failed safely.' });
  expect(logs).toHaveBeenCalledTimes(1);
  expect(JSON.parse(logs.mock.calls[0][0])).toEqual({ event: 'lms_scheduler_failure', processing_class: 'http_403', retryable: true, failure_recording_failed: true, run_id: '00000000-0000-0000-0000-000000049099' });
  expect(logs.mock.calls[0][0]).not.toMatch(/password|secret-token|synthetic-scheduler-secret|private provider/);
  expect(sdk.rpc.mock.calls.filter(([name]) => name === 'fail_lms_provider_run')).toHaveLength(1);
});

it('returns a safe duplicate skip without calling provider or failure persistence', async () => {
  sdk.rpc.mockResolvedValue({ data: { acquired: false, run_id: 'duplicate', reason: 'already_running' }, error: null });
  const response = await handler(request());
  expect(response.status).toBe(202); expect((await response.json()).reason).toBe('already_running');
  expect(fetch).not.toHaveBeenCalled(); expect(sdk.rpc).toHaveBeenCalledTimes(1); expect(logs).not.toHaveBeenCalled();
});
