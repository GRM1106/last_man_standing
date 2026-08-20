-- 11 — Admin pick overview
-- Run once in the Supabase SQL Editor after player_pick_setup.sql.

create or replace function public.get_admin_pick_overview(selected_pot_id uuid,selected_gameweek integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id) then raise exception 'Pot not found'; end if;
  if not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'Gameweek is not part of this pot'; end if;

  select jsonb_build_object(
    'pot_id',pot.id,'pot_name',pot.name,'gameweek_number',selected_gameweek,
    'players',coalesce(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',coalesce(nullif(trim(concat_ws(' ',profile.first_name,profile.last_name)),''),profile.display_name,profile.email),
      'email',profile.email,'player_status',membership.player_status,'payment_status',membership.payment_status,
      'pick',case when pick.id is null then null else jsonb_build_object(
        'id',pick.id,'team_name',team.name,'emblem_url',team.emblem_url,
        'home_name',home.name,'away_name',away.name,'kickoff_at',fixture.kickoff_at,
        'selection_source',pick.selection_source,'outcome',pick.outcome,'confirmed_at',pick.confirmed_at
      ) end
    ) order by coalesce(profile.first_name,profile.display_name,profile.email)),'[]'::jsonb)
  ) into result
  from public.pots pot
  left join public.pot_players membership on membership.pot_id=pot.id
  left join public.profiles profile on profile.id=membership.player_id
  left join public.player_picks pick on pick.pot_id=pot.id and pick.player_id=profile.id and pick.gameweek_number=selected_gameweek
  left join public.football_teams team on team.id=pick.team_id
  left join public.football_fixtures fixture on fixture.id=pick.fixture_id
  left join public.football_teams home on home.id=fixture.home_team_id
  left join public.football_teams away on away.id=fixture.away_team_id
  where pot.id=selected_pot_id
  group by pot.id,pot.name;
  return result;
end;
$$;
revoke all on function public.get_admin_pick_overview(uuid,integer) from public;
grant execute on function public.get_admin_pick_overview(uuid,integer) to authenticated;
