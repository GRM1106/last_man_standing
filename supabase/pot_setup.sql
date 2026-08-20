-- 06 — Pot and payment setup
-- Run once in the Supabase SQL Editor after admin_setup.sql.

create table if not exists public.pots (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 80),
  season text not null check (char_length(trim(season)) between 1 and 20),
  entry_fee_pence integer not null default 1000 check (entry_fee_pence >= 0),
  buy_back_fee_pence integer not null default 1000 check (buy_back_fee_pence >= 0),
  status text not null default 'draft' check (status in ('draft','open','active','complete')),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.pot_gameweeks (
  pot_id uuid not null references public.pots(id) on delete cascade,
  gameweek_number integer not null check (gameweek_number between 1 and 38),
  created_at timestamptz not null default now(),
  primary key (pot_id,gameweek_number)
);

create table if not exists public.pot_players (
  pot_id uuid not null references public.pots(id) on delete cascade,
  player_id uuid not null references public.profiles(id) on delete cascade,
  player_status text not null default 'active' check (player_status in ('active','eliminated','winner','withdrawn')),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','claimed','paid')),
  buy_back_status text not null default 'available' check (buy_back_status in ('available','claimed','used','expired')),
  joined_at timestamptz not null default now(),
  primary key (pot_id,player_id)
);

alter table public.pots enable row level security;
alter table public.pot_gameweeks enable row level security;
alter table public.pot_players enable row level security;

grant select on table public.pots, public.pot_gameweeks, public.pot_players to authenticated;

drop policy if exists "Admins can view all pots" on public.pots;
create policy "Admins can view all pots" on public.pots for select to authenticated
using ((select public.is_current_user_admin()));

drop policy if exists "Players can view assigned pots" on public.pots;
create policy "Players can view assigned pots" on public.pots for select to authenticated
using (exists (
  select 1 from public.pot_players pp
  where pp.pot_id = pots.id and pp.player_id = (select auth.uid())
));

drop policy if exists "Admins can view all pot gameweeks" on public.pot_gameweeks;
create policy "Admins can view all pot gameweeks" on public.pot_gameweeks for select to authenticated
using ((select public.is_current_user_admin()));

drop policy if exists "Players can view assigned pot gameweeks" on public.pot_gameweeks;
create policy "Players can view assigned pot gameweeks" on public.pot_gameweeks for select to authenticated
using (exists (
  select 1 from public.pot_players pp
  where pp.pot_id = pot_gameweeks.pot_id and pp.player_id = (select auth.uid())
));

drop policy if exists "Admins can view all pot players" on public.pot_players;
create policy "Admins can view all pot players" on public.pot_players for select to authenticated
using ((select public.is_current_user_admin()));

drop policy if exists "Players can view their pot membership" on public.pot_players;
create policy "Players can view their pot membership" on public.pot_players for select to authenticated
using (player_id = (select auth.uid()));

create or replace function public.create_pot(
  pot_name text,
  pot_season text,
  entry_fee_pence integer,
  buy_back_fee_pence integer,
  gameweek_numbers integer[],
  player_ids uuid[]
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare new_pot_id uuid;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if nullif(trim(pot_name),'') is null then raise exception 'Enter a pot name'; end if;
  if nullif(trim(pot_season),'') is null then raise exception 'Enter a season'; end if;
  if coalesce(array_length(gameweek_numbers,1),0) = 0 then raise exception 'Select at least one gameweek'; end if;
  if coalesce(array_length(player_ids,1),0) = 0 then raise exception 'Assign at least one player'; end if;
  if exists (select 1 from unnest(gameweek_numbers) gw where gw not between 1 and 38) then raise exception 'Gameweeks must be between 1 and 38'; end if;
  if exists (
    select 1 from unnest(player_ids) player_id
    where not exists (select 1 from public.profiles p where p.id = player_id and p.approved)
  ) then raise exception 'Only approved players can be assigned'; end if;

  insert into public.pots (name,season,entry_fee_pence,buy_back_fee_pence,created_by)
  values (trim(pot_name),trim(pot_season),entry_fee_pence,buy_back_fee_pence,(select auth.uid()))
  returning id into new_pot_id;

  insert into public.pot_gameweeks (pot_id,gameweek_number)
  select new_pot_id,gw from (select distinct unnest(gameweek_numbers) as gw) selected;

  insert into public.pot_players (pot_id,player_id)
  select new_pot_id,player_id from (select distinct unnest(player_ids) as player_id) selected;

  return new_pot_id;
end;
$$;
revoke all on function public.create_pot(text,text,integer,integer,integer[],uuid[]) from public;
grant execute on function public.create_pot(text,text,integer,integer,integer[],uuid[]) to authenticated;

create or replace function public.set_pot_player_payment(
  selected_pot_id uuid,
  selected_player_id uuid,
  new_payment_status text
)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if new_payment_status not in ('unpaid','claimed','paid') then raise exception 'Invalid payment status'; end if;
  update public.pot_players set payment_status = new_payment_status
  where pot_id = selected_pot_id and player_id = selected_player_id;
  if not found then raise exception 'Pot player not found'; end if;
end;
$$;
revoke all on function public.set_pot_player_payment(uuid,uuid,text) from public;
grant execute on function public.set_pot_player_payment(uuid,uuid,text) to authenticated;
