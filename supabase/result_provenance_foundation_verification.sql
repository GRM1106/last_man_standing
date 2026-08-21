-- Phase P1 database verification (non-persistent)
-- Run only in a disposable/local Supabase database after the pre-P1 seed and
-- result_provenance_foundation.sql. Every verification test row is rolled back.
--
-- Required database shape: Supabase auth schema and auth.uid(), anon,
-- authenticated and service_role roles, one test administrator profile, and
-- every pre-P1 SQL module applied in README order. Vanilla PostgreSQL is not
-- sufficient without equivalent roles/auth functions. Never run in production.

begin;

create temporary table p1_verification_context(admin_id uuid not null) on commit drop;
insert into p1_verification_context
select id from public.profiles where is_admin order by created_at limit 1;
do $$ begin
  if not exists(select 1 from p1_verification_context) then
    raise exception 'Phase P1 verification requires one existing administrator profile in the disposable database';
  end if;
end; $$;
select set_config('request.jwt.claim.sub',(select admin_id::text from p1_verification_context),true);

do $$
begin
  if to_regprocedure('public.sync_fpl_data(text,jsonb,jsonb)') is null
    or to_regprocedure('public.process_pot_gameweek(uuid,integer,boolean)') is null
    or to_regprocedure('public.reset_test_gameweek(uuid,integer)') is null then
    raise exception 'Expected existing function signatures are missing';
  end if;
  if to_regprocedure('public.get_p1_provenance_backfill_report()') is null then
    raise exception 'Phase P1 has not been applied';
  end if;
end;
$$;

-- Exercise and verify the transformation of rows that existed before P1.
do $$
declare report jsonb;
begin
  if (select count(*) from public.player_picks where id between -26105 and -26101)<>5 then
    raise exception 'Representative pre-P1 seed is missing';
  end if;

  if not exists(select 1 from public.player_picks where id=-26101 and outcome='won'
    and result_source='legacy_backfill' and resolved_home_team_id=-24101 and resolved_away_team_id=-24102
    and resolved_home_score=2 and resolved_away_score=0 and resolved_fixture_season='P1-SEED-2030'
    and resolved_fixture_status='finished' and resolved_at='2030-08-10T18:05:00Z') then
    raise exception 'Normal legacy result backfill is incorrect';
  end if;

  if not exists(select 1 from public.player_picks where id=-26102 and outcome='lost'
    and result_source='test' and resolved_home_team_id=-24107 and resolved_away_team_id=-24108
    and resolved_home_score=0 and resolved_away_score=1 and resolved_fixture_season='P1-SEED-2030'
    and resolved_fixture_status='finished' and resolved_at='2030-08-10T18:10:00Z') then
    raise exception 'Test-derived legacy result backfill is incorrect';
  end if;

  if not exists(select 1 from public.player_picks where id=-26103 and outcome='postponed'
    and result_source='test' and resolved_home_team_id=-24109 and resolved_away_team_id=-24110
    and resolved_home_score is null and resolved_away_score is null and resolved_fixture_season='P1-SEED-2030'
    and resolved_fixture_status='postponed' and resolved_at='2030-08-17T18:10:00Z') then
    raise exception 'Postponed test-result backfill is incorrect';
  end if;

  if not exists(select 1 from public.player_picks where id=-26104 and outcome='won' and resolved_at is null
    and resolved_home_team_id is null and resolved_away_team_id is null and result_source is null) then
    raise exception 'Incomplete legacy result was not left safely unresolved';
  end if;

  if not exists(select 1 from public.player_picks where id=-26105 and outcome='pending' and resolved_at is null
    and resolved_home_team_id is null and resolved_away_team_id is null and result_source is null) then
    raise exception 'Pending legacy pick was incorrectly resolved';
  end if;

  if exists(select 1 from public.player_picks where id between -26105 and -26101 and fixture_id not in (-25101,-25102,-25103,-25104,-25105)) then
    raise exception 'A representative pick fixture reference changed';
  end if;

  report:=public.get_p1_provenance_backfill_report();
  if (report->>'resolved_picks')::integer<>4
    or (report->>'snapshotted_picks')::integer<>3
    or (report->>'unresolved_backfill_rows')::integer<>1
    or (report->>'unresolved_score_rows')::integer<>1
    or (report->>'pending_picks_with_snapshot')::integer<>0 then
    raise exception 'Backfill report did not classify the representative seed exactly: %',report;
  end if;
end;
$$;

-- Same provider IDs may coexist across seasons and keep distinct internal IDs.
insert into public.football_teams(season,fpl_team_id,code,name,short_name)
values
  ('P1-VERIFY-A',-24001,-24001,'P1 Alpha A','A-A'),
  ('P1-VERIFY-A',-24002,-24002,'P1 Beta A','B-A'),
  ('P1-VERIFY-B',-24001,-24101,'P1 Alpha B','A-B'),
  ('P1-VERIFY-B',-24002,-24102,'P1 Beta B','B-B');

insert into public.football_fixtures(
  season,fpl_fixture_id,gameweek_number,home_team_id,away_team_id,
  home_score,away_score,started,finished,status,finished_provisional
)
select 'P1-VERIFY-A',-25001,1,home.id,away.id,2,0,true,true,'finished',false
from public.football_teams home cross join public.football_teams away
where home.season='P1-VERIFY-A' and home.fpl_team_id=-24001
  and away.season='P1-VERIFY-A' and away.fpl_team_id=-24002;

insert into public.football_fixtures(
  season,fpl_fixture_id,gameweek_number,home_team_id,away_team_id,
  home_score,away_score,started,finished,status,finished_provisional
)
select 'P1-VERIFY-B',-25001,1,home.id,away.id,0,1,true,true,'finished',false
from public.football_teams home cross join public.football_teams away
where home.season='P1-VERIFY-B' and home.fpl_team_id=-24001
  and away.season='P1-VERIFY-B' and away.fpl_team_id=-24002;

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by)
select '00000000-0000-0000-0000-000000002401','P1 verification pot','P1-VERIFY-A',0,0,'draft',admin_id
from p1_verification_context;

insert into public.player_picks(
  pot_id,player_id,gameweek_number,fixture_id,team_id,outcome,
  resolved_home_team_id,resolved_away_team_id,resolved_home_score,resolved_away_score,
  result_source,resolved_at,resolved_fixture_season,resolved_fixture_status
)
select '00000000-0000-0000-0000-000000002401',context.admin_id,1,fixture.id,fixture.home_team_id,'won',
  fixture.home_team_id,fixture.away_team_id,fixture.home_score,fixture.away_score,
  'legacy_backfill',now(),fixture.season,fixture.status
from p1_verification_context context
join public.football_fixtures fixture on fixture.season='P1-VERIFY-A' and fixture.fpl_fixture_id=-25001;

-- A season-B synchronization with reused provider IDs must not update season A
-- or break the existing pick's internal fixture reference.
select public.sync_fpl_data(
  'P1-VERIFY-B',
  '[{"id":-24001,"code":-24201,"name":"P1 Alpha B updated","short_name":"ABU"},{"id":-24002,"code":-24202,"name":"P1 Beta B updated","short_name":"BBU"}]'::jsonb,
  '[{"id":-25001,"event":2,"kickoff_time":"2030-08-20T15:00:00Z","team_h":-24001,"team_a":-24002,"team_h_score":3,"team_a_score":2,"started":true,"finished":true,"finished_provisional":false,"provisional_start_time":false}]'::jsonb
);

do $$
declare team_ids bigint[];
declare fixture_ids bigint[];
begin
  select array_agg(id order by season) into team_ids from public.football_teams where fpl_team_id=-24001 and season like 'P1-VERIFY-%';
  select array_agg(id order by season) into fixture_ids from public.football_fixtures where fpl_fixture_id=-25001 and season like 'P1-VERIFY-%';
  if cardinality(team_ids)<>2 or team_ids[1]=team_ids[2] then raise exception 'Season-scoped team identity test failed'; end if;
  if cardinality(fixture_ids)<>2 or fixture_ids[1]=fixture_ids[2] then raise exception 'Season-scoped fixture identity test failed'; end if;
  if not exists(select 1 from public.football_teams where season='P1-VERIFY-A' and fpl_team_id=-24001 and name='P1 Alpha A') then
    raise exception 'Season-B synchronization modified the season-A team';
  end if;
  if not exists(select 1 from public.football_fixtures where season='P1-VERIFY-A' and fpl_fixture_id=-25001 and home_score=2 and away_score=0) then
    raise exception 'Season-B synchronization modified the season-A fixture';
  end if;
  if not exists(select 1 from public.player_picks pick join public.football_fixtures fixture on fixture.id=pick.fixture_id
    where pick.pot_id='00000000-0000-0000-0000-000000002401' and fixture.season='P1-VERIFY-A' and fixture.fpl_fixture_id=-25001) then
    raise exception 'Existing internal fixture reference was not preserved';
  end if;
end;
$$;

-- Invalid constrained values must be rejected.
do $$
begin
  begin
    update public.football_fixtures set status='not-a-status' where season='P1-VERIFY-A' and fpl_fixture_id=-25001;
    raise exception 'Invalid fixture status was accepted';
  exception when check_violation then null;
  end;
end;
$$;

-- Every unresolved legacy result must be accounted for by the report; pending
-- rows remain unresolved. Any exception here requires review before P2.
do $$
declare report jsonb;
begin
  report:=public.get_p1_provenance_backfill_report();
  if (report->>'unresolved_backfill_rows')::integer<>(select count(*) from public.player_picks where outcome<>'pending' and resolved_at is null) then
    raise exception 'Backfill report omitted an unresolved legacy pick';
  end if;
  if exists(select 1 from public.player_picks where outcome='pending' and resolved_at is not null) then
    raise exception 'A pending pick was incorrectly resolved by Phase P1';
  end if;
  if exists(select 1 from public.player_picks where resolved_at is not null and (
    resolved_home_team_id is null or resolved_away_team_id is null or result_source is null
    or resolved_fixture_season is null or resolved_fixture_status is null
  )) then
    raise exception 'A resolved-pick snapshot is incomplete';
  end if;
end;
$$;

do $$
begin
  begin
    insert into public.player_picks(
      pot_id,player_id,gameweek_number,fixture_id,team_id,outcome,
      resolved_home_team_id,resolved_away_team_id,result_source,resolved_at,
      resolved_fixture_season,resolved_fixture_status
    )
    select pot.id,pot.created_by,38,fixture.id,fixture.away_team_id,'survived',
      fixture.home_team_id,fixture.away_team_id,'not-a-source',now(),fixture.season,fixture.status
    from public.pots pot join public.football_fixtures fixture on fixture.season=pot.season
    where pot.id='00000000-0000-0000-0000-000000002401' limit 1;
    raise exception 'Invalid result source was accepted';
  exception when check_violation then null;
  end;
end;
$$;

-- Ordinary authenticated clients cannot forge provenance/audit rows or call
-- the administrator-only report.
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);

do $$
begin
  begin
    insert into public.admin_audit_events(administrator_id,action,target_type,target_identifier)
    values('00000000-0000-0000-0000-000000000001','forged','pot','forged');
    raise exception 'Authenticated audit insert was accepted';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into public.fixture_result_overrides(fixture_id,administrator_id,reason,previous_status,new_status,source)
    values(-1,'00000000-0000-0000-0000-000000000001','forged','scheduled','finished','admin_correction');
    raise exception 'Authenticated override insert was accepted';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into public.pot_player_status_history(pot_id,player_id,new_status,cause)
    values('00000000-0000-0000-0000-000000002401','00000000-0000-0000-0000-000000000001','active','processing');
    raise exception 'Authenticated status-history insert was accepted';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.get_p1_provenance_backfill_report();
    raise exception 'Non-admin accessor call was accepted';
  exception when raise_exception then
    if sqlerrm<>'Administrator access required' then raise; end if;
  end;
end;
$$;

reset role;

set local role anon;
select set_config('request.jwt.claim.sub','',true);

do $$
begin
  begin
    insert into public.admin_audit_events(administrator_id,action,target_type,target_identifier)
    values('00000000-0000-0000-0000-000000000001','forged-anon','pot','forged');
    raise exception 'Anon audit insert was accepted';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.get_p1_provenance_backfill_report();
    raise exception 'Anon accessor call was accepted';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
rollback;
