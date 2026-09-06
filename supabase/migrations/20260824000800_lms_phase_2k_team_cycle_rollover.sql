-- Phase 2K: reset a player's team pool once their cycle is exhausted.
--
-- Defect (Wave 4, W-1). Phase 2C built the whole per-player cycle model but only ever
-- created cycle 1: create_initial_team_cycle inserts a hardcoded cycle_number=1 from an
-- after-insert trigger on pot_players, and no function anywhere inserted a later cycle or
-- wrote closed_at. current_team_cycle_id could read closed_at, but nothing could set it.
-- Once a player had used every team in the pot's season, the four eligibility filters
-- excluded all of them, manual picks had nothing to choose, assign_random_missing_picks
-- found no candidate, and automation opened a progression_failure review case. The pot
-- became unplayable with no in-domain remedy.
--
-- Rule. Team usage is scoped to a cycle. A cycle closes when every team in the pot's
-- season has been used once within it; the next numbered cycle opens immediately and all
-- teams become eligible again. Prior cycles and their picks are never rewritten.
--
-- Design. Rollover has exactly one owner, ensure_current_team_cycle. Both insert paths
-- into player_picks -- confirm_team_pick (manual) and assign_random_missing_picks
-- (random) -- already pass through the before-insert trigger link_pick_to_team_cycle, so
-- routing that trigger through ensure_current_team_cycle gives both paths the same
-- rollover without duplicating the logic. This is deliberate: the failure to avoid is one
-- where manual picks roll over but random assignment still sees zero eligible teams.
--
-- Rollover is eager. An after-insert trigger calls the same function, so the cycle closes
-- at the moment its final team is consumed rather than lazily on the next pick. Read
-- paths additionally resolve eligibility through active_team_cycle_id, which reports no
-- active cycle while the open one is exhausted, so every team reads as available even if
-- a row were ever inserted outside these triggers.
--
-- Concurrency. Phase 2C already declared the hard guarantees this relies on:
-- unique(pot_id,player_id,cycle_number) and the partial unique index
-- pot_player_team_cycles_one_active on (pot_id,player_id) where closed_at is null. At most
-- one cycle can be open per player per pot, and a cycle number cannot repeat. On top of
-- those, ensure_current_team_cycle takes a transaction-scoped advisory lock keyed on the
-- pot and player and re-reads the open cycle FOR UPDATE before deciding, so concurrent
-- callers serialise rather than racing. If a racer somehow got past both, the unique index
-- raises and the transaction fails closed -- it is never swallowed.

begin;

do $$
begin
  if to_regclass('public.pot_player_team_cycles') is null then
    raise exception 'Phase 2K team-cycle rollover requires Phase 2C';
  end if;
  if to_regclass('public.football_teams') is null then
    raise exception 'Phase 2K team-cycle rollover requires the football dataset';
  end if;
end $$;

-- The eligible-team universe for a pot. This mirrors the team set that
-- get_my_team_availability already reports on -- teams appearing in a fixture of the pot's
-- season -- so exhaustion is measured against exactly the teams a player could have
-- picked, not against a hardcoded 20.
create or replace function public.pot_eligible_team_count(selected_pot_id uuid)
returns integer language sql stable security definer set search_path='' as $$
 select count(*)::integer from public.football_teams team
 where exists(
   select 1 from public.football_fixtures fixture
   join public.pots pot on pot.id=selected_pot_id and pot.season=fixture.season
   where team.id in (fixture.home_team_id,fixture.away_team_id));
$$;
revoke all on function public.pot_eligible_team_count(uuid) from public,anon,authenticated;

-- A cycle is exhausted when it holds one pick for every eligible team. A pot with no
-- fixtures has a universe of zero and is never treated as exhausted, which keeps an
-- unseeded pot from rolling cycles endlessly.
create or replace function public.team_cycle_is_exhausted(selected_cycle_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select case
   when universe.count_value<=0 then false
   else (select count(distinct pick.team_id) from public.player_picks pick
         where pick.team_cycle_id=cycle.id)>=universe.count_value
 end
 from public.pot_player_team_cycles cycle
 cross join lateral (select public.pot_eligible_team_count(cycle.pot_id) as count_value) universe
 where cycle.id=selected_cycle_id;
$$;
revoke all on function public.team_cycle_is_exhausted(uuid) from public,anon,authenticated;

-- Read-only eligibility view of the cycle: the open cycle unless it is exhausted, in which
-- case there is no cycle to exclude teams against and every team reads as available. The
-- eligibility filters compare used.team_cycle_id against this, so a null result excludes
-- nothing. Stable, and never writes -- the read paths stay read-only.
create or replace function public.active_team_cycle_id(selected_pot_id uuid,selected_player_id uuid)
returns uuid language sql stable security definer set search_path='' as $$
 select cycle.id from public.pot_player_team_cycles cycle
 where cycle.pot_id=selected_pot_id and cycle.player_id=selected_player_id and cycle.closed_at is null
   and not public.team_cycle_is_exhausted(cycle.id);
$$;
revoke all on function public.active_team_cycle_id(uuid,uuid) from public,anon,authenticated;

-- The single owner of rollover. Returns a usable open cycle for the player, closing an
-- exhausted one and opening the next first. Idempotent: with a non-exhausted cycle it
-- simply returns it, so repeated calls never produce an extra cycle.
create or replace function public.ensure_current_team_cycle(selected_pot_id uuid,selected_player_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' as $$
declare open_cycle record; next_cycle_id uuid;
begin
 -- Serialise rollover decisions for this player and pot. Transaction scoped, so the
 -- before-insert and after-insert triggers of one pick share it without contending.
 perform pg_advisory_xact_lock(hashtext('lms_team_cycle:'||selected_pot_id::text||':'||selected_player_id::text));

 select id,cycle_number into open_cycle from public.pot_player_team_cycles
 where pot_id=selected_pot_id and player_id=selected_player_id and closed_at is null
 for update;

 if not found then raise exception 'Player has no active team-use cycle'; end if;
 if not public.team_cycle_is_exhausted(open_cycle.id) then return open_cycle.id; end if;

 update public.pot_player_team_cycles set closed_at=now() where id=open_cycle.id;
 insert into public.pot_player_team_cycles(pot_id,player_id,cycle_number,started_at)
 values(selected_pot_id,selected_player_id,open_cycle.cycle_number+1,now())
 returning id into next_cycle_id;
 return next_cycle_id;
end $$;
revoke all on function public.ensure_current_team_cycle(uuid,uuid) from public,anon,authenticated;

-- Stamp the pick with a cycle that has room in it. Replaces the Phase 2C body's
-- current_team_cycle_id call; the 'no active team-use cycle' contract is unchanged, and is
-- now raised from ensure_current_team_cycle.
create or replace function public.link_pick_to_team_cycle() returns trigger language plpgsql security definer set search_path='' as $$
declare active_cycle uuid;
begin
 active_cycle:=public.ensure_current_team_cycle(new.pot_id,new.player_id);
 if new.team_cycle_id is not null and new.team_cycle_id<>active_cycle then raise exception 'Pick team-use cycle is not current for this player and pot'; end if;
 new.team_cycle_id:=active_cycle; return new;
end $$;
revoke all on function public.link_pick_to_team_cycle() from public,anon,authenticated;

-- Close the cycle as soon as its final team is consumed, so the closed/open state is
-- correct the instant exhaustion happens rather than on the next pick.
create or replace function public.roll_team_cycle_after_pick() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform public.ensure_current_team_cycle(new.pot_id,new.player_id);
 return null;
end $$;
revoke all on function public.roll_team_cycle_after_pick() from public,anon,authenticated;

drop trigger if exists player_picks_roll_team_cycle on public.player_picks;
create trigger player_picks_roll_team_cycle after insert on public.player_picks
for each row execute function public.roll_team_cycle_after_pick();

-- Point the four eligibility filters at active_team_cycle_id. Every current_team_cycle_id
-- occurrence in these functions sits inside a `used.team_cycle_id = ...` exclusion filter,
-- so the substitution is total and each function must actually change.
do $$
declare target text; definition text; original text;
begin
  foreach target in array array[
    'public.confirm_team_pick(uuid,bigint,bigint)',
    'public.assign_random_missing_picks(uuid,integer,boolean)',
    'public.get_pot_selection(uuid)',
    'public.get_my_team_availability(uuid)'
  ] loop
    definition:=pg_get_functiondef(target::regprocedure); original:=definition;
    definition:=replace(definition,'public.current_team_cycle_id(','public.active_team_cycle_id(');
    if definition=original then
      raise exception 'Expected % to filter used teams by the current team cycle',target;
    end if;
    if position('public.current_team_cycle_id(' in definition)>0 then
      raise exception 'Unreplaced team-cycle reference remains in %',target;
    end if;
    execute definition;
  end loop;
end $$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'public.pot_eligible_team_count(uuid)',
    'public.team_cycle_is_exhausted(uuid)',
    'public.active_team_cycle_id(uuid,uuid)',
    'public.ensure_current_team_cycle(uuid,uuid)'
  ] loop
    if has_function_privilege('authenticated',fn,'execute') or has_function_privilege('anon',fn,'execute') then
      raise exception 'Team-cycle helper % must not be directly executable',fn;
    end if;
  end loop;

  if not exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('pot_eligible_team_count','team_cycle_is_exhausted','active_team_cycle_id',
                        'ensure_current_team_cycle','link_pick_to_team_cycle','roll_team_cycle_after_pick')
      and p.prosecdef and array_to_string(p.proconfig,',') like 'search_path=%'
    having count(*)=6
  ) then
    raise exception 'Team-cycle rollover functions must keep SECURITY DEFINER and an empty search_path';
  end if;

  if not exists(select 1 from pg_trigger where tgname='player_picks_roll_team_cycle' and not tgisinternal) then
    raise exception 'Team-cycle rollover trigger is missing';
  end if;

  -- Phase 2C's guarantees are what make the rollover safe under concurrency.
  if not exists(select 1 from pg_indexes where schemaname='public' and indexname='pot_player_team_cycles_one_active') then
    raise exception 'Team-cycle rollover requires the single-open-cycle unique index';
  end if;
  if not exists(
    select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid
    where t.relname='pot_player_team_cycles' and c.contype='u'
      and pg_get_constraintdef(c.oid) like '%cycle_number%'
  ) then
    raise exception 'Team-cycle rollover requires the unique cycle number constraint';
  end if;
end $$;

commit;
