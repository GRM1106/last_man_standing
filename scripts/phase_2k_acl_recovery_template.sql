-- ============================================================================
-- Phase 2K — ACL RECOVERY ARTIFACT
--
--   GENERATED FILE — DO NOT EDIT BY HAND.
--   Regenerate with scripts/generate_phase_2k_acl_recovery.py.
--
-- ---------------------------------------------------------------------------
--  ###   THIS FILE TARGETS RESTORED COPIES ONLY.                          ###
--  ###                                                                    ###
--  ###   DO NOT RUN IT AGAINST STAGING. DO NOT RUN IT AGAINST PRODUCTION. ###
--  ###                                                                    ###
--  ###   It drives a target database's privilege state to match a capture ###
--  ###   taken FROM staging. Running it against the source itself, or     ###
--  ###   against production, would revoke and re-grant every privilege in ###
--  ###   schema public for no reason, and would apply one database's      ###
--  ###   privileges to another. The preflight below cannot detect which   ###
--  ###   database you are connected to — only you can. Confirm the target ###
--  ###   before you run this.                                             ###
-- ---------------------------------------------------------------------------
--
@@SUPERSEDED_BANNER@@-- Source capture:         @@SOURCE_BASENAME@@
-- Source capture SHA-256: @@SOURCE_SHA@@
-- Capture query SHA-256:  @@CAPTURE_QUERY_SHA@@
-- Label:                  @@LABEL@@
--
-- The capture-query hash pins the version of
-- supabase/discovery/phase_2k_acl_capture.sql that this artifact's contract
-- assumes. If that file changes, the source capture must be retaken: a capture
-- produced by a different query version may describe a different set of objects,
-- and this artifact would then be reasoning about facts the capture never
-- recorded.
--
-- The generator refuses to emit this file unless the source capture hashes to
-- the value above, so that hash identifies the exact privilege state this
-- artifact reproduces.
--
-- Source capture structure:
@@SECTION_COUNTS@@
--
-- Expected workload:
@@WORKLOAD_COUNTS@@
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES
-- ---------------------------------------------------------------------------
-- The full reset/replay algorithm from PHASE_2K_ACL_RECOVERY_DESIGN.md:
--
--   PREFLIGHT  fail-closed checks, before any GRANT or REVOKE
--   RESET      revoke every current in-scope ACL edge, grantor-scoped, with
--              leaf-peeling, no-progress detection and a grant-option CASCADE
--              cycle break; schema `public` LAST so USAGE survives the work
--   REPLAY     schema `public` FIRST, then objects in dependency order, then
--              default-privilege rules driven to the exact captured ACL
--   VERIFY     in-transaction parity checks; any failure aborts the whole run
--
-- Everything happens in ONE transaction under a transaction-scoped advisory
-- lock. There is no partial application: either every check passes and the
-- transaction commits, or it rolls back completely.
--
-- Running it a second time converges on the same state (fixed point). It is
-- not a no-op — it repeats the full reset and replay — but it lands identically.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES NOT DO
-- ---------------------------------------------------------------------------
--   * No ownership changes. Owners are verified, never altered.
--   * No role creation, alteration or deletion. No password or secret handling.
--   * No writes outside schema `public` and the captured default-privilege
--     rules. Platform-managed schemas are never overwritten.
--   * No DDL on user objects. Only GRANT, REVOKE and ALTER DEFAULT PRIVILEGES.
--   * The only objects it creates are TEMP staging tables and views, which are
--     session-local, carry no privileges of their own, and are dropped on
--     commit. They are populated before the preflight; no privilege of any
--     real object is touched until every preflight check has passed.
-- ============================================================================

\set ON_ERROR_STOP on

begin;

-- Transaction-scoped: released automatically on commit or rollback, so a
-- failed run cannot strand the lock.
select pg_advisory_xact_lock(hashtext('phase-2k-acl-recovery'));

-- ============================================================================
-- STAGED SOURCE SNAPSHOT  (data; the only generated part of this file)
-- ============================================================================
-- Identifiers were decomposed by the generator into (schema, name, args,
-- column) so that nothing here re-parses a dotted identity at run time.

create temp table _p2k_src_edge (
  cls text not null, ident text not null, sch text not null, nm text not null,
  rargs text, col text,
  -- the object whose ACL this edge belongs to, resolved by the generator.
  -- For a column edge that is the parent relation; otherwise the object itself.
  own_cls text not null, own_ident text not null,
  owner text not null, grantee text not null,
  grantor text not null, priv text not null, grantable boolean not null
) on commit drop;

@@EDGE_VALUES@@

create temp table _p2k_src_own (
  cls text not null, ident text not null, sch text not null, nm text not null,
  rargs text, owner text not null, state text not null
) on commit drop;

@@OWN_VALUES@@

create temp table _p2k_src_defgroup (
  defowner text not null, objtype text not null, sch text not null
) on commit drop;

@@DEFGROUP_VALUES@@

create temp table _p2k_src_defedge (
  defowner text not null, objtype text not null, sch text not null,
  grantee text not null, priv text not null, grantable boolean not null
) on commit drop;

@@DEFEDGE_VALUES@@

create temp table _p2k_src_scope (
  nspname text not null, classification text not null
) on commit drop;

@@SCOPE_VALUES@@

create temp table _p2k_src_role (rolname text not null) on commit drop;

@@ROLE_VALUES@@

-- Section H. The artifact never mutates roles, but role membership decides the
-- real reach of every grant, so it must refuse to run against a role graph that
-- differs from the captured one.
create temp table _p2k_src_roleattr (
  rolname text not null, attributes text not null
) on commit drop;

@@ROLEATTR_VALUES@@

create temp table _p2k_src_rolemember (
  member text not null, grp text not null, grantor text not null,
  admin_option boolean not null, inherit_option boolean not null,
  set_option boolean not null
) on commit drop;

@@ROLEMEMBER_VALUES@@

-- ============================================================================
-- TARGET-SIDE ENUMERATION  (live; re-evaluated on every read)
-- ============================================================================

create temp view _p2k_tgt_edge as
  -- `fam` is the object-family key used for leaf-peeling. A column privilege is
  -- authorised by a TABLE-level grant option, so a column edge and its parent
  -- relation edge belong to ONE dependency group even though they are different
  -- objects. Grouping only by (cls, ident) lets the parent be revoked first,
  -- which silently orphans the column grant: the revoke succeeds, the grantee
  -- keeps the column privilege, and not even the owner can remove it afterwards
  -- because only the recorded grantor may revoke and it has lost the authority.
  select 'schema'::text as cls, 'public'::text as ident, 'public'::text as sch,
         'public'::text as nm, null::text as rargs, null::text as col,
         'public'::text as fam,
         pg_get_userbyid(n.nspowner)::text as owner,
         (case when a.grantee = 0 then 'PUBLIC'
               else pg_get_userbyid(a.grantee) end)::text as grantee,
         pg_get_userbyid(a.grantor)::text as grantor,
         a.privilege_type::text as priv, a.is_grantable as grantable
  from pg_namespace n
  cross join lateral aclexplode(n.nspacl) a
  where n.nspname = 'public'
  union all
  select (case when c.relkind = 'S' then 'sequence' else 'relation' end),
         'public.' || c.relname, 'public', c.relname, null, null,
         'public.' || c.relname,
         pg_get_userbyid(c.relowner),
         (case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end),
         pg_get_userbyid(a.grantor), a.privilege_type, a.is_grantable
  from pg_class c
  cross join lateral aclexplode(c.relacl) a
  where c.relnamespace = 'public'::regnamespace
    and c.relkind in ('r','p','v','m','S','f')
  union all
  -- system columns included: attnum <> 0, never attnum > 0
  select 'column', 'public.' || c.relname || '.' || att.attname, 'public',
         c.relname, null, att.attname, 'public.' || c.relname,
         pg_get_userbyid(c.relowner),
         (case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end),
         pg_get_userbyid(a.grantor), a.privilege_type, a.is_grantable
  from pg_class c
  join pg_attribute att on att.attrelid = c.oid
       and att.attnum <> 0 and not att.attisdropped
  cross join lateral aclexplode(att.attacl) a
  where c.relnamespace = 'public'::regnamespace
    and c.relkind in ('r','p','v','m','S','f')
    and att.attacl is not null
  union all
  select 'routine',
         'public.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         'public', p.proname, pg_get_function_identity_arguments(p.oid), null,
         'public.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         pg_get_userbyid(p.proowner),
         (case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end),
         pg_get_userbyid(a.grantor), a.privilege_type, a.is_grantable
  from pg_proc p
  cross join lateral aclexplode(p.proacl) a
  where p.pronamespace = 'public'::regnamespace
  union all
  select 'type', 'public.' || t.typname, 'public', t.typname, null, null,
         'public.' || t.typname,
         pg_get_userbyid(t.typowner),
         (case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end),
         pg_get_userbyid(a.grantor), a.privilege_type, a.is_grantable
  from pg_type t
  left join pg_class tc on tc.oid = t.typrelid
  cross join lateral aclexplode(t.typacl) a
  where t.typnamespace = 'public'::regnamespace
    and t.typtype in ('e','d','c','r','b')
    -- must mirror the capture exactly: an ACTUAL array type is its element
    -- type's typarray. A DOMAIN over an array is typcategory 'A' but grantable.
    and not exists (select 1 from pg_type et
                    where et.oid = t.typelem and et.typarray = t.oid)
    and (tc.oid is null or tc.relkind in ('c','r','p','v','m','f'));

-- Every in-scope object, with the three-state provenance of its stored ACL.
create temp view _p2k_tgt_obj as
  select 'schema'::text as cls, 'public'::text as ident, 'public'::text as sch,
         'public'::text as nm, null::text as rargs,
         pg_get_userbyid(n.nspowner)::text as owner,
         (case when n.nspacl is null then 'null'
               when cardinality(n.nspacl) = 0 then 'empty'
               else 'explicit' end)::text as state
  from pg_namespace n where n.nspname = 'public'
  union all
  select (case when c.relkind = 'S' then 'sequence' else 'relation' end),
         'public.' || c.relname, 'public', c.relname, null,
         pg_get_userbyid(c.relowner),
         (case when c.relacl is null then 'null'
               when cardinality(c.relacl) = 0 then 'empty' else 'explicit' end)
  from pg_class c
  where c.relnamespace = 'public'::regnamespace
    and c.relkind in ('r','p','v','m','S','f')
  union all
  select 'routine',
         'public.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         'public', p.proname, pg_get_function_identity_arguments(p.oid),
         pg_get_userbyid(p.proowner),
         (case when p.proacl is null then 'null'
               when cardinality(p.proacl) = 0 then 'empty' else 'explicit' end)
  from pg_proc p where p.pronamespace = 'public'::regnamespace
  union all
  select 'type', 'public.' || t.typname, 'public', t.typname, null,
         pg_get_userbyid(t.typowner),
         (case when t.typacl is null then 'null'
               when cardinality(t.typacl) = 0 then 'empty' else 'explicit' end)
  from pg_type t
  left join pg_class tc on tc.oid = t.typrelid
  where t.typnamespace = 'public'::regnamespace
    and t.typtype in ('e','d','c','r','b')
    -- must mirror the capture exactly: an ACTUAL array type is its element
    -- type's typarray. A DOMAIN over an array is typcategory 'A' but grantable.
    and not exists (select 1 from pg_type et
                    where et.oid = t.typelem and et.typarray = t.oid)
    and (tc.oid is null or tc.relkind in ('c','r','p','v','m','f'));

-- Default-privilege rules in scope: those attached to schema public, plus the
-- unscoped (all-schemas) rules, exactly as the capture defines them.
create temp view _p2k_tgt_defgroup as
  select pg_get_userbyid(d.defaclrole)::text as defowner,
         d.defaclobjtype::text as objtype,
         coalesce(dn.nspname, '')::text as sch,
         d.defaclacl as acl
  from pg_default_acl d
  left join pg_namespace dn on dn.oid = d.defaclnamespace
  where dn.nspname = 'public' or d.defaclnamespace = 0;

create temp view _p2k_tgt_defedge as
  select g.defowner, g.objtype, g.sch,
         (case when a.grantee = 0 then 'PUBLIC'
               else pg_get_userbyid(a.grantee) end)::text as grantee,
         a.privilege_type::text as priv, a.is_grantable as grantable
  from _p2k_tgt_defgroup g
  cross join lateral aclexplode(g.acl) a
  where cardinality(g.acl) > 0;

-- ============================================================================
-- PREFLIGHT  — fail closed. No GRANT or REVOKE has run at this point.
-- ============================================================================

do $preflight$
declare
  v_num int;
  n int;
  r record;
begin
  -- 1. PostgreSQL major version
  v_num := current_setting('server_version_num')::int;
  if v_num < 170000 or v_num >= 180000 then
    raise exception 'PREFLIGHT: PostgreSQL 17 required, found %',
      current_setting('server_version');
  end if;

  -- 2. staged source matches the counts embedded at generation time
  select count(*) into n from _p2k_src_edge;
  if n <> @@EXPECT_EDGES@@ then
    raise exception 'PREFLIGHT: staged source edges = %, expected %', n, @@EXPECT_EDGES@@;
  end if;
  select count(*) into n from _p2k_src_own;
  if n <> @@EXPECT_OWNERS@@ then
    raise exception 'PREFLIGHT: staged source objects = %, expected %', n, @@EXPECT_OWNERS@@;
  end if;
  select count(*) into n from _p2k_src_defgroup;
  if n <> @@EXPECT_DEFGROUPS@@ then
    raise exception 'PREFLIGHT: staged default groups = %, expected %', n, @@EXPECT_DEFGROUPS@@;
  end if;
  select count(*) into n from _p2k_src_defedge;
  if n <> @@EXPECT_DEFEDGES@@ then
    raise exception 'PREFLIGHT: staged default edges = %, expected %', n, @@EXPECT_DEFEDGES@@;
  end if;
  select count(*) into n from _p2k_src_role;
  if n <> @@EXPECT_ROLES@@ then
    raise exception 'PREFLIGHT: staged roles = %, expected %', n, @@EXPECT_ROLES@@;
  end if;
  select count(*) into n from _p2k_src_roleattr;
  if n <> @@EXPECT_ROLEATTRS@@ then
    raise exception 'PREFLIGHT: staged role closure = %, expected %', n, @@EXPECT_ROLEATTRS@@;
  end if;
  select count(*) into n from _p2k_src_rolemember;
  if n <> @@EXPECT_ROLEMEMBERS@@ then
    raise exception 'PREFLIGHT: staged memberships = %, expected %', n, @@EXPECT_ROLEMEMBERS@@;
  end if;

  -- 3. every role the recovery names must exist
  for r in select rolname from _p2k_src_role order by 1 loop
    if not exists (select 1 from pg_roles where rolname = r.rolname) then
      raise exception 'PREFLIGHT: role % does not exist on this target', r.rolname;
    end if;
  end loop;

  -- 4. every grantor and default-rule owner must be assumable by the caller.
  --    The test is 'SET', not 'USAGE'. Since PostgreSQL 16 a membership carries
  --    independent inherit_option and set_option flags: pg_has_role(...,'USAGE')
  --    reports inheritance and can be true where SET ROLE is denied (the run
  --    would then die mid-reset, after mutations, violating fail-closed) and
  --    false where SET ROLE would in fact succeed (a runnable target refused).
  --    'MEMBER' is not a substitute; it is true in both wrong cases.
  --    Owners are included because a captured type whose ACL is NULL has its
  --    built-in default edges synthesized with the owner as grantor.
  for r in select distinct grantor as who from _p2k_src_edge
           union select distinct owner from _p2k_src_own
           union select distinct defowner from _p2k_src_defgroup
           union select distinct grantor from _p2k_tgt_edge
           union select distinct defowner from _p2k_tgt_defgroup loop
    if not pg_has_role(current_user, r.who, 'SET') then
      raise exception
        'PREFLIGHT: current_user cannot SET ROLE to %, which the recovery must act as',
        r.who;
    end if;
  end loop;

  -- 4b. a grantor also needs USAGE on schema `public` to revoke or grant on the
  --     objects inside it. The schema-last reset protects USAGE that THIS run
  --     would remove, but not a target that already lacks it.
  for r in select distinct grantor as who from _p2k_tgt_edge where cls <> 'schema'
           union select distinct grantor from _p2k_src_edge where cls <> 'schema' loop
    if not has_schema_privilege(r.who, 'public', 'USAGE') then
      raise exception
        'PREFLIGHT: grantor % lacks USAGE on schema public and could not complete the reset',
        r.who;
    end if;
  end loop;

  -- 4c. A role literally named "PUBLIC" is creatable and renders identically to
  --     the grantee=0 pseudo-role in both the capture and this enumeration, so
  --     the two cannot be told apart. Replaying would silently convert grants
  --     between them. Refuse rather than guess.
  if exists (select 1 from pg_roles where rolname = 'PUBLIC') then
    raise exception
      'PREFLIGHT: a role literally named "PUBLIC" exists; it is indistinguishable from the PUBLIC pseudo-role in this format - fail closed';
  end if;

  -- 4d. A DOMAIN over an array has typtype 'd' but typcategory 'A', so the
  --     capture's `typcategory <> ''A''` filter (meant to exclude true array
  --     types, where GRANT is refused) also hides it -- and the same filter in
  --     the target enumeration hides it from check 6 below. Such a type IS
  --     independently grantable and enforced, so it would survive recovery
  --     unrestored while verification reported success.
  -- The capture now represents domains over arrays, so the earlier blanket
  -- refusal on typcategory 'A' is gone. What remains is the general guard: any
  -- type in `public` that actually holds an ACL but which the capture's
  -- predicate excludes would be invisible to both sides, and the "unknown
  -- object" check below could not see it either.
  if exists (
    select 1 from pg_type t
    left join pg_class tc on tc.oid = t.typrelid
    where t.typnamespace = 'public'::regnamespace
      and t.typacl is not null
      and not (t.typtype in ('e','d','c','r','b')
               and not exists (select 1 from pg_type et
                               where et.oid = t.typelem and et.typarray = t.oid)
               and (tc.oid is null or tc.relkind in ('c','r','p','v','m','f'))))
  then
    raise exception
      'PREFLIGHT: schema public holds a type with an explicit ACL that the capture cannot represent - fail closed';
  end if;

  -- 4e. ROLE-CONTEXT PARITY over the captured closed role set.
  --     ACL-edge parity implies effective-access parity only while the role
  --     graph is unchanged: a privilege held by a group confers nothing on a
  --     principal that is no longer a member. This artifact does not and must
  --     not alter roles, so a divergent role graph is a refusal, not a repair.
  --     Section G is intentionally not checked here: its rows are counts of
  --     grantees observed in sections A-D, an aggregate of the very edges this
  --     artifact replays individually, so it carries nothing the edges do not.
  for r in select rolname, attributes from _p2k_src_roleattr order by rolname loop
    if not exists (select 1 from pg_roles pr where pr.rolname = r.rolname) then
      raise exception 'PREFLIGHT: captured role % does not exist on this target', r.rolname;
    end if;
    if not exists (
      select 1 from pg_roles pr where pr.rolname = r.rolname
        and ('superuser='    || pr.rolsuper::text
          || ' inherit='     || pr.rolinherit::text
          || ' createrole='  || pr.rolcreaterole::text
          || ' createdb='    || pr.rolcreatedb::text
          || ' login='       || pr.rolcanlogin::text
          || ' replication=' || pr.rolreplication::text
          || ' bypassrls='   || pr.rolbypassrls::text) = r.attributes)
    then
      raise exception
        'PREFLIGHT: role % has different attributes on this target than the capture records - fail closed',
        r.rolname;
    end if;
  end loop;

  -- memberships among the closed set, compared in BOTH directions including
  -- the grantor, admin_option, inherit_option and set_option
  for r in
    select m.member, m.grp from _p2k_src_rolemember m
    where not exists (
      select 1 from pg_auth_members am
      join pg_roles mem on mem.oid = am.member
      join pg_roles grp on grp.oid = am.roleid
      where mem.rolname = m.member and grp.rolname = m.grp
        and pg_get_userbyid(am.grantor) = m.grantor
        and am.admin_option = m.admin_option
        and am.inherit_option = m.inherit_option
        and am.set_option = m.set_option)
  loop
    raise exception
      'PREFLIGHT: captured membership % -> % is missing or differs on this target - fail closed',
      r.member, r.grp;
  end loop;
  for r in
    select mem.rolname as member, grp.rolname as grp
    from pg_auth_members am
    join pg_roles mem on mem.oid = am.member
    join pg_roles grp on grp.oid = am.roleid
    where mem.rolname in (select rolname from _p2k_src_roleattr)
      and grp.rolname in (select rolname from _p2k_src_roleattr)
      and not exists (
        select 1 from _p2k_src_rolemember m
        where m.member = mem.rolname and m.grp = grp.rolname
          and m.grantor = pg_get_userbyid(am.grantor)
          and m.admin_option = am.admin_option
          and m.inherit_option = am.inherit_option
          and m.set_option = am.set_option)
  loop
    raise exception
      'PREFLIGHT: target has membership % -> % that the capture does not record - fail closed',
      r.member, r.grp;
  end loop;

  -- 4f. an EMPTY captured ACL can only be materialised for the classes below
  for r in select distinct cls from _p2k_src_own where state = 'empty' loop
    if r.cls not in ('schema','relation','sequence','routine','type') then
      raise exception
        'PREFLIGHT: capture records an empty ACL for object class %, which cannot be materialised - fail closed',
        r.cls;
    end if;
  end loop;

  -- 5. every captured object must exist on the target with the same owner
  for r in select * from _p2k_src_own order by cls, ident loop
    if not exists (select 1 from _p2k_tgt_obj t
                   where t.cls = r.cls and t.ident = r.ident) then
      raise exception 'PREFLIGHT: captured object % (%) is absent from this target',
        r.ident, r.cls;
    end if;
    if not exists (select 1 from _p2k_tgt_obj t
                   where t.cls = r.cls and t.ident = r.ident and t.owner = r.owner) then
      raise exception
        'PREFLIGHT: owner of % differs from the capture; this artifact never changes ownership',
        r.ident;
    end if;
  end loop;

  -- 6. no in-scope target object may be absent from the capture. Resetting an
  --    object the capture does not describe would leave it with no privileges
  --    at all, which is a silent security change.
  for r in select * from _p2k_tgt_obj order by cls, ident loop
    if not exists (select 1 from _p2k_src_own s
                   where s.cls = r.cls and s.ident = r.ident) then
      raise exception
        'PREFLIGHT: target object % (%) is not described by the capture - fail closed',
        r.ident, r.cls;
    end if;
  end loop;

  -- 7. A default-privilege rule the capture does not describe is target-only
  --    excess and the reset deletes it, which is what property 5 of the
  --    validated algorithm requires. That is only safe when the rule belongs to
  --    a role the capture actually knows about: deleting an unrelated role's
  --    rule would be an out-of-scope change to someone else's future objects.
  for r in select * from _p2k_tgt_defgroup order by defowner, objtype, sch loop
    if not exists (select 1 from _p2k_src_defgroup s
                   where s.defowner = r.defowner and s.objtype = r.objtype
                     and s.sch = r.sch)
       and (r.sch = ''
            or not exists (select 1 from _p2k_src_role sr where sr.rolname = r.defowner))
    then
      raise exception
        'PREFLIGHT: target default-privilege rule (owner=%, objtype=%, schema=%) is not in the capture and cannot be removed safely - fail closed',
        r.defowner, r.objtype, coalesce(nullif(r.sch, ''), '(all schemas)');
    end if;
  end loop;
  -- An UNSCOPED target-only rule (schema = '') is refused even when its owner is
  -- named by the capture: unlike an object grant, it governs future objects in
  -- every schema, so deleting it would reach into platform-managed schemas this
  -- recovery is forbidden to touch. Only IN SCHEMA public rules owned by a
  -- captured role are removable as excess.

  -- 8. schema scope, recomputed live against this target
  -- alias deliberately not `n`: that is a declared scalar in this block, and a
  -- qualified reference resolves to the variable first (the same hazard as the
  -- `e`/`g` record aliases noted below).
  for r in select ns.nspname from pg_namespace ns
           where ns.nspname !~ '^pg_' and ns.nspname <> 'information_schema'
           order by 1 loop
    if r.nspname <> 'public'
       and r.nspname not in ('auth','storage','realtime','graphql','graphql_public',
             'vault','extensions','supabase_functions','supabase_migrations','pgbouncer',
             'pgsodium','pgsodium_masks','net','cron','pgmq','dbdev','pgtle','repack',
             'tiger','tiger_data','topology','etl','_analytics','_realtime','_supavisor')
    then
      raise exception
        'PREFLIGHT: schema % is UNCLASSIFIED on this target - recovery must fail closed',
        r.nspname;
    end if;
  end loop;

  -- 9. the capture itself must carry no unclassified schema
  if exists (select 1 from _p2k_src_scope where classification like 'UNCLASSIFIED%') then
    raise exception 'PREFLIGHT: source capture contains an UNCLASSIFIED schema - fail closed';
  end if;

  raise notice 'preflight ok: % roles, % objects, % source edges, % default groups',
    (select count(*) from _p2k_src_role), (select count(*) from _p2k_src_own),
    (select count(*) from _p2k_src_edge), (select count(*) from _p2k_src_defgroup);
end
$preflight$;

-- ============================================================================
-- RESET and REPLAY
-- ============================================================================

do $recover$
declare
  e record; g record; brk record;
  passes int; moved int; remaining int;
  stmt text; gt text; objkw text; insch text;
  want aclitem[]; have aclitem[]; want_e text[]; have_e text[];
  n_reset int := 0; n_replay int := 0; n_trim int := 0; n_schema_grants int := 0;
  n_empty int := 0;
begin
  -- Provenance snapshot taken BEFORE any change, so the verification can prove
  -- that the only NULL-to-explicit drift it accepts was already present.
  create temp table _p2k_pre_state on commit drop as
    select cls, ident, state from _p2k_tgt_obj;

  -- The edge set the replay drives towards. For an object whose captured ACL
  -- is NULL, the target must end at the built-in default; the capture already
  -- expands that for relations and routines, but for types a NULL ACL emits no
  -- privilege rows, so the default edges are synthesized here.
  -- NOTE: aliases here are deliberately not `e`/`g`. Those are PL/pgSQL record
  -- variables in this block, and a qualified reference resolves to the variable
  -- rather than the table alias.
  create temp table _p2k_want_edge on commit drop as
    select se.cls, se.ident, se.sch, se.nm, se.rargs, se.col,
           (case when se.cls in ('relation','sequence','column')
                 then se.sch || '.' || se.nm else se.ident end) as fam,
           se.owner, se.grantee,
           se.grantor, se.priv, se.grantable, so.state as src_state
    from _p2k_src_edge se
    join _p2k_src_own so on so.cls = se.own_cls and so.ident = se.own_ident
    where se.cls <> 'type' or so.state = 'explicit'
    union all
    -- A type whose captured ACL is NULL emits no privilege rows (section I is
    -- explicit-only for row types), so its built-in default edges are
    -- synthesized here from the section E state.
    select 'type', so.ident, so.sch, so.nm, null::text, null::text, so.ident, so.owner,
           (case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end),
           pg_get_userbyid(a.grantor), a.privilege_type, a.is_grantable, so.state
    from _p2k_src_own so
    cross join lateral aclexplode(
      acldefault('T'::"char", (select oid from pg_roles where rolname = so.owner))) a
    where so.cls = 'type' and so.state = 'null';

  -- ------------------------------------------------------------------
  -- RESET: objects. Leaf-peeled across every class at once, because a
  -- grant chain lives on one object and never spans objects. Types carry
  -- chains exactly as relations do, so they are peeled the same way.
  -- ------------------------------------------------------------------
  passes := 0;
  loop
    passes := passes + 1; moved := 0;
    for e in
      select * from _p2k_tgt_edge x
      where x.cls <> 'schema'
        and not exists (
          -- An edge is a leaf when no OTHER edge in the same object family was
          -- granted BY its grantee. Excluding every row with the same grantee
          -- (the previous `y.grantee <> x.grantee`) made a self-grant invisible,
          -- so `owner -> X` and `X -> X` were both leaves and the revoke order
          -- decided whether the run aborted with "dependent privileges exist".
          -- The exclusion is now the identical row only.
          select 1 from _p2k_tgt_edge y
          where y.fam = x.fam and y.grantor = x.grantee
            and not (y.cls = x.cls and y.ident = x.ident
                     and y.col is not distinct from x.col
                     and y.grantee = x.grantee and y.grantor = x.grantor
                     and y.priv = x.priv and y.grantable = x.grantable)
            -- Two self-grants by the SAME role are not dependents of each other.
            -- Without this the owner's own aclitems (owner=.../owner) mutually
            -- blocked and the reset deadlocked with edges remaining.
            and not (x.grantor = x.grantee and y.grantor = y.grantee))
      order by x.cls, x.ident, x.col, x.grantee, x.grantor, x.priv
    loop
      gt := case when e.grantee = 'PUBLIC' then 'public' else quote_ident(e.grantee) end;
      stmt := case e.cls
        when 'relation' then format('revoke %s on table %I.%I from %s', e.priv, e.sch, e.nm, gt)
        when 'sequence' then format('revoke %s on sequence %I.%I from %s', e.priv, e.sch, e.nm, gt)
        when 'column'   then format('revoke %s (%I) on table %I.%I from %s', e.priv, e.col, e.sch, e.nm, gt)
        when 'routine'  then format('revoke %s on routine %I.%I(%s) from %s', e.priv, e.sch, e.nm, e.rargs, gt)
        when 'type'     then format('revoke %s on type %I.%I from %s', e.priv, e.sch, e.nm, gt)
      end;
      execute format('set local role %I', e.grantor);
      execute stmt;
      execute 'reset role';
      moved := moved + 1; n_reset := n_reset + 1;
    end loop;

    if moved = 0 then
      select count(*) into remaining from _p2k_tgt_edge where cls <> 'schema';
      exit when remaining = 0;
      -- No leaf and edges remain: a grantor cycle. Break it by revoking one
      -- grant option with CASCADE, issued as that edge's own grantor.
      select * into brk from _p2k_tgt_edge
        where cls <> 'schema' and grantable and grantee <> 'PUBLIC' limit 1;
      if brk.ident is null then
        raise exception 'RESET: no progress with % edges remaining and no grant option to break', remaining;
      end if;
      stmt := case brk.cls
        when 'relation' then format('revoke grant option for %s on table %I.%I from %I cascade', brk.priv, brk.sch, brk.nm, brk.grantee)
        when 'sequence' then format('revoke grant option for %s on sequence %I.%I from %I cascade', brk.priv, brk.sch, brk.nm, brk.grantee)
        when 'column'   then format('revoke grant option for %s (%I) on table %I.%I from %I cascade', brk.priv, brk.col, brk.sch, brk.nm, brk.grantee)
        when 'routine'  then format('revoke grant option for %s on routine %I.%I(%s) from %I cascade', brk.priv, brk.sch, brk.nm, brk.rargs, brk.grantee)
        when 'type'     then format('revoke grant option for %s on type %I.%I from %I cascade', brk.priv, brk.sch, brk.nm, brk.grantee)
      end;
      execute format('set local role %I', brk.grantor);
      execute stmt;
      execute 'reset role';
      moved := 1;
    end if;
    exit when passes > 200;
  end loop;
  -- The cap is a runaway guard, not an exit condition. Leaving it without an
  -- assertion would let a silently incomplete reset reach COMMIT.
  select count(*) into remaining from _p2k_tgt_edge where cls <> 'schema';
  if remaining <> 0 then
    raise exception 'RESET: pass cap reached with % edge(s) still present', remaining;
  end if;
  raise notice 'reset objects: % passes, % revokes', passes, n_reset;

  -- ------------------------------------------------------------------
  -- RESET: schema public, LAST, so USAGE survived every object operation
  -- ------------------------------------------------------------------
  passes := 0;
  loop
    passes := passes + 1; moved := 0;
    for e in
      select * from _p2k_tgt_edge x
      where x.cls = 'schema'
        and not exists (select 1 from _p2k_tgt_edge y where y.cls = 'schema'
                        and y.grantor = x.grantee
                        and not (y.grantee = x.grantee and y.grantor = x.grantor
                                 and y.priv = x.priv and y.grantable = x.grantable)
                        and not (x.grantor = x.grantee and y.grantor = y.grantee))
      order by x.grantee, x.grantor, x.priv
    loop
      gt := case when e.grantee = 'PUBLIC' then 'public' else quote_ident(e.grantee) end;
      execute format('set local role %I', e.grantor);
      execute format('revoke %s on schema %I from %s', e.priv, e.sch, gt);
      execute 'reset role';
      moved := moved + 1; n_reset := n_reset + 1;
    end loop;
    if moved = 0 then
      select count(*) into remaining from _p2k_tgt_edge where cls = 'schema';
      exit when remaining = 0;
      select * into brk from _p2k_tgt_edge
        where cls = 'schema' and grantable and grantee <> 'PUBLIC' limit 1;
      if brk.ident is null then
        raise exception 'RESET schema: no progress with % edges remaining', remaining;
      end if;
      execute format('set local role %I', brk.grantor);
      execute format('revoke grant option for %s on schema %I from %I cascade',
                     brk.priv, brk.sch, brk.grantee);
      execute 'reset role';
      moved := 1;
    end if;
    exit when passes > 200;
  end loop;
  select count(*) into remaining from _p2k_tgt_edge where cls = 'schema';
  if remaining <> 0 then
    raise exception 'RESET schema: pass cap reached with % edge(s) still present', remaining;
  end if;
  raise notice 'reset schema: % passes', passes;

  -- ------------------------------------------------------------------
  -- RESET: default-privilege rules, driven to their built-in baseline so
  -- PostgreSQL deletes the row.
  --   unscoped rule      -> acldefault(objtype, owner)
  --   IN SCHEMA <s> rule -> the empty ACL
  -- pg_default_acl spells sequences 'S'; acldefault() spells them 's' and
  -- uses 'S' for foreign servers, so the code is mapped before use.
  -- ------------------------------------------------------------------
  for g in select defowner, objtype, sch, acl from _p2k_tgt_defgroup loop
    objkw := case g.objtype when 'r' then 'TABLES' when 'S' then 'SEQUENCES'
                            when 'f' then 'FUNCTIONS' when 'T' then 'TYPES'
                            when 'n' then 'SCHEMAS' end;
    insch := case when g.sch = '' then '' else format(' in schema %I', g.sch) end;
    if g.sch = '' then
      want := acldefault(case g.objtype when 'S' then 's' else g.objtype::"char" end,
                         (select oid from pg_roles where rolname = g.defowner));
    else
      want := '{}'::aclitem[];
    end if;
    have := g.acl;
    if cardinality(have) > 0 then
      select coalesce(array_agg(x), '{}'::text[]) into have_e from (
        select (case when a.grantee = 0 then 'public'
                     else quote_ident(pg_get_userbyid(a.grantee)) end)
               || '|' || a.privilege_type || '|' || a.is_grantable as x
        from aclexplode(have) a) s;
    else
      have_e := '{}'::text[];
    end if;
    if cardinality(want) > 0 then
      select coalesce(array_agg(x), '{}'::text[]) into want_e from (
        select (case when a.grantee = 0 then 'public'
                     else quote_ident(pg_get_userbyid(a.grantee)) end)
               || '|' || a.privilege_type || '|' || a.is_grantable as x
        from aclexplode(want) a) s;
    else
      want_e := '{}'::text[];
    end if;
    execute format('set local role %I', g.defowner);
    for e in select unnest(have_e) as v loop
      execute format('alter default privileges for role %I%s revoke %s on %s from %s',
                     g.defowner, insch, split_part(e.v, '|', 2), objkw, split_part(e.v, '|', 1));
    end loop;
    for e in select unnest(want_e) as v loop
      execute format('alter default privileges for role %I%s grant %s on %s to %s%s',
                     g.defowner, insch, split_part(e.v, '|', 2), objkw, split_part(e.v, '|', 1),
                     case when split_part(e.v, '|', 3) = 'true' then ' with grant option' else '' end);
    end loop;
    execute 'reset role';
  end loop;
  if exists (select 1 from _p2k_tgt_defgroup) then
    raise exception 'RESET defaults: % rule row(s) survived the baseline reset',
      (select count(*) from _p2k_tgt_defgroup);
  end if;
  raise notice 'reset complete';

  -- ------------------------------------------------------------------
  -- REPLAY: schema public FIRST, restoring USAGE before any object grant
  -- ------------------------------------------------------------------
  passes := 0;
  loop
    passes := passes + 1; moved := 0;
    for e in
      select * from _p2k_want_edge s
      where s.cls = 'schema'
        and not exists (select 1 from _p2k_tgt_edge t where t.cls = 'schema'
              and t.grantee = s.grantee and t.grantor = s.grantor
              and t.priv = s.priv and t.grantable = s.grantable)
    loop
      -- Same "already at the built-in default" guard the object replay uses.
      -- Without it, a `public` whose nspacl is NULL on BOTH sides was granted
      -- its defaults explicitly and then rejected by this artifact's own
      -- provenance check - two identical databases could not be reconciled.
      if e.src_state = 'null' and exists (
           select 1 from _p2k_tgt_obj o
           where o.cls = 'schema' and o.ident = e.ident and o.state = 'null')
      then continue; end if;
      -- a non-owner grantor must already hold the privilege WITH GRANT OPTION
      if e.grantor <> e.owner and not exists (
           select 1 from _p2k_tgt_edge y where y.cls = 'schema'
             and y.grantee = e.grantor and y.priv = e.priv and y.grantable)
      then continue; end if;
      gt := case when e.grantee = 'PUBLIC' then 'public' else quote_ident(e.grantee) end;
      execute format('set local role %I', e.grantor);
      execute format('grant %s on schema %I to %s%s', e.priv, e.sch, gt,
                     case when e.grantable then ' with grant option' else '' end);
      execute 'reset role';
      moved := moved + 1; n_replay := n_replay + 1; n_schema_grants := n_schema_grants + 1;
    end loop;
    exit when moved = 0 or passes > 200;
  end loop;
  raise notice 'replay schema: % passes, % grants', passes, n_schema_grants;

  -- ------------------------------------------------------------------
  -- REPLAY: objects, dependency-ordered. An object whose captured ACL is
  -- NULL and whose target ACL is still NULL is left alone: it is already at
  -- the built-in default, and granting the default edges explicitly would
  -- create provenance drift for no security benefit.
  -- ------------------------------------------------------------------
  passes := 0;
  loop
    passes := passes + 1; moved := 0;
    for e in
      select * from _p2k_want_edge s
      where s.cls <> 'schema'
        and not exists (select 1 from _p2k_tgt_edge t
              where t.cls = s.cls and t.ident = s.ident
                and t.col is not distinct from s.col
                and t.grantee = s.grantee and t.grantor = s.grantor
                and t.priv = s.priv and t.grantable = s.grantable)
    loop
      if e.cls <> 'column' and e.src_state = 'null' and exists (
           select 1 from _p2k_tgt_obj o
           where o.cls = e.cls and o.ident = e.ident and o.state = 'null')
      then continue; end if;
      -- A non-owner grantor must already hold the privilege WITH GRANT OPTION.
      -- For a COLUMN edge that authority normally sits on the TABLE, not on the
      -- column, so requiring a column-level grantable edge made such a grant
      -- unreplayable forever (VERIFY then aborted the run).
      if e.grantor <> e.owner and not exists (
           select 1 from _p2k_tgt_edge y
           where y.fam = e.fam
             and y.grantee = e.grantor and y.priv = e.priv and y.grantable
             and (case when e.cls = 'column' then y.cls in ('relation','column')
                       else y.cls = e.cls and y.ident = e.ident
                            and y.col is not distinct from e.col end))
      then continue; end if;
      gt := case when e.grantee = 'PUBLIC' then 'public' else quote_ident(e.grantee) end;
      stmt := case e.cls
        when 'relation' then format('grant %s on table %I.%I to %s', e.priv, e.sch, e.nm, gt)
        when 'sequence' then format('grant %s on sequence %I.%I to %s', e.priv, e.sch, e.nm, gt)
        when 'column'   then format('grant %s (%I) on table %I.%I to %s', e.priv, e.col, e.sch, e.nm, gt)
        when 'routine'  then format('grant %s on routine %I.%I(%s) to %s', e.priv, e.sch, e.nm, e.rargs, gt)
        when 'type'     then format('grant %s on type %I.%I to %s', e.priv, e.sch, e.nm, gt)
      end;
      if e.grantable then stmt := stmt || ' with grant option'; end if;
      execute format('set local role %I', e.grantor);
      execute stmt;
      execute 'reset role';
      moved := moved + 1; n_replay := n_replay + 1;
    end loop;
    exit when moved = 0 or passes > 200;
  end loop;
  raise notice 'replay objects: % passes, % grants', passes, n_replay - n_schema_grants;

  -- ------------------------------------------------------------------
  -- TRIM: PostgreSQL materialises acldefault(kind, owner) into the catalogue on
  -- the FIRST grant against a NULL ACL, in addition to the edge being granted.
  -- Whenever the captured ACL is a strict subset of the built-in default -- the
  -- ordinary Supabase pattern of REVOKE EXECUTE ... FROM PUBLIC on a routine --
  -- the replay therefore leaves edges the capture does not contain, and the run
  -- aborted identically on every retry. Anything present on the target but not
  -- wanted is removed here, leaf-peeled like the reset.
  -- ------------------------------------------------------------------
  passes := 0;
  loop
    passes := passes + 1; moved := 0;
    for e in
      select * from _p2k_tgt_edge x
      where x.cls <> 'schema'
        and not exists (
          select 1 from _p2k_want_edge w
          where w.cls = x.cls and w.ident = x.ident
            and w.col is not distinct from x.col
            and w.grantee = x.grantee and w.grantor = x.grantor
            and w.priv = x.priv and w.grantable = x.grantable)
        and not exists (
          select 1 from _p2k_tgt_edge y
          where y.fam = x.fam and y.grantor = x.grantee
            and not (y.cls = x.cls and y.ident = x.ident
                     and y.col is not distinct from x.col
                     and y.grantee = x.grantee and y.grantor = x.grantor
                     and y.priv = x.priv and y.grantable = x.grantable)
            -- Two self-grants by the SAME role are not dependents of each other.
            -- Without this the owner's own aclitems (owner=.../owner) mutually
            -- blocked and the reset deadlocked with edges remaining.
            and not (x.grantor = x.grantee and y.grantor = y.grantee))
      order by x.cls, x.ident, x.col, x.grantee, x.grantor, x.priv
    loop
      gt := case when e.grantee = 'PUBLIC' then 'public' else quote_ident(e.grantee) end;
      stmt := case e.cls
        when 'relation' then format('revoke %s on table %I.%I from %s', e.priv, e.sch, e.nm, gt)
        when 'sequence' then format('revoke %s on sequence %I.%I from %s', e.priv, e.sch, e.nm, gt)
        when 'column'   then format('revoke %s (%I) on table %I.%I from %s', e.priv, e.col, e.sch, e.nm, gt)
        when 'routine'  then format('revoke %s on routine %I.%I(%s) from %s', e.priv, e.sch, e.nm, e.rargs, gt)
        when 'type'     then format('revoke %s on type %I.%I from %s', e.priv, e.sch, e.nm, gt)
      end;
      execute format('set local role %I', e.grantor);
      execute stmt;
      execute 'reset role';
      moved := moved + 1; n_trim := n_trim + 1;
    end loop;
    exit when moved = 0 or passes > 200;
  end loop;
  raise notice 'trim materialised defaults: % passes, % revokes', passes, n_trim;

  -- ------------------------------------------------------------------
  -- EMPTY ACLs. `{}` and NULL are different states: NULL means the built-in
  -- defaults apply, `{}` means nobody holds anything -- not even the owner.
  -- The replay has no edge to grant for an empty ACL, so an object captured as
  -- empty whose target still stores NULL could not be reached and verification
  -- refused. The ACL is forced into existence by granting one privilege to the
  -- owner and then revoking everything from the only two principals acldefault
  -- ever names. Ownership authority is unaffected: it is not an ACL right, so
  -- the owner can still ALTER and re-GRANT afterwards (verified).
  -- Schemas are handled separately, at the very end, because removing USAGE
  -- from `public` would break every object operation that follows.
  -- ------------------------------------------------------------------
  for e in select * from _p2k_src_own o
           where o.state = 'empty' and o.cls <> 'schema'
             and exists (select 1 from _p2k_tgt_obj t
                         where t.cls = o.cls and t.ident = o.ident and t.state = 'null')
           order by o.cls, o.ident
  loop
    execute format('set local role %I', e.owner);
    if e.cls = 'relation' then
      execute format('grant select on table %I.%I to %I', e.sch, e.nm, e.owner);
      execute format('revoke all on table %I.%I from %I, public', e.sch, e.nm, e.owner);
    elsif e.cls = 'sequence' then
      execute format('grant select on sequence %I.%I to %I', e.sch, e.nm, e.owner);
      execute format('revoke all on sequence %I.%I from %I, public', e.sch, e.nm, e.owner);
    elsif e.cls = 'routine' then
      execute format('grant execute on routine %I.%I(%s) to %I', e.sch, e.nm, e.rargs, e.owner);
      execute format('revoke all on routine %I.%I(%s) from %I, public', e.sch, e.nm, e.rargs, e.owner);
    elsif e.cls = 'type' then
      execute format('grant usage on type %I.%I to %I', e.sch, e.nm, e.owner);
      execute format('revoke all on type %I.%I from %I, public', e.sch, e.nm, e.owner);
    else
      raise exception 'REPLAY: cannot materialise an empty ACL for class % - fail closed', e.cls;
    end if;
    execute 'reset role';
    n_empty := n_empty + 1;
  end loop;

  -- ------------------------------------------------------------------
  -- REPLAY: default-privilege rules, driven to the exact captured ACL.
  -- A grant-only replay cannot reproduce a rule that is a strict SUBSET of
  -- the built-in default, so each group is moved in both directions:
  -- revoke (baseline \ source), then grant (source \ baseline).
  -- ------------------------------------------------------------------
  for g in select defowner, objtype, sch from _p2k_src_defgroup loop
    objkw := case g.objtype when 'r' then 'TABLES' when 'S' then 'SEQUENCES'
                            when 'f' then 'FUNCTIONS' when 'T' then 'TYPES'
                            when 'n' then 'SCHEMAS' end;
    insch := case when g.sch = '' then '' else format(' in schema %I', g.sch) end;
    if g.sch = '' then
      have := acldefault(case g.objtype when 'S' then 's' else g.objtype::"char" end,
                         (select oid from pg_roles where rolname = g.defowner));
    else
      have := '{}'::aclitem[];
    end if;
    if cardinality(have) > 0 then
      select coalesce(array_agg(x), '{}'::text[]) into have_e from (
        select (case when a.grantee = 0 then 'public'
                     else quote_ident(pg_get_userbyid(a.grantee)) end)
               || '|' || a.privilege_type || '|' || a.is_grantable as x
        from aclexplode(have) a) s;
    else
      have_e := '{}'::text[];
    end if;
    select coalesce(array_agg(x), '{}'::text[]) into want_e from (
      select (case when d.grantee = 'PUBLIC' then 'public' else quote_ident(d.grantee) end)
             || '|' || d.priv || '|' || d.grantable as x
      from _p2k_src_defedge d
      where d.defowner = g.defowner and d.objtype = g.objtype and d.sch = g.sch) s;
    execute format('set local role %I', g.defowner);
    for e in select v from (select unnest(have_e) as v) h
             where not exists (select 1 from (select unnest(want_e) as w) x
                               where split_part(x.w, '|', 1) = split_part(h.v, '|', 1)
                                 and split_part(x.w, '|', 2) = split_part(h.v, '|', 2)) loop
      execute format('alter default privileges for role %I%s revoke %s on %s from %s',
                     g.defowner, insch, split_part(e.v, '|', 2), objkw, split_part(e.v, '|', 1));
    end loop;
    for e in select v from (select unnest(want_e) as v) w
             where not exists (select 1 from (select unnest(have_e) as h) y where y.h = w.v) loop
      execute format('alter default privileges for role %I%s grant %s on %s to %s%s',
                     g.defowner, insch, split_part(e.v, '|', 2), objkw, split_part(e.v, '|', 1),
                     case when split_part(e.v, '|', 3) = 'true' then ' with grant option' else '' end);
    end loop;
    execute 'reset role';
  end loop;
  raise notice 'replay defaults complete';

  -- Schema-level empty ACL, LAST: this removes USAGE on `public` from everyone,
  -- so nothing that needs it may follow. ALTER DEFAULT PRIVILEGES ... IN SCHEMA
  -- does not require USAGE (verified), so the default phase above is unaffected.
  for e in select * from _p2k_src_own o
           where o.state = 'empty' and o.cls = 'schema'
             and exists (select 1 from _p2k_tgt_obj t
                         where t.cls = 'schema' and t.ident = o.ident and t.state = 'null')
  loop
    execute format('set local role %I', e.owner);
    execute format('grant usage on schema %I to %I', e.nm, e.owner);
    execute format('revoke all on schema %I from %I, public', e.nm, e.owner);
    execute 'reset role';
    n_empty := n_empty + 1;
  end loop;
  if n_empty > 0 then
    raise notice 'materialised % empty ACL(s)', n_empty;
  end if;
end
$recover$;

-- ============================================================================
-- VERIFY  — inside the transaction. Any failure rolls the whole run back.
-- ============================================================================

do $verify$
declare n int; r record;
begin
  -- 1. exact effective-security parity, including the grantor on every edge.
  --    An object that is at its built-in default on BOTH sides is left untouched
  --    by the replay and stores no ACL at all, so its synthesized default edges
  --    are not expected to appear in the target enumeration. This predicate
  --    mirrors the replay's skip rule exactly; columns are excluded from it
  --    because a NULL attacl means "no column grants", not "fall back to a
  --    default".
  select count(*) into n from (
    select w.cls, w.ident, w.col, w.owner, w.grantee, w.grantor, w.priv, w.grantable
    from _p2k_want_edge w
    where not (w.cls <> 'column' and w.src_state = 'null'
               and exists (select 1 from _p2k_tgt_obj o
                           where o.cls = w.cls and o.ident = w.ident
                             and o.state = 'null'))
    except
    select cls, ident, col, owner, grantee, grantor, priv, grantable from _p2k_tgt_edge) x;
  if n <> 0 then
    raise exception 'VERIFY: % captured edge(s) are missing from the target', n;
  end if;
  select count(*) into n from (
    select cls, ident, col, owner, grantee, grantor, priv, grantable from _p2k_tgt_edge
    except
    select cls, ident, col, owner, grantee, grantor, priv, grantable from _p2k_want_edge) x;
  if n <> 0 then
    raise exception 'VERIFY: % target-only edge(s) remain after the replay', n;
  end if;

  -- 2. exact default-rule parity, groups and edges
  select count(*) into n from (
    (select defowner, objtype, sch from _p2k_src_defgroup
     except select defowner, objtype, sch from _p2k_tgt_defgroup)
    union all
    (select defowner, objtype, sch from _p2k_tgt_defgroup
     except select defowner, objtype, sch from _p2k_src_defgroup)) x;
  if n <> 0 then raise exception 'VERIFY: % default-privilege group(s) differ', n; end if;
  select count(*) into n from (
    (select defowner, objtype, sch, grantee, priv, grantable from _p2k_src_defedge
     except select defowner, objtype, sch, grantee, priv, grantable from _p2k_tgt_defedge)
    union all
    (select defowner, objtype, sch, grantee, priv, grantable from _p2k_tgt_defedge
     except select defowner, objtype, sch, grantee, priv, grantable from _p2k_src_defedge)) x;
  if n <> 0 then raise exception 'VERIFY: % default-privilege edge(s) differ', n; end if;

  -- 2b. Re-check the object inventory. Preflight ran once, at the start, and the
  --     transaction is READ COMMITTED with no lock on schema `public`, so an
  --     object created concurrently AFTER preflight would have had its whole ACL
  --     stripped by the reset and would be invisible to checks 1 and 3-4 (they
  --     inner-join the capture). Without this the run committed reporting
  --     success while an unrelated table was left with no privileges at all.
  select count(*) into n from _p2k_tgt_obj t
    where not exists (select 1 from _p2k_src_own s
                      where s.cls = t.cls and s.ident = t.ident);
  if n <> 0 then
    raise exception
      'VERIFY: % in-scope object(s) are not described by the capture; they appeared after preflight and their privileges were reset - rolling back',
      n;
  end if;

  -- 3. ownership unchanged
  select count(*) into n from _p2k_src_own s
    join _p2k_tgt_obj t on t.cls = s.cls and t.ident = s.ident
    where t.owner <> s.owner;
  if n <> 0 then raise exception 'VERIFY: ownership changed on % object(s)', n; end if;

  -- 4. provenance: the ONLY permitted difference is an object whose captured
  --    ACL is NULL now holding an explicit ACL byte-equal to its built-in
  --    default, AND which already held an explicit ACL before this run.
  --    PostgreSQL cannot restore a NULL ACL, so that residual is unavoidable;
  --    anything else is a real divergence.
  for r in
    select s.cls, s.ident, s.state as src_state, t.state as tgt_state,
           p.state as pre_state
    from _p2k_src_own s
    join _p2k_tgt_obj t on t.cls = s.cls and t.ident = s.ident
    join _p2k_pre_state p on p.cls = s.cls and p.ident = s.ident
    where s.state <> t.state
  loop
    if not (r.src_state = 'null' and r.tgt_state = 'explicit') then
      raise exception
        'VERIFY: % has provenance state % but the capture says %; only NULL-to-explicit is approved',
        r.ident, r.tgt_state, r.src_state;
    end if;
    if r.pre_state = 'null' then
      raise exception
        'VERIFY: % was NULL before this run and is explicit after it; the recovery must not create provenance drift',
        r.ident;
    end if;
  end loop;
  select count(*) into n from _p2k_src_own s
    join _p2k_tgt_obj t on t.cls = s.cls and t.ident = s.ident
    where s.state <> t.state;
  if n > @@EXPECT_RESIDUAL@@ then
    raise exception
      'VERIFY: % object(s) show a provenance residual, more than the % the capture permits',
      n, @@EXPECT_RESIDUAL@@;
  end if;

  raise notice 'verify ok: % edges, % default rules, % approved provenance residual',
    (select count(*) from _p2k_tgt_edge),
    (select count(*) from _p2k_tgt_defedge), n;
end
$verify$;

drop view _p2k_tgt_defedge;
drop view _p2k_tgt_defgroup;
drop view _p2k_tgt_obj;
drop view _p2k_tgt_edge;

commit;
