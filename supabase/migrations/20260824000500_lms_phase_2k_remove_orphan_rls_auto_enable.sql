-- Phase 2K: remove the legacy ensure_rls event trigger and its
-- rls_auto_enable() function. RLS remains explicit in each reviewed
-- table-creation migration.
begin;

do $$
declare function_oid oid:=to_regprocedure('public.rls_auto_enable()');
declare function_row record;
declare trigger_row record;
declare trigger_count integer;
declare dependants text;
begin
  -- Absence is the desired state and makes this migration safe to re-run.
  if function_oid is null then
    if exists(select 1 from pg_event_trigger where evtname='ensure_rls') then
      raise exception 'Phase 2K refuses to remove an unexpected ensure_rls event trigger';
    end if;
    return;
  end if;

  select p.prorettype='pg_catalog.event_trigger'::regtype as returns_event_trigger,
         p.prosecdef,
         role.rolname as owner,
         p.proconfig,
         p.prosrc
  into function_row
  from pg_proc p
  join pg_roles role on role.oid=p.proowner
  where p.oid=function_oid;

  if not function_row.returns_event_trigger
    or not function_row.prosecdef
    or function_row.owner<>'postgres'
    or function_row.proconfig is distinct from array['search_path=pg_catalog']::text[]
    or position('pg_event_trigger_ddl_commands()' in function_row.prosrc)=0
    or position('enable row level security' in lower(function_row.prosrc))=0
    or position('cmd.schema_name IN (''public'')' in function_row.prosrc)=0 then
    raise exception 'Phase 2K refuses to remove an unexpected rls_auto_enable() definition';
  end if;

  select count(*)
  into trigger_count
  from pg_event_trigger
  where evtfoid=function_oid;

  select evtname,evtevent,evtenabled,evttags
  into trigger_row
  from pg_event_trigger
  where evtfoid=function_oid
    and evtname='ensure_rls';

  if trigger_count<>1
    or trigger_row.evtname is null
    or trigger_row.evtevent<>'ddl_command_end'
    or trigger_row.evtenabled<>'O'
    or cardinality(trigger_row.evttags)<>3
    or not trigger_row.evttags @> array['CREATE TABLE','CREATE TABLE AS','SELECT INTO']::text[] then
    raise exception 'Phase 2K refuses to remove an unexpected rls_auto_enable() event-trigger registration';
  end if;

  execute 'drop event trigger ensure_rls';

  select string_agg(format('%s:%s',dep.classid::regclass,dep.objid),', ' order by dep.classid::regclass::text,dep.objid)
  into dependants
  from pg_depend dep
  where dep.refclassid='pg_proc'::regclass
    and dep.refobjid=function_oid;
  if dependants is not null then
    raise exception 'Phase 2K refuses to remove rls_auto_enable(): dependent objects exist: %',dependants;
  end if;

  execute 'revoke all on function public.rls_auto_enable() from public,anon,authenticated';
  execute 'drop function public.rls_auto_enable()';
end $$;

do $$
begin
  if exists(select 1 from pg_event_trigger where evtname='ensure_rls') then
    raise exception 'Phase 2K did not remove event trigger ensure_rls';
  end if;
  if to_regprocedure('public.rls_auto_enable()') is not null then
    raise exception 'Phase 2K did not remove public.rls_auto_enable()';
  end if;
end $$;

commit;
