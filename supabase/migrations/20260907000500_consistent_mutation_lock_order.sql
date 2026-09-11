-- Critical #2 follow-up: every fixture/schedule mutation uses one lock order.
-- schedule (-2) -> per-pot automation (-9) -> fixture result -> gameweek processing.
begin;

do $$
begin
  if to_regprocedure('public.assert_lms_schedule_integrity(uuid)') is null
    or to_regprocedure('public.complete_lms_provider_run(uuid,text,jsonb,jsonb)') is null
    or to_regprocedure('public.scan_lms_automation_internal(text)') is null then
    raise exception 'Consistent mutation lock order requires the historical schedule integrity gates';
  end if;
  if to_regprocedure('public.complete_lms_provider_run_lock_order_base(uuid,text,jsonb,jsonb)') is not null then
    raise exception 'Consistent mutation lock order is already installed';
  end if;
end $$;

-- A scan retains transaction-scoped pot locks until it returns. UUID order therefore
-- has to match provider completion's pre-lock loop across every non-complete pot.
create or replace function public.scan_lms_automation_internal(run_source text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare selected_pot record;results jsonb:='[]';item jsonb;
begin
  if run_source='system' and not (
    select competition_automation_enabled from public.lms_operations_config where singleton
  ) then
    return jsonb_build_array(jsonb_build_object(
      'status','skipped','state','competition_automation_disabled'
    ));
  end if;
  for selected_pot in
    select id from public.pots where lifecycle_status not in('complete') order by id
  loop
    begin
      item:=public.run_lms_pot_automation_internal(
        selected_pot.id,
        run_source,
        case when run_source='admin' then (select auth.uid()) else null end
      );
    exception when others then
      item:=jsonb_build_object(
        'status','failed','pot_id',selected_pot.id,
        'safe_error','Pot automation failed independently'
      );
    end;
    results:=results||jsonb_build_array(item||jsonb_build_object('pot_id',selected_pot.id));
  end loop;
  return results;
end $$;
revoke all on function public.scan_lms_automation_internal(text)
from public,anon,authenticated;

alter function public.complete_lms_provider_run(uuid,text,jsonb,jsonb)
rename to complete_lms_provider_run_lock_order_base;
revoke all on function public.complete_lms_provider_run_lock_order_base(uuid,text,jsonb,jsonb)
from public,anon,authenticated,service_role;

create function public.complete_lms_provider_run(
  run_id uuid,selected_season text,fpl_teams jsonb,fpl_fixtures jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare selected_pot record;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'Service role required';
  end if;
  if not exists(
    select 1 from public.lms_provider_runs where id=run_id and status='running'
  ) then
    raise exception 'Provider run is not active';
  end if;
  if jsonb_typeof(fpl_teams)<>'array' or jsonb_array_length(fpl_teams)=0
    or jsonb_typeof(fpl_fixtures)<>'array' or jsonb_array_length(fpl_fixtures)=0 then
    raise exception 'Validated provider collections are required';
  end if;

  -- Provider completion scans every non-complete pot after fixture ingestion. Lock
  -- that exact set in the scan's deterministic order before the base can take any
  -- fixture lock. Manual processing and direct automation already take -2 before
  -- fixture locks; direct automation additionally takes -9 before fixture locks.
  for selected_pot in
    select id from public.pots where lifecycle_status not in('complete') order by id
  loop
    perform pg_advisory_xact_lock(hashtext(selected_pot.id::text),-2);
    perform pg_advisory_xact_lock(hashtext(selected_pot.id::text),-9);
  end loop;

  return public.complete_lms_provider_run_lock_order_base(
    run_id,selected_season,fpl_teams,fpl_fixtures
  );
end $$;
revoke all on function public.complete_lms_provider_run(uuid,text,jsonb,jsonb)
from public,anon,authenticated;
grant execute on function public.complete_lms_provider_run(uuid,text,jsonb,jsonb)
to service_role;

do $$
begin
  if has_function_privilege(
    'service_role',
    'public.complete_lms_provider_run_lock_order_base(uuid,text,jsonb,jsonb)',
    'execute'
  ) then
    raise exception 'The provider completion implementation must remain internal';
  end if;
  if not has_function_privilege(
    'service_role','public.complete_lms_provider_run(uuid,text,jsonb,jsonb)','execute'
  ) or has_function_privilege(
    'authenticated','public.complete_lms_provider_run(uuid,text,jsonb,jsonb)','execute'
  ) then
    raise exception 'Provider completion privileges changed unexpectedly';
  end if;
end $$;

commit;
