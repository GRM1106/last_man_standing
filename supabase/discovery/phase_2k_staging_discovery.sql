-- ============================================================================
-- Phase 2K — STAGING READ-ONLY DISCOVERY
--
-- Intended target: staging only (documented reference evhiixndiuwwodsouyhf).
-- Confirm the connected project before running. Do not run against production.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE IS NOT IN supabase/verification/
-- ---------------------------------------------------------------------------
-- The verification suite is mutating and local-only by purpose: its executable
-- files are used only against disposable databases. (Their headers vary — some
-- say "Disposable local database only", one says "Never run remotely", and
-- several carry no safety header at all — so rely on that stated purpose
-- rather than on any individual file's wording.)
--
-- This file is the opposite: it is read-only and is the ONLY SQL in this
-- repository intended to be run against a live remote project. It is kept in a
-- separate directory so that distinction stays unambiguous. Do not move it.
--
-- ---------------------------------------------------------------------------
-- SAFETY PROPERTIES
-- ---------------------------------------------------------------------------
--   * No DDL, no DML, no temp tables, no function creation, no set_config.
--   * Reads catalogue/metadata plus row counts only.
--   * Each section runs inside an explicit read-only transaction, so the
--     server itself would abort any write that somehow appeared here.
--
-- This file does NOT pass the backup/restore operator gate and does NOT
-- authorize migrations, Edge Function deployment, secrets, or cron. It only
-- answers: "what is actually on staging right now?"
--
-- ---------------------------------------------------------------------------
-- HOW TO RUN
-- ---------------------------------------------------------------------------
-- Run QUERY 1, QUERY 2 and QUERY 3 SEPARATELY. The Supabase SQL Editor
-- displays only the LAST result set, so running the whole file at once will
-- silently discard the earlier sections.
--
-- If the editor reports "there is already a transaction in progress" on
-- 'begin', that is a warning, not a failure. The editor already opened its own
-- transaction. You may either ignore it or drop the begin/set/commit lines and
-- run the bare SELECT — the statements contain no writes either way.
--
-- Review output before sharing: section 3 lists function signatures, sections
-- 6 and 6b list role grants, and section 4 prints full policy expressions.
-- ============================================================================


-- ============================================================================
-- QUERY 1 — phase presence + object inventory        (run this on its own)
--
-- Section 1 is the decisive one. Every LMS migration guards itself with a
-- unique sentinel object and raises '<phase> already installed' if present.
--
-- INTERPRETING SENTINELS: a present sentinel is strong evidence that its
-- migration was applied, but it is not proof on its own — manual drift can
-- create a sentinel object independently of the migration that owns it.
-- Sentinel state must be cross-checked against QUERY 2 (migration history)
-- and against the rest of this inventory. Any disagreement between them
-- STOPS the process and is reported; it is not reconciled by assumption.
--
-- Expected chain, strictly linear:
--   P1/P2 -> Phase 1 -> 2A -> 2B -> 2C -> 2D -> 2E -> 2F -> 2G -> 2H -> 2I -> 2J
-- ============================================================================
begin;
set transaction read only;

with sentinel(ord, item, kind, ident) as (values
  ( 10,'P1/P2 baseline  · fixture_result_overrides',        'table','public.fixture_result_overrides'),
  ( 11,'P1/P2 baseline  · get_effective_fixture_result',    'proc' ,'public.get_effective_fixture_result(bigint)'),
  ( 12,'P1/P2 baseline  · create_fixture_result_override',  'proc' ,'public.create_fixture_result_override(bigint,integer,integer,text,text,text)'),
  ( 20,'Phase 1         · current_pot_gameweek',            'proc' ,'public.current_pot_gameweek(uuid)'),
  ( 21,'Phase 1         · sync_fpl_data_p2_base',           'proc' ,'public.sync_fpl_data_p2_base(text,jsonb,jsonb)'),
  ( 22,'Phase 1         · process_pot_gameweek_p2_base',    'proc' ,'public.process_pot_gameweek_p2_base(uuid,integer,boolean)'),
  ( 30,'Phase 2A        · lock_pot_membership_if_due',      'proc' ,'public.lock_pot_membership_if_due(uuid)'),
  ( 40,'Phase 2B        · pot_rounds',                      'table','public.pot_rounds'),
  ( 41,'Phase 2B        · pot_round_players',               'table','public.pot_round_players'),
  ( 50,'Phase 2C        · pot_player_team_cycles',          'table','public.pot_player_team_cycles'),
  ( 60,'Phase 2D        · fixture_selection_block_events',  'table','public.fixture_selection_block_events'),
  ( 70,'Phase 2E        · round_collective_reinstatements', 'table','public.round_collective_reinstatements'),
  ( 80,'Phase 2F        · pot_player_buyback_events',       'table','public.pot_player_buyback_events'),
  ( 90,'Phase 2G        · pot_completions',                 'table','public.pot_completions'),
  (100,'Phase 2H        · lms_review_cases',                'table','public.lms_review_cases'),
  (110,'Phase 2I        · lms_automation_runs',             'table','public.lms_automation_runs'),
  (120,'Phase 2J        · lms_provider_runs',               'table','public.lms_provider_runs'),
  (121,'Phase 2J        · lms_operations_config',           'table','public.lms_operations_config'),
  (122,'Phase 2J        · lms_provider_state',              'table','public.lms_provider_state')
)

-- 1. Which phases appear installed (corroborate against QUERY 2)
select ord::int                  as ord,
       '1. PHASE PRESENCE'::text as section,
       item::text                as item,
       (case when kind = 'table'
             then case when to_regclass(ident)     is null then 'ABSENT' else 'present' end
             else case when to_regprocedure(ident) is null then 'ABSENT' else 'present' end
        end)::text               as detail
from sentinel

union all
-- 1b. Phase 1 also adds a column; confirm independently of the function
select 23, '1. PHASE PRESENCE'::text,
       'Phase 1         · pot_gameweeks.pick_deadline_at column'::text,
       (case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'pot_gameweeks'
                            and column_name = 'pick_deadline_at')
             then 'present' else 'ABSENT' end)::text

union all
-- 1c. Phase 2A also adds a column; confirm independently of the function
select 31, '1. PHASE PRESENCE'::text,
       'Phase 2A        · pots.lifecycle_status column'::text,
       (case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'pots'
                            and column_name = 'lifecycle_status')
             then 'present' else 'ABSENT' end)::text

union all
-- 2. Base tables in public, with RLS posture and planner row estimate.
--    'unanalyzed' means reltuples = -1 (never analyzed) — NOT an empty table.
--    Use QUERY 3 for exact counts.
select 200, '2. TABLES + RLS'::text,
       c.relname::text,
       ((case when c.relrowsecurity then 'RLS on' else 'RLS OFF' end)
        || (case when c.relforcerowsecurity then ' (forced)' else '' end)
        || ' · policies=' || (select count(*) from pg_policy p where p.polrelid = c.oid)::text
        || ' · ~rows='
        || (case when c.reltuples < 0 then 'unanalyzed'
                 else c.reltuples::bigint::text end))::text
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'

union all
-- 3. Functions with exact identity signatures (catches overload drift)
select 300, '3. FUNCTIONS'::text,
       p.proname::text,
       (coalesce(pg_get_function_identity_arguments(p.oid), '')
        || ' -> ' || coalesce(pg_get_function_result(p.oid), '(aggregate/window)')
        || (case p.prosecdef when true then ' · SECURITY DEFINER' else ' · invoker' end))::text
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'

union all
-- 4. Row-level security policies, INCLUDING the actual expressions.
--    Roles and commands alone cannot reveal an unsafe policy — the USING and
--    WITH CHECK expressions are what determine whether a row is reachable.
--    polroles containing 0 means PUBLIC.
select 400, '4. POLICIES'::text,
       (c.relname::text || ' :: ' || p.polname::text)::text,
       ('cmd=' || (case p.polcmd
                     when 'r' then 'SELECT' when 'a' then 'INSERT'
                     when 'w' then 'UPDATE' when 'd' then 'DELETE'
                     when '*' then 'ALL'    else p.polcmd::text end)
        || ' · permissive=' || (case when p.polpermissive then 'yes' else 'no (RESTRICTIVE)' end)
        || ' · roles=' || coalesce((select string_agg(r.rolname::text, ',' order by r.rolname::text)
                                    from pg_roles r where r.oid = any(p.polroles)), 'PUBLIC')
        || ' · USING=' || coalesce(pg_get_expr(p.polqual, p.polrelid), '(none)')
        || ' · WITH CHECK=' || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '(none)'))::text
from pg_policy p
join pg_class c on c.oid = p.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'

union all
-- 5. Triggers, excluding FK-enforcement internals
select 500, '5. TRIGGERS'::text,
       (c.relname::text || ' :: ' || t.tgname::text)::text,
       (case when t.tgenabled = 'D' then 'DISABLED' else 'enabled' end)::text
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and not t.tgisinternal

union all
-- 6. Table grants to client-facing roles — the RLS-bypass risk surface
select 600, '6. TABLE GRANTS'::text,
       (g.table_name::text || ' -> ' || g.grantee::text)::text,
       string_agg(g.privilege_type::text, ',' order by g.privilege_type::text)::text
from information_schema.role_table_grants g
where g.table_schema = 'public' and g.grantee::text in ('anon','authenticated')
group by g.table_name, g.grantee

union all
-- 6b. ROUTINE grants — internal RPC exposure.
--     PostgREST will expose any public-schema function the requesting role may
--     EXECUTE. PUBLIC is included deliberately: Postgres grants EXECUTE to
--     PUBLIC by default, so a function exposed that way is callable by anon
--     and authenticated while being invisible to an anon/authenticated-only
--     audit. The LMS migrations revoke from public,anon,authenticated — any
--     row here for an internal routine is a finding.
--     specific_name is included so overloads remain distinguishable.
select 650, '6b. ROUTINE GRANTS'::text,
       (rp.routine_name::text || ' [' || rp.specific_name::text || '] -> ' || rp.grantee::text)::text,
       string_agg(rp.privilege_type::text, ',' order by rp.privilege_type::text)::text
from information_schema.routine_privileges rp
where rp.routine_schema = 'public'
  and rp.grantee::text in ('anon','authenticated','PUBLIC')
group by rp.routine_name, rp.specific_name, rp.grantee

union all
-- 7. Installed extensions
select 700, '7. EXTENSIONS'::text, e.extname::text, e.extversion::text
from pg_extension e

union all
-- 8. Scheduler-relevant: is pg_cron present at all?
select 800, '8. CRON'::text, 'pg_cron extension'::text,
       (case when exists (select 1 from pg_extension where extname = 'pg_cron')
             then 'INSTALLED — then also run: select jobid, schedule, jobname, active from cron.job;'
             else 'not installed' end)::text

order by 1, 3;

commit;


-- ============================================================================
-- QUERY 2 — applied migration history                (run separately)
--
-- to_jsonb(m) returns whatever columns this project's migration runner
-- actually has. Column names vary by Supabase migration-runner version, so
-- selecting named columns other than 'version' risks a spurious failure.
--
-- IF THIS ERRORS: record the error text VERBATIM and stop interpreting it.
-- An error may mean the relation is missing, the current role lacks
-- permission on supabase_migrations, or the runner's schema version differs
-- from what this query expects. It does NOT by itself establish that the
-- migration runner was bypassed. The distinction changes the catch-up plan,
-- so it must be determined, not assumed.
-- ============================================================================
begin;
set transaction read only;

select to_jsonb(m) as migration_record
from supabase_migrations.schema_migrations m
order by m.version;

commit;


-- ============================================================================
-- QUERY 3 — exact row counts for core tables         (run separately)
--
-- Input to the BACKUP / RESTORE decision: how much real data is at risk.
-- These tables all predate Phase 1, so they should exist on any staging
-- project at the P1/P2 baseline or later. If this errors naming a table,
-- that table is absent — which is itself a material finding. Report it.
-- ============================================================================
begin;
set transaction read only;

select 'profiles'                 as table_name, count(*) as exact_rows from public.profiles
union all select 'pots',                  count(*) from public.pots
union all select 'pot_players',           count(*) from public.pot_players
union all select 'pot_gameweeks',         count(*) from public.pot_gameweeks
union all select 'player_picks',          count(*) from public.player_picks
union all select 'football_teams',        count(*) from public.football_teams
union all select 'football_fixtures',     count(*) from public.football_fixtures
union all select 'fixture_result_overrides', count(*) from public.fixture_result_overrides
order by 1;

commit;
