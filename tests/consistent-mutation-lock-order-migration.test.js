import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const migration = readFileSync(new URL(
  '../supabase/migrations/20260907000500_consistent_mutation_lock_order.sql',
  import.meta.url,
), 'utf8');

const functionBody = name => {
  const match = migration.match(new RegExp(
    `create(?: or replace)? function public\\.${name}\\b([\\s\\S]*?)\\$\\$;`,
    'i',
  ));
  expect(match, `${name} must exist`).not.toBeNull();
  return match[1];
};

describe('consistent mutation lock order migration', () => {
  it('is forward-only and leaves competition history untouched', () => {
    expect(migration).toMatch(/^-- Critical #2 follow-up/m);
    expect(migration).toMatch(/begin;[\s\S]*commit;/i);
    expect(migration).not.toMatch(/update public\.(?:pot_rounds|player_picks|pot_gameweek_processes)|delete from|truncate|drop table/i);
  });

  it('takes schedule and automation locks before provider fixture ingestion', () => {
    const body = functionBody('complete_lms_provider_run');
    const schedule = body.indexOf("pg_advisory_xact_lock(hashtext(selected_pot.id::text),-2)");
    const automation = body.indexOf("pg_advisory_xact_lock(hashtext(selected_pot.id::text),-9)");
    const base = body.indexOf('public.complete_lms_provider_run_lock_order_base(');
    expect(schedule).toBeGreaterThan(-1);
    expect(automation).toBeGreaterThan(schedule);
    expect(base).toBeGreaterThan(automation);
  });

  it('locks and scans every non-complete pot in the same UUID order', () => {
    const order = /select id from public\.pots where lifecycle_status not in\('complete'\) order by id/i;
    expect(functionBody('complete_lms_provider_run')).toMatch(order);
    expect(functionBody('scan_lms_automation_internal')).toMatch(order);
  });

  it('keeps the unguarded provider base internal and preserves the service-only API', () => {
    expect(migration).toMatch(/revoke all on function public\.complete_lms_provider_run_lock_order_base[\s\S]*?service_role/i);
    expect(migration).toMatch(/grant execute on function public\.complete_lms_provider_run\(uuid,text,jsonb,jsonb\)[\s\S]*?to service_role/i);
    expect(migration).not.toMatch(/grant execute on function public\.complete_lms_provider_run\(uuid,text,jsonb,jsonb\)\s+to authenticated/i);
  });
});
