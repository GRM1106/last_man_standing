-- 23 — Player team availability list
-- Run once in the Supabase SQL Editor after standings_window.sql.

create or replace function public.get_my_team_availability(selected_pot_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid())) then
    raise exception 'You are not assigned to this pot';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',team.id,'name',team.name,'short_name',team.short_name,'emblem_url',team.emblem_url,
    'available',not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=(select auth.uid()) and used.team_id=team.id)
  ) order by team.name),'[]'::jsonb) into result
  from public.football_teams team
  where exists(select 1 from public.football_fixtures fixture join public.pots pot on pot.id=selected_pot_id and pot.season=fixture.season
    where team.id in (fixture.home_team_id,fixture.away_team_id));
  return result;
end;
$$;
revoke all on function public.get_my_team_availability(uuid) from public;
grant execute on function public.get_my_team_availability(uuid) to authenticated;
