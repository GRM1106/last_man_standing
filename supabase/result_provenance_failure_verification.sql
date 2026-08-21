-- Run after result_provenance_foundation.sql aborts against the intentional
-- failure seed. These read-only assertions prove the migration transaction did
-- not partially apply. Never use production for this test.

do $$
begin
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='football_teams' and column_name='season') then
    raise exception 'Failure-path rollback left football_teams.season behind';
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='football_fixtures' and column_name='status') then
    raise exception 'Failure-path rollback left football_fixtures.status behind';
  end if;
  if to_regclass('public.fixture_result_overrides') is not null
    or to_regclass('public.admin_audit_events') is not null
    or to_regclass('public.pot_player_status_history') is not null then
    raise exception 'Failure-path rollback left Phase P1 audit tables behind';
  end if;
  if not exists(
    select 1 from pg_constraint constraint_row
    join pg_attribute attribute_row on attribute_row.attrelid=constraint_row.conrelid
      and attribute_row.attnum=any(constraint_row.conkey)
    where constraint_row.conrelid='public.football_fixtures'::regclass
      and constraint_row.contype='u' and attribute_row.attname='fpl_fixture_id'
      and cardinality(constraint_row.conkey)=1
  ) then
    raise exception 'Failure-path rollback did not restore the original global fixture constraint';
  end if;
end;
$$;

select 'Phase P1 intentional failure rolled back completely' as result;
