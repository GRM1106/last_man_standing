import { afterEach, describe, expect, it, vi } from 'vitest';
import { ProviderError } from '../server/fpl-provider.js';
import { runSchedulerPipeline, SchedulerFailurePersistenceError, schedulerFailureReport } from '../server/scheduler-pipeline.js';

afterEach(() => vi.useRealTimers());
describe('scheduler failure observability', () => {
  it('reports both failures without serialising either error or an unsafe run identifier', () => {
    const first = new ProviderError('secret-token provider body', { classification: 'http_503', retryable: true });
    const second = { message: 'database-password', details: 'private payload' };
    const error = new SchedulerFailurePersistenceError(first, second, 'injected-token');
    expect(error.cause).toBe(first); expect(error.persistenceError).toBe(second);
    expect(schedulerFailureReport(error)).toEqual({ event: 'lms_scheduler_failure', processing_class: 'http_503', retryable: true, failure_recording_failed: true });
    expect(JSON.stringify(schedulerFailureReport(error))).not.toMatch(/secret-token|password|private|injected/);
  });
  it('includes only a valid operational run UUID and allowlisted classification', () => {
    const runId = '00000000-0000-0000-0000-000000039001';
    const first = new ProviderError('sensitive', { classification: 'private-token', retryable: true });
    expect(schedulerFailureReport(new SchedulerFailurePersistenceError(first, new Error('sensitive'), runId)))
      .toEqual({ event: 'lms_scheduler_failure', processing_class: 'platform', retryable: true, failure_recording_failed: true, run_id: runId });
  });
  it('reports an ordinary provider or claim failure without fabricating a secondary outage', () => {
    expect(schedulerFailureReport(new ProviderError('sensitive', { classification: 'timeout', retryable: true })))
      .toEqual({ event: 'lms_scheduler_failure', processing_class: 'timeout', retryable: true, failure_recording_failed: false });
    expect(schedulerFailureReport(new Error('private connection string')).processing_class).toBe('platform');
  });
  it('retains processing failure when recording rejects with a database-request timeout', async () => {
    const processing = new Error('Synthetic ingestion failure');
    const persistence = new DOMException('Synthetic recording timeout', 'AbortError');
    const operations = { claim: vi.fn().mockResolvedValue({ acquired: true, run_id: '00000000-0000-0000-0000-000000049099' }),
      ingestAndScan: vi.fn().mockRejectedValue(processing), fail: vi.fn().mockRejectedValue(persistence) };
    const teams = [{ id: 1, code: 1, name: 'Home', short_name: 'HOM' }, { id: 2, code: 2, name: 'Away', short_name: 'AWY' }];
    const fixtures = [{ id: 1, event: 1, team_h: 1, team_a: 2 }];
    const fetchImpl = vi.fn(async url => new Response(JSON.stringify(url.includes('bootstrap-static') ? { teams } : fixtures)));
    const error = await runSchedulerPipeline({ source: 'scheduler', season: '2026/27', operations,
      fetchOptions: { fetchImpl, retries: 0 } }).catch(error => error);
    expect(error).toBeInstanceOf(SchedulerFailurePersistenceError);
    expect(error.cause).toBe(processing); expect(error.persistenceError).toBe(persistence);
    expect(operations.fail).toHaveBeenCalledExactlyOnceWith('00000000-0000-0000-0000-000000049099', 'platform', false);
    expect(schedulerFailureReport(error).failure_recording_failed).toBe(true);
  });
  it('records a timed-out provider exactly once and retains its retry classification', async () => {
    vi.useFakeTimers();
    const fetchImpl = vi.fn((_url, { signal }) => new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new DOMException('Synthetic timeout', 'AbortError')))));
    const operations = { claim: vi.fn().mockResolvedValue({ acquired: true, run_id: 'timeout-run' }), ingestAndScan: vi.fn(), fail: vi.fn().mockResolvedValue(undefined) };
    const result = runSchedulerPipeline({ source: 'scheduler', season: '2026/27', operations, fetchOptions: { fetchImpl, timeoutMs: 10, retries: 0 } }).catch(error => error);
    await vi.advanceTimersByTimeAsync(10);
    expect(await result).toMatchObject({ classification: 'timeout', retryable: true });
    expect(operations.fail).toHaveBeenCalledExactlyOnceWith('timeout-run', 'timeout', true);
    expect(operations.ingestAndScan).not.toHaveBeenCalled();
  });
});
