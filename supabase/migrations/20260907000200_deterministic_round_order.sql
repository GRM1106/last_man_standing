-- Critical #2: deterministic creation. Existing round identities are never rewritten.
begin;
CREATE OR REPLACE FUNCTION public.create_pot(pot_name text, pot_season text, entry_fee_pence integer, buy_back_fee_pence integer, gameweek_numbers integer[], player_ids uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare new_pot_id uuid;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if nullif(trim(pot_name),'') is null then raise exception 'Enter a pot name'; end if;
  if nullif(trim(pot_season),'') is null then raise exception 'Enter a season'; end if;
  if coalesce(array_length(gameweek_numbers,1),0)=0 then raise exception 'Select at least one gameweek'; end if;
  if coalesce(array_length(player_ids,1),0)=0 then raise exception 'Assign at least one player'; end if;
  if exists(select 1 from unnest(gameweek_numbers) gw where gw not between 1 and 38) then raise exception 'Gameweeks must be between 1 and 38'; end if;
  if exists(select 1 from unnest(player_ids) player_id where not exists(select 1 from public.profiles where id=player_id)) then
    raise exception 'Every assigned player must have a registered profile';
  end if;
  insert into public.pots(name,season,entry_fee_pence,buy_back_fee_pence,created_by,lifecycle_status)
  values(trim(pot_name),trim(pot_season),entry_fee_pence,buy_back_fee_pence,(select auth.uid()),'setup') returning id into new_pot_id;
  insert into public.pot_gameweeks(pot_id,gameweek_number) select new_pot_id,gw from(select distinct unnest(gameweek_numbers) gw) selected order by gw;
  insert into public.pot_players(pot_id,player_id) select new_pot_id,player_id from(select distinct unnest(player_ids) player_id) selected;
  return new_pot_id;
end; $function$
;
CREATE OR REPLACE FUNCTION public.fill_remaining_pot_gameweeks(selected_pot_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  order by gameweek
  on conflict (pot_id,gameweek_number) do nothing;
end;
$function$
;

-- A statement trigger ranks the whole inserted set, independent of executor row order.
-- Later inserts may only append chronologically; filling an old gap requires a reviewed
-- repair, not an implicit rewrite of existing round/cohort/buy-back history.
drop trigger pot_gameweeks_create_lms_round on public.pot_gameweeks;
create or replace function public.create_lms_round_for_gameweek()
returns trigger language plpgsql security definer set search_path='' as $$
declare target uuid; last_week integer; last_sequence integer;
begin
  for target in select distinct pot_id from inserted_gameweeks order by pot_id loop
    perform pg_advisory_xact_lock(hashtext(target::text),-2);
    if exists (
      select 1 from (
        select r.sequence_number,row_number() over(order by g.gameweek_number) expected
        from public.pot_gameweeks g left join public.pot_rounds r
          on r.pot_id=g.pot_id and r.gameweek_number=g.gameweek_number
        where g.pot_id=target and not exists(select 1 from inserted_gameweeks n
          where n.pot_id=g.pot_id and n.gameweek_number=g.gameweek_number)
      ) mappings where sequence_number is distinct from expected
    ) then raise exception 'Existing round ordering requires a reviewed repair'; end if;
    select max(gameweek_number),coalesce(max(sequence_number),0)
      into last_week,last_sequence from public.pot_rounds where pot_id=target;
    if exists(select 1 from inserted_gameweeks where pot_id=target and gameweek_number<=last_week) then
      raise exception 'Cannot insert an earlier round into an existing schedule; reviewed repair required';
    end if;
    insert into public.pot_rounds(pot_id,sequence_number,gameweek_number,created_at)
    select pot_id,last_sequence+row_number() over(order by gameweek_number),gameweek_number,created_at
      from inserted_gameweeks where pot_id=target order by gameweek_number;
  end loop;
  return null;
end $$;
revoke all on function public.create_lms_round_for_gameweek() from public,anon,authenticated;
create trigger pot_gameweeks_create_lms_round after insert on public.pot_gameweeks
referencing new table as inserted_gameweeks for each statement
execute function public.create_lms_round_for_gameweek();
commit;
