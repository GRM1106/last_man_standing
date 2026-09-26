-- Keep contact details in their explicit administrator field, never as a fallback name.
begin;
CREATE OR REPLACE FUNCTION public.get_admin_pick_overview(selected_pot_id uuid, selected_gameweek integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id) then raise exception 'Pot not found'; end if;
  if not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'Gameweek is not part of this pot'; end if;
  select jsonb_build_object('pot_id',pot.id,'pot_name',pot.name,'pot_status',pot.status,'test_mode',pot.test_mode,'gameweek_number',selected_gameweek,
    'players',coalesce(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',public.lms_player_display_name(profile.first_name,profile.last_name,profile.display_name,profile.email),
      'email',profile.email,'player_status',membership.player_status,'payment_status',membership.payment_status,
      'pick',case when pick.id is null then null else jsonb_build_object(
        'id',pick.id,'team_name',team.name,'emblem_url',team.emblem_url,'home_name',home.name,'away_name',away.name,
        'kickoff_at',fixture.kickoff_at,'selection_source',pick.selection_source,'outcome',pick.outcome,
        'preview_outcome',case
          when not pot.test_mode or test_result.fixture_id is null then pick.outcome
          when test_result.postponed then 'postponed'
          -- In Last Man Standing, a draw eliminates the player just like a loss.
          when test_result.home_score=test_result.away_score then 'lost'
          when (pick.team_id=fixture.home_team_id and test_result.home_score>test_result.away_score)
            or (pick.team_id=fixture.away_team_id and test_result.away_score>test_result.home_score) then 'won'
          else 'lost' end,
        'confirmed_at',pick.confirmed_at
      ) end
    ) order by coalesce(profile.first_name,profile.display_name,profile.email)) filter (where membership.player_id is not null),'[]'::jsonb)) into result
  from public.pots pot
  left join public.pot_players membership on membership.pot_id=pot.id
  left join public.profiles profile on profile.id=membership.player_id
  left join public.player_picks pick on pick.pot_id=pot.id and pick.player_id=profile.id and pick.gameweek_number=selected_gameweek
  left join public.football_teams team on team.id=pick.team_id
  left join public.football_fixtures fixture on fixture.id=pick.fixture_id
  left join public.football_teams home on home.id=fixture.home_team_id
  left join public.football_teams away on away.id=fixture.away_team_id
  left join public.pot_fixture_test_results test_result on test_result.pot_id=pot.id and test_result.fixture_id=fixture.id
  where pot.id=selected_pot_id group by pot.id,pot.name,pot.status,pot.test_mode;
  return result;
end;
$function$;
commit;
