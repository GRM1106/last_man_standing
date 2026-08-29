-- 17 — Advance player dashboard after a completed round
-- Run once in the Supabase SQL Editor after random_pick_setup.sql.

create or replace function public.get_pot_selection(selected_pot_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare membership public.pot_players%rowtype;
declare selected_gameweek integer;
declare saved_pick jsonb;
declare fixture_options jsonb;
declare remaining_teams jsonb;
begin
  select * into membership from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid());
  if not found then raise exception 'You are not assigned to this pot'; end if;

  select pick.gameweek_number into selected_gameweek from public.player_picks pick
  where pick.pot_id=selected_pot_id and pick.player_id=(select auth.uid()) and pick.outcome='pending'
  order by pick.gameweek_number desc limit 1;

  if selected_gameweek is null then
    select gameweek.gameweek_number into selected_gameweek
    from public.pot_gameweeks gameweek join public.pots pot on pot.id=gameweek.pot_id
    where gameweek.pot_id=selected_pot_id
      and not exists(select 1 from public.pot_gameweek_processes processed
        where processed.pot_id=selected_pot_id and processed.gameweek_number=gameweek.gameweek_number)
      and exists(select 1 from public.football_fixtures fixture
        where fixture.season=pot.season and fixture.gameweek_number=gameweek.gameweek_number
          and fixture.kickoff_at>now() and not fixture.finished)
    order by gameweek.gameweek_number limit 1;
  end if;

  select jsonb_build_object('id',pick.id,'gameweek_number',pick.gameweek_number,'team_id',pick.team_id,
    'fixture_id',pick.fixture_id,'outcome',pick.outcome,'confirmed_at',pick.confirmed_at,
    'team_name',team.name,'emblem_url',team.emblem_url,'home_name',home.name,'away_name',away.name,'kickoff_at',fixture.kickoff_at)
  into saved_pick from public.player_picks pick
  join public.football_teams team on team.id=pick.team_id
  join public.football_fixtures fixture on fixture.id=pick.fixture_id
  join public.football_teams home on home.id=fixture.home_team_id
  join public.football_teams away on away.id=fixture.away_team_id
  where pick.pot_id=selected_pot_id and pick.player_id=(select auth.uid()) and pick.gameweek_number=selected_gameweek;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',fixture.id,'gameweek_number',fixture.gameweek_number,'kickoff_at',fixture.kickoff_at,
    'started',fixture.started,'finished',fixture.finished,'home_score',fixture.home_score,'away_score',fixture.away_score,
    'home_team',jsonb_build_object('id',home.id,'name',home.name,'short_name',home.short_name,'emblem_url',home.emblem_url,
      'form',coalesce((select to_jsonb(form.last_five) from public.football_team_form form where form.team_id=home.id),'[]'::jsonb),
      'available',not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=(select auth.uid()) and used.team_id=home.id)),
    'away_team',jsonb_build_object('id',away.id,'name',away.name,'short_name',away.short_name,'emblem_url',away.emblem_url,
      'form',coalesce((select to_jsonb(form.last_five) from public.football_team_form form where form.team_id=away.id),'[]'::jsonb),
      'available',not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=(select auth.uid()) and used.team_id=away.id))
  ) order by fixture.kickoff_at),'[]'::jsonb) into fixture_options
  from public.football_fixtures fixture
  join public.pots pot on pot.id=selected_pot_id and pot.season=fixture.season
  join public.football_teams home on home.id=fixture.home_team_id
  join public.football_teams away on away.id=fixture.away_team_id
  where fixture.gameweek_number=selected_gameweek;

  select coalesce(jsonb_agg(jsonb_build_object('id',team.id,'name',team.name,'short_name',team.short_name,'emblem_url',team.emblem_url)
    order by team.name),'[]'::jsonb) into remaining_teams from public.football_teams team
  where not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id
    and used.player_id=(select auth.uid()) and used.team_id=team.id);

  return jsonb_build_object('gameweek_number',selected_gameweek,'payment_status',membership.payment_status,
    'player_status',membership.player_status,'pick',saved_pick,'fixtures',fixture_options,'remaining_teams',remaining_teams);
end;
$$;
revoke all on function public.get_pot_selection(uuid) from public;
grant execute on function public.get_pot_selection(uuid) to authenticated;
