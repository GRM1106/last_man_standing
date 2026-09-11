import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const migration = readFileSync(new URL(
  '../supabase/migrations/20260907000400_historical_schedule_integrity_gates.sql',
  import.meta.url,
), 'utf8');

const functionBody = name => {
  const match = migration.match(new RegExp(`create function public\\.${name}\\b([\\s\\S]*?)\\$\\$;`, 'i'));
  expect(match, `${name} must exist`).not.toBeNull();
  return match[1];
};

describe('historical schedule integrity gates migration', () => {
  it('is forward-only and preserves legacy round history for reviewed repair', () => {
    expect(migration).toMatch(/^-- Critical #2 follow-up/m);
    expect(migration).toMatch(/begin;[\s\S]*commit;/i);
    expect(migration).not.toMatch(/update public\.pot_rounds|delete from public\.pot_rounds|truncate|drop table/i);
  });

  it('proves every gameweek has its chronological round mapping under the append lock', () => {
    const body = functionBody('assert_lms_schedule_integrity');
    expect(body).toContain("pg_advisory_xact_lock(hashtext(selected_pot_id::text),-2)");
    expect(body).toMatch(/left join public\.pot_rounds/i);
    expect(body).toMatch(/row_number\(\) over\(order by g\.gameweek_number\)/i);
    expect(body).toMatch(/round_id is null[\s\S]*sequence_number is distinct from mapping\.expected_sequence/i);
    expect(body).toContain('reviewed repair before competition mutations');
  });

  it.each([
    'process_pot_gameweek',
    'run_lms_pot_automation_internal',
    'claim_buy_back',
    'confirm_buy_back',
    'revoke_buy_back',
    'set_buy_back_decision',
  ])('gates %s through the shared assertion', name => {
    expect(functionBody(name)).toContain('public.assert_lms_schedule_integrity(selected_pot_id)');
  });

  it('keeps the assertion and every unguarded base internal', () => {
    expect(migration).toMatch(/revoke all on function public\.assert_lms_schedule_integrity\(uuid\) from public,anon,authenticated/i);
    for (const name of [
      'process_pot_gameweek_schedule_integrity_base',
      'run_lms_pot_automation_schedule_integrity_base',
      'claim_buy_back_schedule_integrity_base',
      'confirm_buy_back_schedule_integrity_base',
      'revoke_buy_back_schedule_integrity_base',
      'set_buy_back_decision_schedule_integrity_base',
    ]) expect(migration).toMatch(new RegExp(`revoke all on function public\\.${name}`,'i'));
  });
});
