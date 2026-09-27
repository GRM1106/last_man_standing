-- Also the reviewed, idempotent pre-upgrade bootstrap on the first-22 baseline.
-- Replaying it in migration order preserves the switch and its audit history.
begin;
create schema if not exists lms_maintenance authorization postgres;
revoke all on schema lms_maintenance from public,anon,authenticated,service_role;
create table if not exists lms_maintenance.state (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  changed_at timestamptz not null default clock_timestamp()
);
create table if not exists lms_maintenance.events (
  id bigint generated always as identity primary key,
  enabled boolean not null,
  changed_at timestamptz not null default clock_timestamp(),
  operator text not null,
  reason text not null check (length(trim(reason)) between 1 and 500)
);
insert into lms_maintenance.state(singleton) values(true) on conflict do nothing;
revoke all on all tables in schema lms_maintenance from public,anon,authenticated,service_role;
revoke all on all sequences in schema lms_maintenance from public,anon,authenticated,service_role;

create or replace function lms_maintenance.is_operator() returns boolean
language sql stable security definer set search_path=pg_catalog as $$
  select (session_user='postgres' or
    (session_user like 'cli_login_%' and pg_has_role(session_user,'postgres','MEMBER')))
    and coalesce(current_setting('role',true),'none') in ('none','postgres')
    and coalesce(current_setting('request.jwt.claims',true),'') in ('','{}')
    and coalesce(current_setting('request.jwt.claim.role',true),'')=''
    and coalesce(current_setting('request.jwt.claim.sub',true),'')=''
$$;

create or replace function lms_maintenance.guard_write() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
declare frozen boolean;
begin
  if lms_maintenance.is_operator() then return null; end if;
  -- Shared transaction lock lasts until commit/rollback. Enabling takes the
  -- exclusive counterpart and therefore drains all writes admitted while OFF.
  perform pg_advisory_xact_lock_shared(761394820527001::bigint);
  -- A locking read sees the current row, or raises a serialization failure for
  -- an old repeatable-read snapshot. A stale snapshot must never allow a write.
  select enabled into frozen from lms_maintenance.state where singleton for share;
  if frozen is distinct from false then
    raise exception using errcode='P0001', message='LMS_MAINTENANCE: Last Man Standing is temporarily unavailable. Please check back shortly.';
  end if;
  return null;
end $$;

create or replace function lms_maintenance.set_enabled(requested boolean, change_reason text)
returns boolean language plpgsql security definer set search_path=pg_catalog set lock_timeout='10s' as $$
begin
  if not lms_maintenance.is_operator() then raise exception 'Maintenance switching requires a direct operator connection'; end if;
  if requested is null or change_reason is null or length(trim(change_reason)) not between 1 and 500 then
    raise exception 'Maintenance requires an explicit state and a short reason';
  end if;
  perform pg_advisory_xact_lock(761394820527001::bigint);
  update lms_maintenance.state set enabled=requested,changed_at=clock_timestamp() where singleton;
  if not found then raise exception 'Maintenance state missing; refuse switch'; end if;
  insert into lms_maintenance.events(enabled,operator,reason) values(requested,session_user,trim(change_reason));
  return requested;
end $$;

create or replace function public.get_lms_maintenance() returns jsonb
language sql stable security definer set search_path=pg_catalog as $$
  select jsonb_build_object('enabled',coalesce((select enabled from lms_maintenance.state where singleton),true))
$$;
revoke all on function public.get_lms_maintenance() from public,anon,authenticated,service_role;
grant execute on function public.get_lms_maintenance() to anon,authenticated,service_role;

create or replace function lms_maintenance.install_guards() returns void
language plpgsql security definer set search_path=pg_catalog as $$
declare t record;
begin
  for t in select c.oid,n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('r','p')
  loop
    if not exists(select 1 from pg_trigger where tgrelid=t.oid and tgname='lms_maintenance_write_guard'
      and tgfoid='lms_maintenance.guard_write()'::regprocedure) then
      execute format('create trigger lms_maintenance_write_guard before insert or update or delete or truncate on %I.%I for each statement execute function lms_maintenance.guard_write()',t.nspname,t.relname);
    end if;
    if exists(select 1 from pg_trigger where tgrelid=t.oid and tgname='lms_maintenance_write_guard' and tgenabled<>'A') then
      execute format('alter table %I.%I enable always trigger lms_maintenance_write_guard',t.nspname,t.relname);
    end if;
  end loop;
end $$;
create or replace function lms_maintenance.guard_new_tables() returns event_trigger
language plpgsql security definer set search_path=pg_catalog as $$
begin perform lms_maintenance.install_guards(); end $$;
do $$ begin
  if not exists(select 1 from pg_event_trigger where evtname='lms_maintenance_new_tables') then
    create event trigger lms_maintenance_new_tables on ddl_command_end
      when tag in ('CREATE TABLE','CREATE TABLE AS','SELECT INTO','ALTER TABLE')
      execute function lms_maintenance.guard_new_tables();
  end if;
end $$;
select lms_maintenance.install_guards();
-- Auth writes remain managed by Supabase. Block creation before any profile
-- trigger, in the same transaction: no orphan/new partially created account.
create or replace trigger lms_maintenance_signup_guard before insert on auth.users
  for each statement execute function lms_maintenance.guard_write();
-- Do not ALTER the platform-owned Auth table. Auth connections cannot select
-- replica mode; the normal INSERT trigger is sufficient for managed signup.
revoke all on all functions in schema lms_maintenance from public,anon,authenticated,service_role;
-- Application callers cannot create unguarded relations or alter the guards.
revoke create on schema public from public,anon,authenticated,service_role;
commit;
