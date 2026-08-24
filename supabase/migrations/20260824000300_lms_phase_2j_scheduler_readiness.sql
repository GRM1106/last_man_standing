-- Phase 2J: provider scheduler integration and deployment readiness (local only).
begin;

do $$ begin
  if to_regclass('public.lms_automation_runs') is null then raise exception 'Phase 2J requires Phase 2I'; end if;
  if to_regclass('public.lms_provider_runs') is not null then raise exception 'Phase 2J already installed'; end if;
end $$;

create table public.lms_operations_config(
  singleton boolean primary key default true check(singleton),
  provider_automation_enabled boolean not null default false,
  competition_automation_enabled boolean not null default false,
  scheduler_expected boolean not null default false,
  warning_after interval not null default interval '3 hours' check(warning_after>interval '0'),
  critical_after interval not null default interval '6 hours' check(critical_after>warning_after),
  stuck_after interval not null default interval '15 minutes' check(stuck_after>interval '0'),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);
insert into public.lms_operations_config(singleton) values(true);
alter table public.lms_operations_config enable row level security;
revoke all on public.lms_operations_config from public,anon,authenticated;

create table public.lms_provider_state(
  singleton boolean primary key default true check(singleton),
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_ingested_at timestamptz,
  last_error_class text,
  last_safe_error text,
  teams_count integer check(teams_count>=0),
  fixtures_count integer check(fixtures_count>=0)
);
insert into public.lms_provider_state(singleton) values(true);
alter table public.lms_provider_state enable row level security;
revoke all on public.lms_provider_state from public,anon,authenticated;

create table public.lms_provider_runs(
  id uuid primary key default gen_random_uuid(),
  source text not null check(source in('scheduler','admin','local_simulation')),
  status text not null check(status in('running','succeeded','failed','skipped')),
  started_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  fetch_result text check(fetch_result in('pending','succeeded','failed','skipped')),
  ingestion_result text check(ingestion_result in('pending','succeeded','failed','skipped')),
  automation_result text check(automation_result in('pending','succeeded','partial','failed','skipped')),
  error_class text,
  safe_error text,
  retryable boolean,
  teams_count integer check(teams_count>=0),
  fixtures_count integer check(fixtures_count>=0),
  automation_summary jsonb not null default '[]',
  provider_fresh_at timestamptz
);
create unique index lms_provider_one_running on public.lms_provider_runs((status)) where status='running';
create index lms_provider_runs_recent on public.lms_provider_runs(started_at desc);
alter table public.lms_provider_runs enable row level security;
grant select on public.lms_provider_runs to authenticated;
create policy "Admins see provider runs" on public.lms_provider_runs for select to authenticated using((select public.is_current_user_admin()));
revoke insert,update,delete on public.lms_provider_runs from public,anon,authenticated;

create or replace function public.is_current_user_admin() returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select auth.role())='service_role' or (select p.is_admin from public.profiles p where p.id=(select auth.uid())),false)
$$;
revoke all on function public.is_current_user_admin() from public,anon;
grant execute on function public.is_current_user_admin() to authenticated,service_role;

create or replace function public.claim_lms_provider_run(run_source text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare new_id uuid;active_id uuid;cfg public.lms_operations_config%rowtype;
begin
  if (select auth.role())<>'service_role' then raise exception 'Service role required'; end if;
  if run_source not in('scheduler','admin','local_simulation') then raise exception 'Invalid provider run source'; end if;
  select * into cfg from public.lms_operations_config where singleton for update;
  update public.lms_provider_runs set status='failed',completed_at=clock_timestamp(),fetch_result='failed',ingestion_result='skipped',automation_result='skipped',error_class='stuck',safe_error='Previous provider run exceeded the execution window',retryable=true
    where status='running' and started_at<clock_timestamp()-cfg.stuck_after;
  update public.lms_provider_state set last_attempt_at=clock_timestamp() where singleton;
  if run_source='scheduler' and not cfg.provider_automation_enabled then
    insert into public.lms_provider_runs(source,status,completed_at,fetch_result,ingestion_result,automation_result,error_class,safe_error)
      values(run_source,'skipped',clock_timestamp(),'skipped','skipped','skipped','disabled','Scheduled provider automation is disabled') returning id into new_id;
    return jsonb_build_object('acquired',false,'run_id',new_id,'reason','disabled');
  end if;
  select id into active_id from public.lms_provider_runs where status='running' limit 1;
  if active_id is not null then
    insert into public.lms_provider_runs(source,status,completed_at,fetch_result,ingestion_result,automation_result,error_class,safe_error)
      values(run_source,'skipped',clock_timestamp(),'skipped','skipped','skipped','overlap','Another provider run is already active') returning id into new_id;
    return jsonb_build_object('acquired',false,'run_id',new_id,'active_run_id',active_id,'reason','already_running');
  end if;
  insert into public.lms_provider_runs(source,status,fetch_result,ingestion_result,automation_result)
    values(run_source,'running','pending','pending','pending') returning id into new_id;
  return jsonb_build_object('acquired',true,'run_id',new_id);
exception when unique_violation then
  select id into active_id from public.lms_provider_runs where status='running' limit 1;
  insert into public.lms_provider_runs(source,status,completed_at,fetch_result,ingestion_result,automation_result,error_class,safe_error)
    values(run_source,'skipped',clock_timestamp(),'skipped','skipped','skipped','overlap','Another provider run is already active') returning id into new_id;
  return jsonb_build_object('acquired',false,'run_id',new_id,'active_run_id',active_id,'reason','already_running');
end $$;
revoke all on function public.claim_lms_provider_run(text) from public,anon,authenticated;
grant execute on function public.claim_lms_provider_run(text) to service_role;

create or replace function public.scan_lms_automation_internal(run_source text) returns jsonb language plpgsql security definer set search_path='' as $$
declare p record;results jsonb:='[]';item jsonb;
begin
  if run_source='system' and not (select competition_automation_enabled from public.lms_operations_config where singleton) then return jsonb_build_array(jsonb_build_object('status','skipped','state','competition_automation_disabled')); end if;
  for p in select id from public.pots where lifecycle_status not in('complete') order by created_at loop
    begin item:=public.run_lms_pot_automation_internal(p.id,run_source,case when run_source='admin' then (select auth.uid()) else null end);
    exception when others then item:=jsonb_build_object('status','failed','pot_id',p.id,'safe_error','Pot automation failed independently'); end;
    results:=results||jsonb_build_array(item||jsonb_build_object('pot_id',p.id));
  end loop;
  return results;
end $$;
revoke all on function public.scan_lms_automation_internal(text) from public,anon,authenticated;

create or replace function public.scan_lms_automation() returns jsonb language plpgsql security definer set search_path='' as $$
begin if not (select public.is_current_user_admin()) then raise exception 'Administrator access required';end if;return public.scan_lms_automation_internal('admin');end $$;
revoke all on function public.scan_lms_automation() from public,anon;grant execute on function public.scan_lms_automation() to authenticated;

create or replace function public.complete_lms_provider_run(run_id uuid,selected_season text,fpl_teams jsonb,fpl_fixtures jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ingested jsonb;scan jsonb;failed_count integer;cfg public.lms_operations_config%rowtype;
begin
  if (select auth.role())<>'service_role' then raise exception 'Service role required'; end if;
  if not exists(select 1 from public.lms_provider_runs where id=run_id and status='running') then raise exception 'Provider run is not active'; end if;
  if jsonb_typeof(fpl_teams)<>'array' or jsonb_array_length(fpl_teams)=0 or jsonb_typeof(fpl_fixtures)<>'array' or jsonb_array_length(fpl_fixtures)=0 then raise exception 'Validated provider collections are required'; end if;
  ingested:=public.sync_fpl_data(selected_season,fpl_teams,fpl_fixtures);
  update public.lms_provider_state set last_success_at=clock_timestamp(),last_ingested_at=clock_timestamp(),last_error_class=null,last_safe_error=null,teams_count=jsonb_array_length(fpl_teams),fixtures_count=jsonb_array_length(fpl_fixtures) where singleton;
  select * into cfg from public.lms_operations_config where singleton;
  scan:=public.scan_lms_automation_internal('system');
  select count(*) into failed_count from jsonb_array_elements(scan) item where item->>'status'='failed';
  update public.lms_provider_runs set status='succeeded',completed_at=clock_timestamp(),fetch_result='succeeded',ingestion_result='succeeded',automation_result=case when failed_count>0 then 'partial' else 'succeeded' end,teams_count=jsonb_array_length(fpl_teams),fixtures_count=jsonb_array_length(fpl_fixtures),automation_summary=scan,provider_fresh_at=clock_timestamp() where id=run_id;
  return jsonb_build_object('status','succeeded','run_id',run_id,'ingestion',ingested,'automation',scan,'automation_failures',failed_count);
end $$;
revoke all on function public.complete_lms_provider_run(uuid,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.complete_lms_provider_run(uuid,text,jsonb,jsonb) to service_role;

create or replace function public.fail_lms_provider_run(run_id uuid,failure_class text,is_retryable boolean default false)
returns void language plpgsql security definer set search_path='' as $$
begin
  if (select auth.role())<>'service_role' then raise exception 'Service role required'; end if;
  update public.lms_provider_runs set status='failed',completed_at=clock_timestamp(),fetch_result='failed',ingestion_result='skipped',automation_result='skipped',error_class=left(coalesce(failure_class,'platform'),80),safe_error='Football data refresh failed safely',retryable=is_retryable where id=run_id and status='running';
  if not found then raise exception 'Provider run is not active'; end if;
  update public.lms_provider_state set last_error_class=left(coalesce(failure_class,'platform'),80),last_safe_error='Football data refresh failed safely' where singleton;
end $$;
revoke all on function public.fail_lms_provider_run(uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.fail_lms_provider_run(uuid,text,boolean) to service_role;

alter function public.process_pot_gameweek(uuid,integer,boolean) rename to process_pot_gameweek_phase2j_base;
revoke all on function public.process_pot_gameweek_phase2j_base(uuid,integer,boolean) from public,anon,authenticated;
create or replace function public.process_pot_gameweek(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare last_ingest timestamptz;critical interval;is_test boolean;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select test_mode into is_test from public.pots where id=selected_pot_id;
  if apply_changes and not coalesce(is_test,false) and exists(select 1 from public.player_picks p join public.football_fixtures f on f.id=p.fixture_id where p.pot_id=selected_pot_id and p.gameweek_number=selected_gameweek and f.kickoff_at<=now()) then
    select s.last_ingested_at,c.critical_after into last_ingest,critical from public.lms_provider_state s cross join public.lms_operations_config c where s.singleton and c.singleton;
    if last_ingest is null or last_ingest<now()-critical then raise exception 'Provider data is stale; automatic result finalization is paused'; end if;
  end if;
  return public.process_pot_gameweek_phase2j_base(selected_pot_id,selected_gameweek,apply_changes);
end $$;
revoke all on function public.process_pot_gameweek(uuid,integer,boolean) from public,anon;
grant execute on function public.process_pot_gameweek(uuid,integer,boolean) to authenticated;

create or replace function public.get_lms_operations_health() returns jsonb language sql stable security definer set search_path='' as $$
  select case when (select public.is_current_user_admin()) then jsonb_build_object(
    'last_attempt_at',s.last_attempt_at,'last_success_at',s.last_success_at,'last_ingested_at',s.last_ingested_at,
    'data_age_seconds',case when s.last_ingested_at is null then null else extract(epoch from now()-s.last_ingested_at)::integer end,
    'freshness',case when s.last_ingested_at is null or s.last_ingested_at<now()-c.critical_after then 'critical' when s.last_ingested_at<now()-c.warning_after then 'warning' else 'fresh' end,
    'last_error',s.last_safe_error,'teams_count',s.teams_count,'fixtures_count',s.fixtures_count,
    'provider_automation_enabled',c.provider_automation_enabled,'competition_automation_enabled',c.competition_automation_enabled,'scheduler_expected',c.scheduler_expected,
    'scheduler_state',case when not c.scheduler_expected then 'not_deployed' when not c.provider_automation_enabled then 'disabled' else 'enabled_target' end,
    'last_run',(select jsonb_build_object('id',r.id,'source',r.source,'status',r.status,'started_at',r.started_at,'completed_at',r.completed_at,'error',r.safe_error,'automation',r.automation_summary) from public.lms_provider_runs r order by r.started_at desc limit 1),
    'automation_summary',jsonb_build_object('last_scan',(select max(started_at) from public.lms_automation_runs),'processed',(select count(*) from public.lms_automation_runs where started_at>now()-interval '24 hours' and status='succeeded'),'waiting',(select count(*) from public.lms_automation_runs where started_at>now()-interval '24 hours' and status='skipped'),'blocked',(select count(*) from public.lms_automation_runs where started_at>now()-interval '24 hours' and status='blocked'),'failed',(select count(*) from public.lms_automation_runs where started_at>now()-interval '24 hours' and status='failed'))
  ) else null end from public.lms_provider_state s cross join public.lms_operations_config c where s.singleton and c.singleton
$$;
revoke all on function public.get_lms_operations_health() from public,anon;grant execute on function public.get_lms_operations_health() to authenticated;

create or replace function public.get_player_provider_notice() returns text language sql stable security definer set search_path='' as $$
  select case when s.last_ingested_at is null or s.last_ingested_at<now()-c.critical_after then 'Football updates are currently delayed. Your selections are safe.' else null end from public.lms_provider_state s cross join public.lms_operations_config c where s.singleton and c.singleton
$$;
revoke all on function public.get_player_provider_notice() from public,anon;grant execute on function public.get_player_provider_notice() to authenticated;

comment on table public.lms_operations_config is 'Environment-local operational switches. Scheduler flags default off and do not create platform cron jobs.';
comment on function public.complete_lms_provider_run(uuid,text,jsonb,jsonb) is 'Atomic authoritative provider ingestion followed by the Phase 2I automation scan; contains no LMS rules.';
commit;
