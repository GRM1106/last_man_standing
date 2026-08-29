-- 20 — Pick deadlines and random assignment audit
-- Run once in the Supabase SQL Editor after pot_standings.sql.

alter table public.player_picks add column if not exists selection_reason text;

create or replace function public.get_gameweek_deadline(selected_pot_id uuid,selected_gameweek integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare deadline timestamptz; declare test_enabled boolean;
begin
  if not exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid()))
    and not (select public.is_current_user_admin()) then raise exception 'You are not assigned to this pot'; end if;
  if not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'Gameweek is not part of this pot'; end if;
  select min(fixture.kickoff_at),pot.test_mode into deadline,test_enabled
  from public.pots pot left join public.football_fixtures fixture on fixture.season=pot.season and fixture.gameweek_number=selected_gameweek
  where pot.id=selected_pot_id group by pot.test_mode;
  return jsonb_build_object('deadline',deadline,'deadline_passed',deadline is not null and now()>=deadline,'test_mode',test_enabled);
end;
$$;
revoke all on function public.get_gameweek_deadline(uuid,integer) from public;
grant execute on function public.get_gameweek_deadline(uuid,integer) to authenticated;

create or replace function public.confirm_team_pick(selected_pot_id uuid,selected_fixture_id bigint,selected_team_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare membership public.pot_players%rowtype; declare fixture public.football_fixtures%rowtype; declare deadline timestamptz;
begin
  select * into membership from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid());
  if not found then raise exception 'You are not assigned to this pot'; end if;
  if membership.player_status<>'active' then raise exception 'You are not active in this pot'; end if;
  if membership.payment_status<>'paid' then raise exception 'Your entry payment must be confirmed before selecting a team'; end if;
  if not exists(select 1 from public.profiles where id=(select auth.uid()) and approved) then raise exception 'Your account is awaiting approval'; end if;
  select football_fixture.* into fixture from public.football_fixtures football_fixture join public.pots pot on pot.id=selected_pot_id and pot.season=football_fixture.season where football_fixture.id=selected_fixture_id;
  if not found then raise exception 'Fixture not found for this pot'; end if;
  if fixture.gameweek_number is null or not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=fixture.gameweek_number) then raise exception 'This gameweek is not part of the pot'; end if;
  select min(candidate.kickoff_at) into deadline from public.football_fixtures candidate join public.pots pot on pot.id=selected_pot_id and pot.season=candidate.season where candidate.gameweek_number=fixture.gameweek_number and candidate.kickoff_at is not null;
  if deadline is null then raise exception 'The gameweek deadline is not available yet'; end if;
  if now()>=deadline then raise exception 'The gameweek pick deadline has passed'; end if;
  if selected_team_id not in (fixture.home_team_id,fixture.away_team_id) then raise exception 'Select a team playing in this fixture'; end if;
  if exists(select 1 from public.player_picks where pot_id=selected_pot_id and player_id=(select auth.uid()) and gameweek_number=fixture.gameweek_number) then raise exception 'Your pick for this gameweek is already locked'; end if;
  if exists(select 1 from public.player_picks where pot_id=selected_pot_id and player_id=(select auth.uid()) and team_id=selected_team_id) then raise exception 'You have already used that team in this pot'; end if;
  insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,selection_reason)
  values(selected_pot_id,(select auth.uid()),fixture.gameweek_number,selected_fixture_id,selected_team_id,'manual','Player confirmed before the gameweek deadline');
end;
$$;
revoke all on function public.confirm_team_pick(uuid,bigint,bigint) from public;
grant execute on function public.confirm_team_pick(uuid,bigint,bigint) to authenticated;

create or replace function public.assign_random_missing_picks(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare selected_pot public.pots%rowtype; declare missing_count integer; declare no_team_count integer; declare inserted_count integer:=0;
declare deadline timestamptz; declare problems text[]:=array[]::text[];
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select * into selected_pot from public.pots where id=selected_pot_id; if not found then raise exception 'Pot not found'; end if;
  if not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'Gameweek is not part of this pot'; end if;
  select min(kickoff_at) into deadline from public.football_fixtures where season=selected_pot.season and gameweek_number=selected_gameweek and kickoff_at is not null;
  if exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then problems:=array_append(problems,'This gameweek has already been processed.'); end if;
  select count(*) into missing_count from public.pot_players membership where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek);
  select count(*) into no_team_count from public.pot_players membership where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek)
    and not exists(select 1 from (select home_team_id team_id from public.football_fixtures where season=selected_pot.season and gameweek_number=selected_gameweek
      union select away_team_id from public.football_fixtures where season=selected_pot.season and gameweek_number=selected_gameweek) option_team
      where not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=membership.player_id and used.team_id=option_team.team_id));
  if deadline is null then problems:=array_append(problems,'The gameweek deadline is not available.');
  elsif not selected_pot.test_mode and now()<deadline then problems:=array_append(problems,'Random picks cannot be assigned before the gameweek deadline.'); end if;
  if missing_count=0 then problems:=array_append(problems,'Every paid active player already has a pick.'); end if;
  if no_team_count>0 then problems:=array_append(problems,no_team_count||' player(s) have no unused team available in this gameweek.'); end if;
  if not apply_changes then return jsonb_build_object('ready',cardinality(problems)=0,'missing',missing_count,'test_mode',selected_pot.test_mode,'deadline',deadline,'deadline_passed',selected_pot.test_mode or (deadline is not null and now()>=deadline),'problems',to_jsonb(problems)); end if;
  if cardinality(problems)>0 then raise exception '%',array_to_string(problems,' '); end if;
  perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),selected_gameweek);
  insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,selection_reason)
  select selected_pot_id,membership.player_id,selected_gameweek,candidate.fixture_id,candidate.team_id,'random',
    case when selected_pot.test_mode then 'Test-mode random assignment for a missing pick' else 'No player pick was received before the gameweek deadline' end
  from public.pot_players membership cross join lateral (
    select option.fixture_id,option.team_id from (select id fixture_id,home_team_id team_id from public.football_fixtures where season=selected_pot.season and gameweek_number=selected_gameweek
      union all select id,away_team_id from public.football_fixtures where season=selected_pot.season and gameweek_number=selected_gameweek) option
    where not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=membership.player_id and used.team_id=option.team_id)
    order by random() limit 1) candidate
  where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek)
  on conflict do nothing; get diagnostics inserted_count=row_count;
  return jsonb_build_object('ready',true,'assigned',inserted_count,'test_mode',selected_pot.test_mode,'deadline',deadline,'problems','[]'::jsonb);
end;
$$;
revoke all on function public.assign_random_missing_picks(uuid,integer,boolean) from public;
grant execute on function public.assign_random_missing_picks(uuid,integer,boolean) to authenticated;
