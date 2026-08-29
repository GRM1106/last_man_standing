-- 18 — Tournament lifecycle, history and test reset
-- Run once in the Supabase SQL Editor after round_progression.sql.

create or replace function public.set_pot_status(selected_pot_id uuid,new_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare current_status text;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if new_status not in ('draft','open','active','complete') then raise exception 'Invalid pot status'; end if;
  select status into current_status from public.pots where id=selected_pot_id;
  if not found then raise exception 'Pot not found'; end if;
  if current_status='complete' and new_status<>'complete' then raise exception 'A completed pot cannot be reopened'; end if;
  if new_status='complete' and current_status<>'complete' then raise exception 'Use the winner control to complete a pot'; end if;
  if current_status='active' and new_status<>'active' then raise exception 'An active pot can only be completed by crowning its winner'; end if;
  if new_status<>'draft' and exists(select 1 from public.pots where id=selected_pot_id and test_mode) then
    raise exception 'Disable test mode before moving a pot out of draft';
  end if;
  update public.pots set status=new_status where id=selected_pot_id;
end;
$$;
revoke all on function public.set_pot_status(uuid,text) from public;
grant execute on function public.set_pot_status(uuid,text) to authenticated;

create or replace function public.complete_pot_with_winner(selected_pot_id uuid,selected_winner_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status<>'complete') then raise exception 'Pot not found or already complete'; end if;
  if not exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=selected_winner_id and player_status='active') then
    raise exception 'Winner must be an active player in this pot';
  end if;
  if not exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id) then
    raise exception 'Process at least one gameweek before completing the pot';
  end if;
  if (select count(*) from public.pot_players where pot_id=selected_pot_id and player_status='active')<>1 then
    raise exception 'The pot can only be completed when exactly one active player remains';
  end if;
  if exists(select 1 from public.pot_players where pot_id=selected_pot_id and buy_back_status='claimed') then
    raise exception 'Resolve pending buy-back claims before completing the pot';
  end if;
  update public.pot_players set player_status='winner' where pot_id=selected_pot_id and player_id=selected_winner_id;
  update public.pots set status='complete',test_mode=false where id=selected_pot_id;
end;
$$;
revoke all on function public.complete_pot_with_winner(uuid,uuid) from public;
grant execute on function public.complete_pot_with_winner(uuid,uuid) to authenticated;

create or replace function public.reset_draft_test_pot(selected_pot_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status='draft' and test_mode) then
    raise exception 'Only a draft pot in test mode can be fully reset';
  end if;
  delete from public.pot_gameweek_processes where pot_id=selected_pot_id;
  delete from public.pot_fixture_test_results where pot_id=selected_pot_id;
  delete from public.player_picks where pot_id=selected_pot_id;
  update public.pot_players set player_status='active',buy_back_status='available',buy_back_claimed_at=null,buy_back_used_at=null
    where pot_id=selected_pot_id and player_status<>'withdrawn';
end;
$$;
revoke all on function public.reset_draft_test_pot(uuid) from public;
grant execute on function public.reset_draft_test_pot(uuid) to authenticated;

create or replace function public.get_my_pot_history(selected_pot_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid()))
    and not (select public.is_current_user_admin()) then raise exception 'You are not assigned to this pot'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'gameweek_number',pick.gameweek_number,'team_name',team.name,'emblem_url',team.emblem_url,
    'home_name',home.name,'away_name',away.name,'kickoff_at',fixture.kickoff_at,
    'selection_source',pick.selection_source,'outcome',pick.outcome
  ) order by pick.gameweek_number),'[]'::jsonb) into result
  from public.player_picks pick
  join public.football_teams team on team.id=pick.team_id
  join public.football_fixtures fixture on fixture.id=pick.fixture_id
  join public.football_teams home on home.id=fixture.home_team_id
  join public.football_teams away on away.id=fixture.away_team_id
  where pick.pot_id=selected_pot_id and pick.player_id=(select auth.uid());
  return result;
end;
$$;
revoke all on function public.get_my_pot_history(uuid) from public;
grant execute on function public.get_my_pot_history(uuid) to authenticated;
