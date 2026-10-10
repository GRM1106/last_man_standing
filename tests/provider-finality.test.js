import { describe, expect, it } from 'vitest';
import { validateAndProjectFplPayload } from '../server/fpl-provider.js';
import { runSchedulerPipeline } from '../server/scheduler-pipeline.js';

const teams = [{ id: 1, code: 1, name: 'Home', short_name: 'HOM' }, { id: 2, code: 2, name: 'Away', short_name: 'AWY' }];
const fixture = { id: 1, event: 1, team_h: 1, team_a: 2, team_h_score: 2, team_a_score: 0, started: true,
  finished: true, finished_provisional: true };
const bootstrap = { teams, events: [{ id: 1, finished: true, data_checked: true }] };

describe('provider completion evidence', () => {
  it.each(['finished', 'finished_provisional'])('preserves missing, NULL and false %s despite a completed event', field => {
    for (const value of [undefined, null, false, true]) {
      const input = { ...fixture, [field]: value };
      if (value === undefined) delete input[field];
      const projected = validateAndProjectFplPayload(bootstrap, [input]).fixtures[0];
      expect(projected[field]).toBe(value);
      expect(JSON.parse(JSON.stringify(projected))[field]).toBe(value);
    }
  });
  it.each(['finished', 'finished_provisional'])('rejects unsupported %s values instead of coercing them', field => {
    for (const value of ['true', 'false', 'yes', 1, 0, {}, []]) {
      expect(() => validateAndProjectFplPayload(bootstrap, [{ ...fixture, [field]: value }])).toThrow('Provider fixture shape is invalid.');
    }
  });
  it('preserves cumulative completed flags and provisional-only evidence separately', () => {
    const result = validateAndProjectFplPayload(bootstrap, [fixture, { ...fixture, id: 2, finished: false }]);
    expect(result.fixtures.map(({ finished, finished_provisional }) => [finished, finished_provisional])).toEqual([[true, true], [false, true]]);
  });
  it('does not promote missing fixture evidence in a mixed payload', () => {
    const input = { ...fixture, id: 2 };
    delete input.finished_provisional;
    const result = validateAndProjectFplPayload(bootstrap, [fixture, input]);
    expect(result.fixtures[0].finished_provisional).toBe(true);
    expect(result.fixtures[1].finished_provisional).toBeUndefined();
  });
  it('passes unknown then explicit evidence unchanged through scheduler retries', async () => {
    const ingested = [];
    let attempt = 0;
    const operations = {
      claim: async () => ({ acquired: true, run_id: 'test-run' }),
      ingestAndScan: async (...args) => { ingested.push(args); return { status: 'succeeded' }; },
      fail: async () => { throw new Error('Unexpected failure'); }
    };
    const unknown = { ...fixture }; delete unknown.finished_provisional;
    for (const input of [unknown, fixture]) {
      await runSchedulerPipeline({ source: 'scheduler', season: '2026/27', operations,
        fetchOptions: { retries: 0, fetchImpl: async url => ({ ok: true, json: async () => url.includes('bootstrap-static') ? bootstrap : [input] }) } });
      attempt++;
    }
    expect(attempt).toBe(2);
    expect(JSON.stringify(ingested[0])).not.toContain('finished_provisional');
    expect(JSON.stringify(ingested[1])).toContain('"finished_provisional":true');
  });
});
