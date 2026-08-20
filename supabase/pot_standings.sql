-- 19 — Pot standings board
-- Run once in the Supabase SQL Editor after tournament_operations.sql.

create or replace function public.get_pot_standings(selected_pot_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id) then raise exception 'Pot not found'; end if;

  select jsonb_build_object(
    'pot_id',pot.id,
    'pot_name',pot.name,
    'season',pot.season,
    'status',pot.status,
    'gameweeks',coalesce((
      select jsonb_agg(gameweek.gameweek_number order by gameweek.gameweek_number)
      from public.pot_gameweeks gameweek
      where gameweek.pot_id=pot.id
    ),'[]'::jsonb),
    'players',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',profile.id,
        'name',coalesce(nullif(trim(concat_ws(' ',profile.first_name,profile.last_name)),''),profile.display_name,profile.email),
        'email',profile.email,
        'player_status',membership.player_status,
        'payment_status',membership.payment_status,
        'buy_back_status',membership.buy_back_status,
        'picks',coalesce((
          select jsonb_agg(jsonb_build_object(
            'gameweek_number',pick.gameweek_number,
            'team_name',team.name,
            'short_name',team.short_name,
            'emblem_url',team.emblem_url,
            'selection_source',pick.selection_source,
            'outcome',pick.outcome
          ) order by pick.gameweek_number)
          from public.player_picks pick
          join public.football_teams team on team.id=pick.team_id
          where pick.pot_id=pot.id and pick.player_id=membership.player_id
        ),'[]'::jsonb)
      ) order by
        case membership.player_status when 'winner' then 0 when 'active' then 1 else 2 end,
        coalesce(profile.first_name,profile.display_name,profile.email))
      from public.pot_players membership
      join public.profiles profile on profile.id=membership.player_id
      where membership.pot_id=pot.id
    ),'[]'::jsonb)
  ) into result
  from public.pots pot where pot.id=selected_pot_id;

  return result;
end;
$$;
revoke all on function public.get_pot_standings(uuid) from public;
grant execute on function public.get_pot_standings(uuid) to authenticated;
