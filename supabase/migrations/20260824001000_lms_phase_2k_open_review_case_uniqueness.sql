-- Phase 2K: let a pot be corrected more than twice for the same governed issue.
--
-- Defect. Phase 2H gave lms_review_cases
--
--   unique nulls not distinct(pot_id,case_type,fixture_id,player_id,status)
--
-- to power the idempotent upsert in open_lms_review_case, whose conflict target names the
-- same five columns. The deduplication that upsert needs is "at most one OPEN case per
-- target shape" -- it only ever inserts rows with the default status 'open'. Putting
-- `status` inside a full unique constraint additionally constrained the terminal rows the
-- upsert never touches, so each shape got exactly one 'resolved' slot and one 'dismissed'
-- slot for the whole life of the pot:
--
--   open   shape X, resolve it            -> ok
--   open   shape X again                  -> ok, the open slot is free again
--   resolve shape X again                 -> 23505, a resolved X already exists
--   dismiss it instead                    -> ok, the dismissed slot was free
--   open   shape X a third time           -> ok
--   resolve or dismiss it                 -> 23505 both ways
--
-- The third case of a shape can therefore be opened but can never leave 'open'. Because
-- resolve_lms_review_case keeps a pot in lifecycle_status='review' while any case is open,
-- that pot is stuck in review permanently with no in-domain remedy.
--
-- Fix. The uniqueness moves to a partial unique index over the target shape alone,
-- restricted to open rows. NULLS NOT DISTINCT is retained so pot-level cases -- the ones
-- with a null fixture_id and player_id -- still collide with each other and merge, which
-- is exactly what Phase 2H intended and what PostgreSQL's default NULLS DISTINCT would
-- not do. PostgreSQL 15+ supports NULLS NOT DISTINCT on a partial unique index directly,
-- so no COALESCE sentinel values are needed and none are used.
--
-- open_lms_review_case's conflict target moves with it. Inferring a partial index requires
-- the caller to restate the index predicate, so the ON CONFLICT clause carries
-- `where status='open'`. Nothing else about the function changes: same signature, same
-- hardening, same evidence merge, same impact_snapshot overwrite, same version increment,
-- same opened_at/opened_by semantics, same pot lifecycle update.
--
-- Existing data is safe by construction. The new index is implied by the constraint it
-- replaces: every open row was already unique on these four columns, because the old key
-- included status and all open rows share the same status value. Nothing is deleted,
-- merged or rewritten -- terminal rows simply stop being constrained.

begin;

do $$
begin
  if to_regclass('public.lms_review_cases') is null then
    raise exception 'Phase 2K review-case uniqueness requires Phase 2H';
  end if;
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.lms_review_cases'::regclass
      and conname='lms_review_cases_pot_id_case_type_fixture_id_player_id_stat_key'
  ) then
    raise exception 'The Phase 2H review-case uniqueness constraint is missing; refusing to guess the baseline';
  end if;
  -- Belt and braces: the replacement can only fail if two open rows already share a shape,
  -- which the constraint being dropped made impossible. Prove it rather than assume it.
  if exists(
    select 1 from public.lms_review_cases where status='open'
    group by pot_id,case_type,fixture_id,player_id having count(*)>1
  ) then
    raise exception 'Existing data already violates the open-case invariant; resolve the duplicates first';
  end if;
end $$;

alter table public.lms_review_cases
  drop constraint lms_review_cases_pot_id_case_type_fixture_id_player_id_stat_key;

-- At most one OPEN case per (pot, case_type, fixture, player); any number of historical
-- resolved or dismissed cases of the same shape.
create unique index lms_review_cases_one_open_per_target
  on public.lms_review_cases (pot_id, case_type, fixture_id, player_id)
  nulls not distinct
  where status = 'open';

-- Identical to the Phase 2H function except for the ON CONFLICT target, which now names
-- the open-only index and restates its predicate so PostgreSQL can infer it.
create or replace function public.open_lms_review_case(selected_pot_id uuid,selected_case_type text,selected_summary text,selected_round_id uuid default null,selected_fixture_id bigint default null,selected_pick_id bigint default null,selected_player_id uuid default null,selected_evidence jsonb default '{}',selected_source text default 'system') returns uuid language plpgsql security definer set search_path='' as $$
declare created_id uuid;impact jsonb;
begin
 if selected_source='admin' and not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 select jsonb_build_object('later_rounds',(select count(*) from public.pot_rounds r where r.pot_id=selected_pot_id and (selected_round_id is null or r.sequence_number>(select sequence_number from public.pot_rounds where id=selected_round_id))),'later_picks',(select count(*) from public.player_picks p where p.pot_id=selected_pot_id and (selected_round_id is null or p.gameweek_number>(select gameweek_number from public.pot_rounds where id=selected_round_id))),'completed',exists(select 1 from public.pot_completions where pot_id=selected_pot_id)) into impact;
 insert into public.lms_review_cases(pot_id,source_round_id,fixture_id,pick_id,player_id,case_type,summary,evidence,impact_snapshot,opened_by,opened_source)
 values(selected_pot_id,selected_round_id,selected_fixture_id,selected_pick_id,selected_player_id,selected_case_type,trim(selected_summary),selected_evidence,impact,case when selected_source='system' then null else (select auth.uid()) end,selected_source)
 on conflict(pot_id,case_type,fixture_id,player_id) where status='open' do update set evidence=lms_review_cases.evidence||excluded.evidence,impact_snapshot=excluded.impact_snapshot,version=lms_review_cases.version+1 returning id into created_id;
 perform set_config('lms.review_case_opening','1',true);
 update public.pots set lifecycle_status='review',review_status='needs_review',review_reason=trim(selected_summary),review_status_changed_at=now() where id=selected_pot_id;
 perform set_config('lms.review_case_opening','0',true);
 return created_id;
end $$;
revoke all on function public.open_lms_review_case(uuid,text,text,uuid,bigint,bigint,uuid,jsonb,text) from public,anon,authenticated;

do $$
declare index_definition text;
begin
  if exists(
    select 1 from pg_constraint
    where conrelid='public.lms_review_cases'::regclass
      and conname='lms_review_cases_pot_id_case_type_fixture_id_player_id_stat_key'
  ) then
    raise exception 'The status-bearing review-case constraint is still present';
  end if;

  select indexdef into index_definition from pg_indexes
  where schemaname='public' and indexname='lms_review_cases_one_open_per_target';
  if index_definition is null then
    raise exception 'The open-only review-case index is missing';
  end if;
  if index_definition not like '%NULLS NOT DISTINCT%' then
    raise exception 'The open-only review-case index must treat null targets as equal';
  end if;
  if index_definition not like '%WHERE (status = ''open''::text)%' then
    raise exception 'The open-only review-case index must be restricted to open cases';
  end if;
  if index_definition like '%status,%' or index_definition like '%, status)%' then
    raise exception 'Status must not be part of the review-case uniqueness key';
  end if;

  if not exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='open_lms_review_case'
      and p.prosecdef and array_to_string(p.proconfig,',') like 'search_path=%'
  ) then
    raise exception 'open_lms_review_case must keep SECURITY DEFINER and an empty search_path';
  end if;
  if has_function_privilege('authenticated','public.open_lms_review_case(uuid,text,text,uuid,bigint,bigint,uuid,jsonb,text)','execute')
    or has_function_privilege('anon','public.open_lms_review_case(uuid,text,text,uuid,bigint,bigint,uuid,jsonb,text)','execute') then
    raise exception 'open_lms_review_case must remain internal';
  end if;
end $$;

commit;
