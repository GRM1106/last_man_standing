-- 16 — Random picks for missing selections
-- Run once in the Supabase SQL Editor after pot_management.sql.

create or replace function public.assign_random_missing_picks(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare selected_pot public.pots%rowtype;
declare missing_count integer;
declare no_team_count integer;
declare inserted_count integer := 0;
declare fixtures_ready boolean;
declare problems text[] := array[]::text[];
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select * into selected_pot from public.pots where id=selected_pot_id;
  if not found then raise exception 'Pot not found'; end if;
  if not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'Gameweek is not part of this pot'; end if;
  if exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then problems:=array_append(problems,'This gameweek has already been processed.'); end if;

  select count(*) into missing_count from public.pot_players membership
  where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek);

  select exists(select 1 from public.football_fixtures fixture where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek)
    and not exists(select 1 from public.football_fixtures fixture where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
      and (not fixture.finished or fixture.home_score is null or fixture.away_score is null)) into fixtures_ready;

  select count(*) into no_team_count from public.pot_players membership
  where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek)
    and not exists(select 1 from (
      select fixture.home_team_id as team_id from public.football_fixtures fixture where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
      union select fixture.away_team_id from public.football_fixtures fixture where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
    ) option_team where not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=membership.player_id and used.team_id=option_team.team_id));

  if missing_count=0 then problems:=array_append(problems,'Every paid active player already has a pick.'); end if;
  if no_team_count>0 then problems:=array_append(problems,no_team_count||' player(s) have no unused team available in this gameweek.'); end if;
  if not selected_pot.test_mode and not fixtures_ready then problems:=array_append(problems,'All fixtures must have final results before random picks are assigned.'); end if;
  if not apply_changes then return jsonb_build_object('ready',cardinality(problems)=0,'missing',missing_count,'test_mode',selected_pot.test_mode,'problems',to_jsonb(problems)); end if;
  if cardinality(problems)>0 then raise exception '%',array_to_string(problems,' '); end if;

  perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),selected_gameweek);
  insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source)
  select selected_pot_id,membership.player_id,selected_gameweek,candidate.fixture_id,candidate.team_id,'random'
  from public.pot_players membership
  cross join lateral (
    select option.fixture_id,option.team_id from (
      select fixture.id as fixture_id,fixture.home_team_id as team_id from public.football_fixtures fixture where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
      union all
      select fixture.id,fixture.away_team_id from public.football_fixtures fixture where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
    ) option
    where not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=membership.player_id and used.team_id=option.team_id)
    order by random() limit 1
  ) candidate
  where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek)
  on conflict do nothing;
  get diagnostics inserted_count=row_count;
  return jsonb_build_object('ready',true,'assigned',inserted_count,'test_mode',selected_pot.test_mode,'problems','[]'::jsonb);
end;
$$;
revoke all on function public.assign_random_missing_picks(uuid,integer,boolean) from public;
grant execute on function public.assign_random_missing_picks(uuid,integer,boolean) to authenticated;
