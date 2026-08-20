-- 14 — One-time buy-back workflow
-- Run once in the Supabase SQL Editor after gameweek_processing.sql.

alter table public.pot_players add column if not exists buy_back_claimed_at timestamptz;
alter table public.pot_players add column if not exists buy_back_used_at timestamptz;

create or replace function public.claim_buy_back(selected_pot_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare membership public.pot_players%rowtype;
declare eliminated_gameweek integer;
declare next_gameweek integer;
declare deadline timestamptz;
begin
  select * into membership from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid());
  if not found then raise exception 'You are not assigned to this pot'; end if;
  if membership.player_status<>'eliminated' then raise exception 'Buy-back is only available after elimination'; end if;
  if membership.buy_back_status<>'available' then raise exception 'Your one-time buy-back is no longer available'; end if;
  select max(gameweek_number) into eliminated_gameweek from public.player_picks
    where pot_id=selected_pot_id and player_id=(select auth.uid()) and outcome='lost';
  if eliminated_gameweek is null then raise exception 'No elimination result was found'; end if;
  select min(gameweek_number) into next_gameweek from public.pot_gameweeks
    where pot_id=selected_pot_id and gameweek_number>eliminated_gameweek;
  select min(fixture.kickoff_at) into deadline from public.football_fixtures fixture
    join public.pots pot on pot.id=selected_pot_id and pot.season=fixture.season
    where fixture.gameweek_number=next_gameweek and fixture.kickoff_at is not null;
  if next_gameweek is null or deadline is null then raise exception 'The next gameweek deadline is not available yet'; end if;
  if now()>=deadline then raise exception 'The buy-back deadline has passed'; end if;
  update public.pot_players set buy_back_status='claimed',buy_back_claimed_at=now()
    where pot_id=selected_pot_id and player_id=(select auth.uid());
end;
$$;
revoke all on function public.claim_buy_back(uuid) from public;
grant execute on function public.claim_buy_back(uuid) to authenticated;

create or replace function public.set_buy_back_decision(selected_pot_id uuid,selected_player_id uuid,approved boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare membership public.pot_players%rowtype;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select * into membership from public.pot_players where pot_id=selected_pot_id and player_id=selected_player_id;
  if not found then raise exception 'Pot player not found'; end if;
  if membership.buy_back_status<>'claimed' then raise exception 'This player does not have a pending buy-back claim'; end if;
  if approved then
    update public.pot_players set player_status='active',buy_back_status='used',buy_back_used_at=now()
      where pot_id=selected_pot_id and player_id=selected_player_id;
  else
    update public.pot_players set buy_back_status='available',buy_back_claimed_at=null
      where pot_id=selected_pot_id and player_id=selected_player_id;
  end if;
end;
$$;
revoke all on function public.set_buy_back_decision(uuid,uuid,boolean) from public;
grant execute on function public.set_buy_back_decision(uuid,uuid,boolean) to authenticated;

create or replace function public.get_my_dashboard()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('approved',coalesce(profile.approved,false),'first_name',profile.first_name,'email',profile.email,
    'pots',coalesce((select jsonb_agg(jsonb_build_object(
      'id',pot.id,'name',pot.name,'season',pot.season,'status',pot.status,
      'entry_fee_pence',pot.entry_fee_pence,'buy_back_fee_pence',pot.buy_back_fee_pence,
      'player_status',membership.player_status,'payment_status',membership.payment_status,
      'buy_back_status',case when membership.buy_back_status='available' and membership.player_status='eliminated'
        and buyback.deadline is not null and now()>=buyback.deadline then 'expired' else membership.buy_back_status end,
      'buy_back_deadline',buyback.deadline,
      'gameweeks',coalesce((select jsonb_agg(gameweek.gameweek_number order by gameweek.gameweek_number)
        from public.pot_gameweeks gameweek where gameweek.pot_id=pot.id),'[]'::jsonb)
    ) order by pot.created_at desc)
    from public.pot_players membership join public.pots pot on pot.id=membership.pot_id
    left join lateral (
      select min(fixture.kickoff_at) as deadline from public.football_fixtures fixture
      where fixture.season=pot.season and fixture.gameweek_number=(
        select min(gameweek.gameweek_number) from public.pot_gameweeks gameweek
        where gameweek.pot_id=pot.id and gameweek.gameweek_number>(
          select coalesce(max(pick.gameweek_number),0) from public.player_picks pick
          where pick.pot_id=pot.id and pick.player_id=membership.player_id and pick.outcome='lost'))
    ) buyback on true
    where membership.player_id=(select auth.uid()) and profile.approved),'[]'::jsonb)
  ) from public.profiles profile where profile.id=(select auth.uid());
$$;
revoke all on function public.get_my_dashboard() from public;
grant execute on function public.get_my_dashboard() to authenticated;
