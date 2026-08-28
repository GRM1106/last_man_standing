-- ============================================================================
-- Phase 2K — COMPLETE ACL CAPTURE, READ-ONLY
--
-- Intended target: staging only (documented reference evhiixndiuwwodsouyhf).
-- Confirm the connected project before running. Do not run against production.
--
-- ---------------------------------------------------------------------------
-- WHY THIS EXISTS
-- ---------------------------------------------------------------------------
-- Section 2W of PHASE_2K_DISCOVERY_EVIDENCE.md records that a logical restore
-- reproduced staging's schema and data but NOT its privileges: the restored copy
-- held 26 table grants against staging's 18, and 84 routine grants against 34.
--
-- schema.sql was not missing its ACLs — it carries 67 GRANT and 39 REVOKE
-- statements. The failure is that those statements are source-relative: pg_dump
-- emits what is needed starting from the defaults it assumes the target has, and
-- does not revoke what a different target grants by default.
--
-- SCOPE OF THAT CLAIM: **this observed divergence was additive and toward more
-- privilege.** That is what the 148-vs-206 comparison established. It is not a
-- general law — a target with narrower defaults than the source could diverge in
-- the opposite direction, and a recovery mechanism must not assume the error is
-- always one-way.
--
-- This query captures the complete privilege state of the source so a later
-- recovery artifact can reproduce it exactly without depending on the target's
-- defaults. The mechanism is designed in PHASE_2K_ACL_RECOVERY_DESIGN.md and
-- does not exist yet.
--
-- ---------------------------------------------------------------------------
-- SAFETY PROPERTIES
-- ---------------------------------------------------------------------------
--   * No DDL, no DML, no temporary objects, no function creation, no set_config.
--   * Reads system catalogues only. No information_schema: its specific_name
--     carries an OID suffix that differs between environments.
--   * Runs inside an explicit read-only transaction.
--   * NO SECRETS. pg_authid is never read. Password hashes, and the masked
--     rolpassword column of pg_roles, are never selected.
--
-- ---------------------------------------------------------------------------
-- OUTPUT CONTRACT — nine text columns, fixed order, all explicitly cast
-- ---------------------------------------------------------------------------
--   section          A..H
--   object_kind      table | view | materialized view | partitioned table |
--                    sequence | foreign table | column | function | procedure |
--                    aggregate | window | schema | role | membership |
--                    future <kind>
--   object_identity  schema-qualified and stable across environments:
--                      relations  public.pots
--                      columns    public.pots.lifecycle_status
--                      routines   public.confirm_team_pick(uuid, bigint, bigint)
--                                 — IDENTITY ARGUMENTS, never an OID, never
--                                   information_schema.specific_name
--                      membership member -> granted_role
--   owner            object owner. Section F: the role whose defaults apply.
--                    Sections G/H: '-'.
--   grantee          role name, or PUBLIC. '-' where not applicable.
--   grantor          role that granted the privilege. '-' where not applicable.
--   privilege_type   SELECT | EXECUTE | USAGE | MAINTAIN | ... Section G: the
--                    observed row count. Section H: 'attributes' or 'membership'.
--   is_grantable     WITH GRANT OPTION status, or ADMIN OPTION in section H
--                    membership rows. '-' where not applicable.
--   acl_source       explicit | default-derived | default-privilege-rule |
--                    ownership… | observed in A-D | role attributes | membership
--
-- ACL_SOURCE IS LOAD-BEARING. A NULL ACL does not mean "no privileges" — it means
-- the built-in defaults apply, which for functions includes EXECUTE to PUBLIC.
-- Rows reconstructed via acldefault() are default-derived; rows from a stored ACL
-- are explicit. Conflating them is what produced the 2W divergence.
--
-- COLUMN ACLs ARE DIFFERENT and must not be reconstructed. A NULL pg_attribute
-- .attacl means "no column-specific privileges exist; table-level applies" —
-- there are no built-in column defaults to derive. Section C therefore emits rows
-- only where attacl IS NOT NULL, and every such row is explicit by construction.
--
-- SECTIONS
--   A. SCHEMA PRIVILEGES        privileges on schema public itself
--   B. RELATION PRIVILEGES      tables, partitioned, views, matviews, sequences,
--                               foreign tables
--   C. COLUMN PRIVILEGES        pg_attribute.attacl, explicit only
--   D. ROUTINE PRIVILEGES       functions, procedures, aggregates, window fns
--   E. OWNERSHIP                every object with its owner, privileges or not
--   F. DEFAULT PRIVILEGES       pg_default_acl rules affecting FUTURE objects
--   G. GRANTEES OBSERVED        distinct grantees in A-D, plus expected-role check
--   H. ROLE SECURITY CONTEXT    existence, attributes, inheritance and membership
--                               edges for every owner/grantor/grantee observed
--
-- Section E exists because a privilege query cannot prove completeness: an object
-- whose ACL is an empty array produces no rows in A-D. Section H exists because a
-- privilege is only meaningful relative to who can exercise it — a grant to a role
-- that is a member of another role, or that inherits, has different reach.
--
-- ---------------------------------------------------------------------------
-- HOW TO RUN
-- ---------------------------------------------------------------------------
-- One statement, one result set. Export the COMPLETE output as CSV — do not
-- summarise, and do not omit routine, column or grant rows. Hold the CSV outside
-- the repository with owner-only permissions; do not commit it.
--
-- ---------------------------------------------------------------------------
-- POSTGRESQL VERSION REQUIREMENT
-- ---------------------------------------------------------------------------
-- Requires PostgreSQL 16 or later: pg_auth_members.inherit_option and
-- .set_option do not exist before 16. Verified present on the target line —
-- pg_auth_members carries oid, roleid, member, grantor, admin_option,
-- inherit_option, set_option on 17.6. Both environments are confirmed 17.6
-- (evidence sections 2F and 2P). On PostgreSQL 15 or earlier this query fails
-- to parse rather than silently omitting membership controls, which is the
-- intended behaviour.
-- ============================================================================

begin;
set transaction read only;

-- WITH RECURSIVE is required by role_closure below. Non-recursive CTEs may
-- follow it unchanged; the keyword applies to the WITH clause, not to each CTE.
with recursive
-- NOTE: relkind 'S' is a SEQUENCE, but acldefault()'s sequence code is lowercase
-- 's' — uppercase 'S' means FOREIGN SERVER there. Passing relkind through would
-- silently reconstruct the wrong defaults. pg_default_acl (section F) uses
-- uppercase 'S' for sequence, a third convention.
rel as (
  select c.oid, n.nspname, c.relname, c.relkind, c.relowner, c.relacl,
         case c.relkind
           when 'r' then 'table'    when 'p' then 'partitioned table'
           when 'v' then 'view'     when 'm' then 'materialized view'
           when 'S' then 'sequence' when 'f' then 'foreign table'
           else c.relkind::text end as kind,
         case when c.relkind = 'S' then 's'::"char" else 'r'::"char" end as acl_type
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r','p','v','m','S','f')
),
rtn as (
  select p.oid, n.nspname, p.proname, p.proowner, p.proacl,
         case p.prokind
           when 'f' then 'function'  when 'p' then 'procedure'
           when 'a' then 'aggregate' when 'w' then 'window'
           else p.prokind::text end as kind,
         (n.nspname || '.' || p.proname || '('
            || pg_get_function_identity_arguments(p.oid) || ')') as identity
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
),
sch as (
  select n.oid, n.nspname, n.nspowner, n.nspacl
  from pg_namespace n where n.nspname = 'public'
),

-- Default-privilege rules, factored into a CTE so their roles feed the role
-- closure as well as section F output. Previously inlined, which meant the roles
-- named in default rules were invisible to the closure.
def_acl as (
  select d.defaclrole, d.defaclobjtype, d.defaclnamespace,
         coalesce(dn.nspname, '(all schemas)') as nspname,
         a.grantee, a.grantor, a.privilege_type, a.is_grantable
  from pg_default_acl d
  left join pg_namespace dn on dn.oid = d.defaclnamespace
  cross join lateral aclexplode(d.defaclacl) a
  where dn.nspname = 'public' or d.defaclnamespace = 0
),

acl_rows as (
  select 'A. SCHEMA PRIVILEGES'::text                     as section,
         'schema'::text                                   as object_kind,
         s.nspname::text                                  as object_identity,
         pg_get_userbyid(s.nspowner)::text                as owner,
         (case when a.grantee = 0 then 'PUBLIC'
               else pg_get_userbyid(a.grantee) end)::text as grantee,
         pg_get_userbyid(a.grantor)::text                 as grantor,
         a.privilege_type::text                           as privilege_type,
         a.is_grantable::text                             as is_grantable,
         (case when s.nspacl is null then 'default-derived'
               else 'explicit' end)::text                 as acl_source
  from sch s
  cross join lateral aclexplode(coalesce(s.nspacl, acldefault('n'::"char", s.nspowner))) a

  union all

  select 'B. RELATION PRIVILEGES'::text, r.kind::text,
         (r.nspname || '.' || r.relname)::text,
         pg_get_userbyid(r.relowner)::text,
         (case when a.grantee = 0 then 'PUBLIC'
               else pg_get_userbyid(a.grantee) end)::text,
         pg_get_userbyid(a.grantor)::text,
         a.privilege_type::text, a.is_grantable::text,
         (case when r.relacl is null then 'default-derived' else 'explicit' end)::text
  from rel r
  cross join lateral aclexplode(coalesce(r.relacl, acldefault(r.acl_type, r.relowner))) a

  union all

  -- C. Column privileges. attacl NULL means no column-specific grants exist, so
  --    there is nothing to derive and nothing to emit. Never reconstructed.
  select 'C. COLUMN PRIVILEGES'::text, 'column'::text,
         (r.nspname || '.' || r.relname || '.' || att.attname)::text,
         pg_get_userbyid(r.relowner)::text,
         (case when a.grantee = 0 then 'PUBLIC'
               else pg_get_userbyid(a.grantee) end)::text,
         pg_get_userbyid(a.grantor)::text,
         a.privilege_type::text, a.is_grantable::text,
         'explicit'::text
  from rel r
  join pg_attribute att on att.attrelid = r.oid
  cross join lateral aclexplode(att.attacl) a
  where att.attnum > 0 and not att.attisdropped and att.attacl is not null

  union all

  select 'D. ROUTINE PRIVILEGES'::text, t.kind::text, t.identity::text,
         pg_get_userbyid(t.proowner)::text,
         (case when a.grantee = 0 then 'PUBLIC'
               else pg_get_userbyid(a.grantee) end)::text,
         pg_get_userbyid(a.grantor)::text,
         a.privilege_type::text, a.is_grantable::text,
         (case when t.proacl is null then 'default-derived' else 'explicit' end)::text
  from rtn t
  cross join lateral aclexplode(coalesce(t.proacl, acldefault('f'::"char", t.proowner))) a
),

-- Seed for the role closure: every REAL role implicated anywhere as owner,
-- grantor or grantee, across schema/relation/column/routine rows (A-D) AND
-- default-privilege rules, plus the three expected application roles.
--
-- PUBLIC is deliberately excluded. It is a pseudo-grantee, not a row in
-- pg_roles, and must never be resolved through it. It is still emitted as a
-- grantee wherever it holds a privilege — it is only absent from the closure.
role_seed as (
  select rn from (
    select owner    as rn from acl_rows
    union select grantee   from acl_rows
    union select grantor   from acl_rows
    union select pg_get_userbyid(r.relowner)::text from rel r
    union select pg_get_userbyid(t.proowner)::text from rtn t
    union select pg_get_userbyid(s2.nspowner)::text from sch s2
    union select pg_get_userbyid(d.defaclrole)::text from def_acl d
    union select (case when d.grantee = 0 then null
                       else pg_get_userbyid(d.grantee) end)::text from def_acl d
    union select pg_get_userbyid(d.grantor)::text from def_acl d
    union select x from (values ('anon'),('authenticated'),('service_role')) v(x)
  ) u
  where rn is not null and rn <> '-' and rn <> 'PUBLIC'
    and exists (select 1 from pg_roles pr where pr.rolname = u.rn)
),

-- Recursive closure over membership, followed in BOTH directions: a seed role's
-- groups and its members are equally relevant to what a grant can actually reach.
--
-- CYCLE PROTECTION: the recursive term uses UNION, not UNION ALL. UNION discards
-- rows already present in the accumulated result, so a membership cycle
-- (a member of b, b member of a) terminates instead of looping forever. No depth
-- cap is imposed, because a cap would silently truncate a legitimately deep
-- hierarchy — the wrong failure mode for a security capture.
role_closure as (
  select rn from role_seed
  union
  select other.rolname::text
  from role_closure rc
  join pg_roles cur on cur.rolname = rc.rn
  join pg_auth_members m on m.member = cur.oid or m.roleid = cur.oid
  join pg_roles other
    on other.oid = case when m.member = cur.oid then m.roleid else m.member end
)

select section, object_kind, object_identity, owner,
       grantee, grantor, privilege_type, is_grantable, acl_source
from acl_rows

union all

-- E. Every object and its owner, independent of any privileges.
select 'E. OWNERSHIP'::text, 'schema'::text, s.nspname::text,
       pg_get_userbyid(s.nspowner)::text,
       '-'::text, '-'::text, '-'::text, '-'::text, 'ownership'::text
from sch s
union all
select 'E. OWNERSHIP'::text, r.kind::text, (r.nspname || '.' || r.relname)::text,
       pg_get_userbyid(r.relowner)::text, '-'::text, '-'::text, '-'::text, '-'::text,
       (case when r.relacl is null then 'ownership (acl null: defaults apply)'
             when cardinality(r.relacl) = 0 then 'ownership (acl empty: no privileges)'
             else 'ownership' end)::text
from rel r
union all
select 'E. OWNERSHIP'::text, t.kind::text, t.identity::text,
       pg_get_userbyid(t.proowner)::text, '-'::text, '-'::text, '-'::text, '-'::text,
       (case when t.proacl is null then 'ownership (acl null: defaults apply)'
             when cardinality(t.proacl) = 0 then 'ownership (acl empty: no privileges)'
             else 'ownership' end)::text
from rtn t

union all

-- F. Default-privilege rules: what the source grants on FUTURE objects. Rules,
--    not privileges on existing objects. The recovery mechanism must reset and
--    reproduce these exactly — they are the origin of the 2W divergence, and they
--    are IN SCOPE for verification, not excluded from it.
select 'F. DEFAULT PRIVILEGES'::text,
       (case d.defaclobjtype
          when 'r' then 'future table'   when 'S' then 'future sequence'
          when 'f' then 'future routine' when 'T' then 'future type'
          when 'n' then 'future schema'
          else d.defaclobjtype::text end)::text,
       d.nspname::text,
       pg_get_userbyid(d.defaclrole)::text,
       (case when d.grantee = 0 then 'PUBLIC'
             else pg_get_userbyid(d.grantee) end)::text,
       pg_get_userbyid(d.grantor)::text,
       d.privilege_type::text, d.is_grantable::text,
       'default-privilege-rule'::text
from def_acl d

union all

-- G. Distinct grantees observed. Grantees are never filtered anywhere above: an
--    unexpected grantee must surface rather than be silently dropped.
select 'G. GRANTEES OBSERVED'::text, 'role'::text, ar.grantee::text,
       '-'::text, ar.grantee::text, '-'::text, count(*)::text, '-'::text,
       'observed in A-D'::text
from acl_rows ar
group by ar.grantee

union all

select 'G. GRANTEES OBSERVED'::text, 'role'::text, expected.name::text,
       '-'::text, expected.name::text, '-'::text, '-'::text, '-'::text,
       (case when expected.name = 'PUBLIC' then 'expected role: always present'
             when exists (select 1 from pg_roles pr where pr.rolname = expected.name)
               then 'expected role: exists'
             else 'expected role: ABSENT' end)::text
from (values ('PUBLIC'),('anon'),('authenticated'),('service_role')) as expected(name)

union all

-- H. Role security context over the CLOSED role set, not just directly observed
--    roles. A privilege's real reach depends on membership and inheritance, so a
--    role reachable only transitively still matters.
--    NO SECRETS: pg_authid is never read; rolpassword is never selected.
select 'H. ROLE SECURITY CONTEXT'::text, 'role'::text, rc.rn::text,
       '-'::text, rc.rn::text, '-'::text, 'attributes'::text, '-'::text,
       ('superuser='    || pr.rolsuper::text
     || ' inherit='     || pr.rolinherit::text
     || ' createrole='  || pr.rolcreaterole::text
     || ' createdb='    || pr.rolcreatedb::text
     || ' login='       || pr.rolcanlogin::text
     || ' replication=' || pr.rolreplication::text
     || ' bypassrls='   || pr.rolbypassrls::text)::text
from role_closure rc
join pg_roles pr on pr.rolname = rc.rn

union all

-- Expected application roles reported explicitly, so an ABSENT one is visible
-- rather than merely missing from the closure.
select 'H. ROLE SECURITY CONTEXT'::text, 'role'::text, e.name::text,
       '-'::text, e.name::text, '-'::text, 'existence'::text, '-'::text,
       (case when exists (select 1 from pg_roles pr where pr.rolname = e.name)
             then 'expected role: exists' else 'expected role: ABSENT' end)::text
from (values ('anon'),('authenticated'),('service_role')) as e(name)

union all

-- Every membership edge with BOTH endpoints inside the closed set, carrying all
-- four PostgreSQL 17 membership controls: admin_option, inherit_option,
-- set_option and the membership grantor.
select 'H. ROLE SECURITY CONTEXT'::text, 'membership'::text,
       (mem.rolname || ' -> ' || grp.rolname)::text,
       '-'::text, mem.rolname::text, pg_get_userbyid(m.grantor)::text,
       'membership'::text, m.admin_option::text,
       ('inherit_option=' || m.inherit_option::text
     || ' set_option='    || m.set_option::text)::text
from pg_auth_members m
join pg_roles mem on mem.oid = m.member
join pg_roles grp on grp.oid = m.roleid
where mem.rolname in (select rn from role_closure)
  and grp.rolname in (select rn from role_closure)

order by 1, 3, 5, 7, 2, 4, 6, 8, 9;

commit;
