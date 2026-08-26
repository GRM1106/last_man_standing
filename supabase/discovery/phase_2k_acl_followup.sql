-- ============================================================================
-- Phase 2K — ACL FOLLOW-UP, READ-ONLY
--
-- Companion to phase_2k_staging_discovery.sql. Same rules: read-only, staging
-- only, confirm the connected project first, no authorization to mutate.
--
-- PURPOSE
-- Discovery found legacy REFERENCES/TRIGGER/TRUNCATE held by anon and
-- authenticated, with SELECT/INSERT/UPDATE/DELETE apparently already removed.
-- That residue is consistent with "ALL was granted by default, then some
-- privileges were revoked". If that is what happened, the cause may be
-- ALTER DEFAULT PRIVILEGES, which applies to FUTURE tables as well — meaning
-- the Phase 1–2J catch-up chain would recreate the same weakness on every new
-- table it creates, because most of its migrations revoke only
-- insert/update/delete and not TRUNCATE/REFERENCES/TRIGGER.
--
-- QUERY 4 is decisive about the CURRENT future-table posture. Run it first.
--
-- Run each query SEPARATELY; the SQL Editor shows only the last result set.
-- ============================================================================


-- ============================================================================
-- QUERY 4 — default privileges  (DECISIVE — run this first)
--
-- If any row grants privileges on tables ('r') in schema public to anon or
-- authenticated, then tables created by that grantor in public inherit them at
-- CREATE time, and a later "revoke insert,update,delete" will not remove
-- TRUNCATE/REFERENCES/TRIGGER. An empty result proves only that the CURRENT
-- defaults will not recreate the residue. It does not prove whether the legacy
-- grants came from an explicit GRANT or from historical defaults later reset.
-- ============================================================================
begin;
set transaction read only;

select coalesce(d.defaclrole::regrole::text, '(none)')      as grantor_role,
       coalesce(n.nspname, '(all schemas)')                 as schema_name,
       case d.defaclobjtype when 'r' then 'table'
                            when 'f' then 'function'
                            when 'S' then 'sequence'
                            when 'T' then 'type'
                            when 'n' then 'schema'
                            else d.defaclobjtype::text end  as object_type,
       d.defaclacl::text[]                                  as default_acl
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
order by 2, 3, 1;

commit;


-- ============================================================================
-- QUERY 5 — schema-level privileges on public
--
-- TRIGGER privilege only becomes an escalation path if a role can also create
-- functions in the schema. Confirms whether anon/authenticated hold CREATE.
-- ============================================================================
begin;
set transaction read only;

select 'public schema ACL'                                   as item,
       coalesce(n.nspacl::text, '(default)')                 as detail
from pg_namespace n where n.nspname = 'public'
union all
select 'anon has CREATE on public',
       has_schema_privilege('anon','public','CREATE')::text
union all
select 'anon has USAGE on public',
       has_schema_privilege('anon','public','USAGE')::text
union all
select 'authenticated has CREATE on public',
       has_schema_privilege('authenticated','public','CREATE')::text
union all
select 'authenticated has USAGE on public',
       has_schema_privilege('authenticated','public','USAGE')::text
order by 1;

commit;


-- ============================================================================
-- QUERY 6 — every public routine executable by PUBLIC/anon/authenticated,
--           with return type and security mode.
--
-- Return type decides API reachability: PostgREST does not expose functions
-- returning 'trigger' or 'event_trigger', and such functions error if called
-- outside their trigger context. Those are hygiene items. Anything else that
-- is SECURITY DEFINER and executable by anon is a live exposure.
--
-- rls_auto_enable has no source anywhere in this repository's history, so its
-- prosrc is included to identify what it is and where it came from.
-- ============================================================================
begin;
set transaction read only;

select p.proname::text                                         as routine,
       pg_get_function_identity_arguments(p.oid)               as args,
       pg_get_function_result(p.oid)                           as returns,
       case p.prosecdef when true then 'DEFINER' else 'INVOKER' end as security,
       case when has_function_privilege('anon',          p.oid, 'EXECUTE') then 'anon ' else '' end
       || case when has_function_privilege('authenticated', p.oid, 'EXECUTE') then 'authenticated ' else '' end
                                                               as effective_execute,
       coalesce((select string_agg(
                  case when a.grantee=0 then 'PUBLIC' else a.grantee::regrole::text end,
                  ',' order by case when a.grantee=0 then 'PUBLIC' else a.grantee::regrole::text end)
                 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
                 where a.privilege_type='EXECUTE'),'(none)')   as direct_execute_grants,
       case when p.proname = 'rls_auto_enable'
            then left(p.prosrc, 500) else '(omitted)' end      as source_excerpt
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (has_function_privilege('anon', p.oid, 'EXECUTE')
       or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
order by
  case when pg_get_function_result(p.oid) in ('trigger','event_trigger') then 2 else 1 end,
  p.proname;

commit;


-- ============================================================================
-- QUERY 7 — exact privilege rows to be revoked
--
-- Enumerates precisely which (table, grantee, privilege) triples exist for the
-- non-DML privileges, including PostgreSQL's MAINTAIN privilege, so a corrective
-- migration can be written against facts rather than an assumed table list.
-- ============================================================================
begin;
set transaction read only;

select c.relname::text                                    as table_name,
       case when a.grantee = 0 then 'PUBLIC'
            else a.grantee::regrole::text end             as grantee,
       string_agg(a.privilege_type, ',' order by a.privilege_type) as privileges
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
cross join lateral aclexplode(coalesce(c.relacl, acldefault('r',c.relowner))) a
where n.nspname = 'public'
  and c.relkind in ('r','p','v','m','f')
  and (a.grantee = 0
       or a.grantee = 'anon'::regrole::oid
       or a.grantee = 'authenticated'::regrole::oid)
  and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
group by c.relname, a.grantee
order by 1, 2;

commit;


-- ============================================================================
-- QUERY 8 — data omitted by the first exact-count query
--
-- QUERY 3 counted eight core public tables. This closes the gap by counting
-- the other four discovered public base tables plus auth.users. It reads only
-- counts; no emails, identities or row contents are returned.
-- ============================================================================
begin;
set transaction read only;

select 'admin_audit_events'        as table_name,count(*) as exact_rows from public.admin_audit_events
union all select 'pot_fixture_test_results', count(*) from public.pot_fixture_test_results
union all select 'pot_gameweek_processes', count(*) from public.pot_gameweek_processes
union all select 'pot_player_status_history', count(*) from public.pot_player_status_history
union all select 'auth.users', count(*) from auth.users
order by 1;

commit;
