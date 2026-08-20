-- 13 — Gameweek result processing
-- Run once in the Supabase SQL Editor after test_result_setup.sql.

create table if not exists public.pot_gameweek_processes (
  pot_id uuid not null references public.pots(id) on delete cascade,
  gameweek_number integer not null check (gameweek_number between 1 and 38),
  test_run boolean not null default false,
  summary jsonb not null,
  processed_by uuid not null references public.profiles(id),
  processed_at timestamptz not null default now(),
  primary key (pot_id,gameweek_number)
);
alter table public.pot_gameweek_processes enable row level security;
revoke all on table public.pot_gameweek_processes from public,authenticated;

create or replace function public.process_pot_gameweek(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare selected_pot public.pots%rowtype;
declare player_count integer;
declare winners integer;
declare losers integer;
declare postponed_count integer;
declare unpaid_count integer;
declare missing_count integer;
declare unavailable_count integer;
declare already_processed boolean;
declare problems text[] := array[]::text[];
declare result jsonb;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select * into selected_pot from public.pots where id=selected_pot_id;
  if not found then raise exception 'Pot not found'; end if;
  if not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'Gameweek is not part of this pot'; end if;
  if selected_pot.test_mode and selected_pot.status<>'draft' then raise exception 'Test mode is only allowed on draft pots'; end if;

  select exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek) into already_processed;
  select count(*) into player_count from public.pot_players where pot_id=selected_pot_id and player_status='active';
  select count(*) into unpaid_count from public.pot_players where pot_id=selected_pot_id and player_status='active' and payment_status<>'paid';
  select count(*) into missing_count from public.pot_players membership where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek);
  select count(*) into unavailable_count from public.player_picks pick
    join public.football_fixtures fixture on fixture.id=pick.fixture_id
    left join public.pot_fixture_test_results test_result on test_result.pot_id=selected_pot_id and test_result.fixture_id=fixture.id
    where pick.pot_id=selected_pot_id and pick.gameweek_number=selected_gameweek and pick.outcome='pending'
      and case when selected_pot.test_mode then test_result.fixture_id is null
        else not fixture.finished or fixture.home_score is null or fixture.away_score is null end;

  if already_processed then problems:=array_append(problems,'This gameweek has already been processed.'); end if;
  if unpaid_count>0 then problems:=array_append(problems,unpaid_count||' active player(s) still need payment confirmation.'); end if;
  if missing_count>0 then problems:=array_append(problems,missing_count||' paid active player(s) do not have a locked pick.'); end if;
  if unavailable_count>0 then problems:=array_append(problems,unavailable_count||' pick result(s) are not available yet.'); end if;

  with resolved as (
    select pick.id,
      case
        when selected_pot.test_mode and test_result.postponed then 'postponed'
        when selected_pot.test_mode and test_result.home_score=test_result.away_score then 'lost'
        when selected_pot.test_mode and ((pick.team_id=fixture.home_team_id and test_result.home_score>test_result.away_score) or (pick.team_id=fixture.away_team_id and test_result.away_score>test_result.home_score)) then 'won'
        when selected_pot.test_mode then 'lost'
        when fixture.home_score=fixture.away_score then 'lost'
        when (pick.team_id=fixture.home_team_id and fixture.home_score>fixture.away_score) or (pick.team_id=fixture.away_team_id and fixture.away_score>fixture.home_score) then 'won'
        else 'lost' end as resolved_outcome
    from public.player_picks pick
    join public.football_fixtures fixture on fixture.id=pick.fixture_id
    left join public.pot_fixture_test_results test_result on test_result.pot_id=selected_pot_id and test_result.fixture_id=fixture.id
    where pick.pot_id=selected_pot_id and pick.gameweek_number=selected_gameweek
  ) select count(*) filter(where resolved_outcome='won'),count(*) filter(where resolved_outcome='lost'),count(*) filter(where resolved_outcome='postponed')
    into winners,losers,postponed_count from resolved;

  result:=jsonb_build_object('pot_id',selected_pot_id,'pot_name',selected_pot.name,'gameweek_number',selected_gameweek,
    'test_mode',selected_pot.test_mode,'processed',already_processed,'ready',cardinality(problems)=0,
    'player_count',player_count,'winners',coalesce(winners,0),'losers',coalesce(losers,0),'postponed',coalesce(postponed_count,0),'problems',to_jsonb(problems));
  if not apply_changes then return result; end if;
  if cardinality(problems)>0 then raise exception '%',array_to_string(problems,' '); end if;

  perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),selected_gameweek);
  if exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'This gameweek has already been processed'; end if;

  with resolved as (
    select pick.id,pick.player_id,
      case
        when selected_pot.test_mode and test_result.postponed then 'postponed'
        when selected_pot.test_mode and test_result.home_score=test_result.away_score then 'lost'
        when selected_pot.test_mode and ((pick.team_id=fixture.home_team_id and test_result.home_score>test_result.away_score) or (pick.team_id=fixture.away_team_id and test_result.away_score>test_result.home_score)) then 'won'
        when selected_pot.test_mode then 'lost'
        when fixture.home_score=fixture.away_score then 'lost'
        when (pick.team_id=fixture.home_team_id and fixture.home_score>fixture.away_score) or (pick.team_id=fixture.away_team_id and fixture.away_score>fixture.home_score) then 'won'
        else 'lost' end as resolved_outcome
    from public.player_picks pick join public.football_fixtures fixture on fixture.id=pick.fixture_id
    left join public.pot_fixture_test_results test_result on test_result.pot_id=selected_pot_id and test_result.fixture_id=fixture.id
    where pick.pot_id=selected_pot_id and pick.gameweek_number=selected_gameweek
  ), updated_picks as (
    update public.player_picks pick set outcome=resolved.resolved_outcome from resolved where pick.id=resolved.id returning pick.player_id,pick.outcome
  ) update public.pot_players membership set player_status='eliminated'
    where membership.pot_id=selected_pot_id and membership.player_status='active'
      and exists(select 1 from updated_picks pick where pick.player_id=membership.player_id and pick.outcome='lost');

  insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by)
  values(selected_pot_id,selected_gameweek,selected_pot.test_mode,result,(select auth.uid()));
  return result||jsonb_build_object('processed',true);
end;
$$;
revoke all on function public.process_pot_gameweek(uuid,integer,boolean) from public;
grant execute on function public.process_pot_gameweek(uuid,integer,boolean) to authenticated;

create or replace function public.reset_test_gameweek(selected_pot_id uuid,selected_gameweek integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status='draft' and test_mode) then raise exception 'This is not a draft pot in test mode'; end if;
  if not exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek and test_run) then raise exception 'No processed test run was found'; end if;
  update public.pot_players membership set player_status='active'
    where membership.pot_id=selected_pot_id and exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id and pick.gameweek_number=selected_gameweek and pick.player_id=membership.player_id and pick.outcome='lost');
  update public.player_picks set outcome='pending' where pot_id=selected_pot_id and gameweek_number=selected_gameweek;
  delete from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek;
  delete from public.pot_fixture_test_results test_result using public.football_fixtures fixture
    where test_result.pot_id=selected_pot_id and test_result.fixture_id=fixture.id and fixture.gameweek_number=selected_gameweek;
end;
$$;
revoke all on function public.reset_test_gameweek(uuid,integer) from public;
grant execute on function public.reset_test_gameweek(uuid,integer) to authenticated;
