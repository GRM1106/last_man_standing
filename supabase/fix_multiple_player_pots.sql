-- 10 — Fix multiple pots on player dashboard
-- Run once in the Supabase SQL Editor after player_dashboard_setup.sql.

create or replace function public.get_my_dashboard()
returns jsonb language sql stable security definer set search_path = '' as $$
  with current_player as (
    select id,email,first_name,approved
    from public.profiles
    where id = (select auth.uid())
  ),
  assigned_pots as (
    select
      pot.id,
      pot.name,
      pot.season,
      pot.status,
      pot.entry_fee_pence,
      pot.buy_back_fee_pence,
      membership.player_status,
      membership.payment_status,
      membership.buy_back_status,
      coalesce((
        select jsonb_agg(gameweek.gameweek_number order by gameweek.gameweek_number)
        from public.pot_gameweeks gameweek
        where gameweek.pot_id = pot.id
      ),'[]'::jsonb) as gameweeks,
      pot.created_at
    from public.pot_players membership
    join public.pots pot on pot.id = membership.pot_id
    join current_player player on player.id = membership.player_id
    where player.approved
  )
  select jsonb_build_object(
    'approved',coalesce(player.approved,false),
    'email',player.email,
    'first_name',player.first_name,
    'pots',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',pot.id,
          'name',pot.name,
          'season',pot.season,
          'status',pot.status,
          'entry_fee_pence',pot.entry_fee_pence,
          'buy_back_fee_pence',pot.buy_back_fee_pence,
          'player_status',pot.player_status,
          'payment_status',pot.payment_status,
          'buy_back_status',pot.buy_back_status,
          'gameweeks',pot.gameweeks
        ) order by pot.created_at desc
      )
      from assigned_pots pot
    ),'[]'::jsonb)
  )
  from current_player player;
$$;
revoke all on function public.get_my_dashboard() from public;
grant execute on function public.get_my_dashboard() to authenticated;
