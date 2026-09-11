-- 08 — Automatic remaining gameweeks
-- Run once in the Supabase SQL Editor after pot_setup.sql.

create or replace function public.fill_remaining_pot_gameweeks(selected_pot_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare first_gameweek integer;
begin
  if not (select public.is_current_user_admin()) then
    raise exception 'Administrator access required';
  end if;

  if not exists (select 1 from public.pots where id = selected_pot_id) then
    raise exception 'Pot not found';
  end if;

  select min(gameweek_number) into first_gameweek
  from public.pot_gameweeks
  where pot_id = selected_pot_id;

  if first_gameweek is null then
    raise exception 'The pot does not have a starting gameweek';
  end if;

  insert into public.pot_gameweeks (pot_id,gameweek_number)
  select selected_pot_id,gameweek
  from generate_series(first_gameweek,38) as series(gameweek)
  on conflict (pot_id,gameweek_number) do nothing;
end;
$$;
revoke all on function public.fill_remaining_pot_gameweeks(uuid) from public;
grant execute on function public.fill_remaining_pot_gameweeks(uuid) to authenticated;
