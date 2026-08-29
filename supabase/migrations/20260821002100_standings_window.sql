-- 22 — Progressive standings gameweek window
-- Run once in the Supabase SQL Editor after player_standings.sql.

create or replace function public.get_pot_standings(selected_pot_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; declare viewer_is_admin boolean;
begin
  viewer_is_admin:=(select public.is_current_user_admin());
  if not viewer_is_admin and not exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid())) then raise exception 'You are not assigned to this pot'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id) then raise exception 'Pot not found'; end if;
  select jsonb_build_object('pot_id',pot.id,'pot_name',pot.name,'season',pot.season,'status',pot.status,
    'current_gameweek',coalesce(
      (select min(gameweek.gameweek_number) from public.pot_gameweeks gameweek where gameweek.pot_id=pot.id and not exists(select 1 from public.pot_gameweek_processes processed where processed.pot_id=pot.id and processed.gameweek_number=gameweek.gameweek_number)),
      (select max(gameweek.gameweek_number) from public.pot_gameweeks gameweek where gameweek.pot_id=pot.id)),
    'gameweeks',coalesce((select jsonb_agg(visible_gameweek.gameweek_number order by visible_gameweek.gameweek_number) from (
      select gameweek.gameweek_number from public.pot_gameweeks gameweek where gameweek.pot_id=pot.id order by gameweek.gameweek_number
      limit greatest(5,(select count(*)+1 from public.pot_gameweek_processes processed where processed.pot_id=pot.id))
    ) visible_gameweek),'[]'::jsonb),
    'players',coalesce((select jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',coalesce(nullif(trim(concat_ws(' ',profile.first_name,profile.last_name)),''),profile.display_name,profile.email),
      'email',case when viewer_is_admin then profile.email else null end,'player_status',membership.player_status,
      'payment_status',case when viewer_is_admin then membership.payment_status else null end,'buy_back_status',case when viewer_is_admin then membership.buy_back_status else null end,
      'picks',coalesce((select jsonb_agg(jsonb_build_object('gameweek_number',pick.gameweek_number,'team_name',team.name,'short_name',team.short_name,
        'emblem_url',team.emblem_url,'selection_source',pick.selection_source,'outcome',pick.outcome) order by pick.gameweek_number)
        from public.player_picks pick join public.football_teams team on team.id=pick.team_id
        where pick.pot_id=pot.id and pick.player_id=membership.player_id and (viewer_is_admin
          or exists(select 1 from public.pot_gameweek_processes processed where processed.pot_id=pot.id and processed.gameweek_number=pick.gameweek_number)
          or now()>=(select min(fixture.kickoff_at) from public.football_fixtures fixture where fixture.season=pot.season and fixture.gameweek_number=pick.gameweek_number))),'[]'::jsonb)
    ) order by case membership.player_status when 'winner' then 0 when 'active' then 1 else 2 end,coalesce(profile.first_name,profile.display_name,profile.email))
    from public.pot_players membership join public.profiles profile on profile.id=membership.player_id where membership.pot_id=pot.id),'[]'::jsonb)
  ) into result from public.pots pot where pot.id=selected_pot_id;
  return result;
end;
$$;
revoke all on function public.get_pot_standings(uuid) from public;
grant execute on function public.get_pot_standings(uuid) to authenticated;
