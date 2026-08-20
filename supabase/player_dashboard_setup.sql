-- 07 — Player dashboard access and payment claim
-- Run once in the Supabase SQL Editor after pot_setup.sql.

create or replace function public.get_my_dashboard()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'approved',coalesce(profile.approved,false),
    'first_name',profile.first_name,
    'pots',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',pot.id,
          'name',pot.name,
          'season',pot.season,
          'status',pot.status,
          'entry_fee_pence',pot.entry_fee_pence,
          'buy_back_fee_pence',pot.buy_back_fee_pence,
          'player_status',membership.player_status,
          'payment_status',membership.payment_status,
          'buy_back_status',membership.buy_back_status,
          'gameweeks',coalesce((
            select jsonb_agg(gameweek.gameweek_number order by gameweek.gameweek_number)
            from public.pot_gameweeks gameweek
            where gameweek.pot_id = pot.id
          ),'[]'::jsonb)
        ) order by pot.created_at desc
      )
      from public.pot_players membership
      join public.pots pot on pot.id = membership.pot_id
      where membership.player_id = (select auth.uid())
        and profile.approved
    ),'[]'::jsonb)
  )
  from public.profiles profile
  where profile.id = (select auth.uid());
$$;
revoke all on function public.get_my_dashboard() from public;
grant execute on function public.get_my_dashboard() to authenticated;

create or replace function public.claim_pot_payment(selected_pot_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.pot_players
  set payment_status = 'claimed'
  where pot_id = selected_pot_id
    and player_id = (select auth.uid())
    and payment_status = 'unpaid';

  if not found then
    if not exists (
      select 1 from public.pot_players
      where pot_id = selected_pot_id and player_id = (select auth.uid())
    ) then raise exception 'You are not assigned to this pot';
    end if;
  end if;
end;
$$;
revoke all on function public.claim_pot_payment(uuid) from public;
grant execute on function public.claim_pot_payment(uuid) to authenticated;
