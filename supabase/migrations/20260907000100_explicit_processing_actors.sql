-- Critical #1: audit identities are not authentication accounts.
-- Requires the complete baseline through 20260824001000. No sporting rules change.
begin;
-- Serialize provisioning and provider claims with the backfill/trigger installation.
lock table public.profiles,public.lms_provider_runs in share row exclusive mode;

do $$ begin
  if to_regprocedure('public.lms_revised_winner_projection(uuid,uuid[])') is null then
    raise exception 'Processing actors require the complete Phase 2K baseline';
  end if;
  if exists(select 1 from public.lms_provider_runs where status='running') then
    raise exception 'Pause and drain provider runs before installing processing actors';
  end if;
  if exists(select 1 from public.profiles where id='00000000-0000-0000-0000-000000000001') then
    raise exception 'Reserved system actor ID collides with an existing profile';
  end if;
end $$;

create table public.lms_audit_actors (
  id uuid primary key,
  actor_type text not null check(actor_type in ('human','system')),
  profile_id uuid unique references public.profiles(id) on delete cascade,
  system_name text unique,
  check((actor_type='human' and profile_id is not null and id=profile_id and system_name is null)
    or (actor_type='system' and profile_id is null and system_name='lms-scheduler'
      and id='00000000-0000-0000-0000-000000000001'))
);
insert into public.lms_audit_actors(id,actor_type,profile_id)
select id,'human',id from public.profiles;
insert into public.lms_audit_actors(id,actor_type,system_name)
values('00000000-0000-0000-0000-000000000001','system','lms-scheduler');
alter table public.lms_audit_actors enable row level security;
revoke all on public.lms_audit_actors from public,anon,authenticated;
grant select on public.lms_audit_actors to authenticated;
create policy "Administrators see audit actors" on public.lms_audit_actors
for select to authenticated using((select public.is_current_user_admin()));

create function public.register_profile_audit_actor() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  insert into public.lms_audit_actors(id,actor_type,profile_id) values(new.id,'human',new.id);
  return new;
end $$;
revoke all on function public.register_profile_audit_actor() from public,anon,authenticated;
create trigger profiles_register_audit_actor after insert on public.profiles
for each row execute function public.register_profile_audit_actor();

-- Existing IDs retain exactly their original human meaning. NOT NULL stays in place.
alter table public.pot_gameweek_processes drop constraint pot_gameweek_processes_processed_by_fkey;
alter table public.pot_gameweek_processes add foreign key(processed_by) references public.lms_audit_actors(id);
alter table public.pot_completions drop constraint pot_completions_completed_by_fkey;
alter table public.pot_completions add foreign key(completed_by) references public.lms_audit_actors(id);
alter table public.lms_automation_runs drop constraint lms_automation_runs_actor_id_fkey;
alter table public.lms_automation_runs add foreign key(actor_id) references public.lms_audit_actors(id);
-- Historical provider rows had no attribution: leave them unknown, never invent it.
alter table public.lms_provider_runs add column actor_id uuid references public.lms_audit_actors(id);

create function public.current_lms_audit_actor() returns uuid
language plpgsql stable security definer set search_path='' as $$
declare actor uuid; human uuid := (select auth.uid());
begin
  if human is not null then
    if not exists(select 1 from public.profiles where id=human and is_admin) then
      raise exception 'An authenticated administrator is required for human processing';
    end if;
    return human;
  end if;
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'An authenticated administrator or service actor is required';
  end if;
  actor:=coalesce(nullif(current_setting('lms.audit_actor_id',true),'')::uuid,
    '00000000-0000-0000-0000-000000000001'::uuid);
  if not exists(select 1 from public.lms_audit_actors where id=actor) then
    raise exception 'Unknown processing actor';
  end if;
  return actor;
end $$;
revoke all on function public.current_lms_audit_actor() from public,anon,authenticated;

-- Enforce attribution where records are written, including all existing processing
-- wrappers. SQL operator fixtures may supply an explicit registered actor, as before.
create function public.attribute_lms_processing() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='pot_gameweek_processes' then
    new.processed_by:=coalesce(new.processed_by,public.current_lms_audit_actor());
  elsif tg_table_name='pot_completions' then
    new.completed_by:=coalesce(new.completed_by,public.current_lms_audit_actor());
  else
    new.actor_id:=coalesce(new.actor_id,public.current_lms_audit_actor());
  end if;
  return new;
end $$;
revoke all on function public.attribute_lms_processing() from public,anon,authenticated;
create trigger pot_processes_attribute_actor before insert on public.pot_gameweek_processes
for each row execute function public.attribute_lms_processing();
create trigger pot_completions_attribute_actor before insert on public.pot_completions
for each row execute function public.attribute_lms_processing();
create trigger pot_automation_attribute_actor before insert on public.lms_automation_runs
for each row execute function public.attribute_lms_processing();
create trigger provider_runs_attribute_actor before insert on public.lms_provider_runs
for each row execute function public.attribute_lms_processing();

create function public.preserve_provider_actor() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.actor_id is distinct from old.actor_id then raise exception 'Provider attribution is immutable'; end if;
  return new;
end $$;
revoke all on function public.preserve_provider_actor() from public,anon,authenticated;
create trigger provider_runs_preserve_actor before update on public.lms_provider_runs
for each row execute function public.preserve_provider_actor();

-- The Edge Function verifies the JWT, then passes its verified user ID here.
-- Browsers cannot call this service-only adapter or choose a different actor.
create function public.claim_lms_provider_run_for_admin(run_source text,administrator_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; previous text:=current_setting('lms.audit_actor_id',true);
begin
  if (select auth.role()) is distinct from 'service_role' then raise exception 'Service role required'; end if;
  if run_source is null or run_source not in('admin','local_simulation') then raise exception 'Invalid admin run source'; end if;
  if not exists(select 1 from public.profiles where id=administrator_id and is_admin) then
    raise exception 'Verified administrator required';
  end if;
  perform set_config('lms.audit_actor_id',administrator_id::text,true);
  result:=public.claim_lms_provider_run(run_source);
  perform set_config('lms.audit_actor_id',coalesce(previous,''),true);
  return result;
end $$;
revoke all on function public.claim_lms_provider_run_for_admin(text,uuid) from public,anon,authenticated;
grant execute on function public.claim_lms_provider_run_for_admin(text,uuid) to service_role;

-- Resume the actor recorded at claim time, even on a different pooled connection.
alter function public.complete_lms_provider_run(uuid,text,jsonb,jsonb)
rename to complete_lms_provider_run_before_actors;
revoke all on function public.complete_lms_provider_run_before_actors(uuid,text,jsonb,jsonb)
from public,anon,authenticated,service_role;
create function public.complete_lms_provider_run(run_id uuid,selected_season text,fpl_teams jsonb,fpl_fixtures jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid; result jsonb; previous text:=current_setting('lms.audit_actor_id',true);
begin
  if (select auth.role()) is distinct from 'service_role' then raise exception 'Service role required'; end if;
  select r.actor_id into actor from public.lms_provider_runs r where r.id=run_id and r.status='running' for update;
  if not found or actor is null then raise exception 'Provider run has no active attributed claim'; end if;
  perform set_config('lms.audit_actor_id',actor::text,true);
  result:=public.complete_lms_provider_run_before_actors(run_id,selected_season,fpl_teams,fpl_fixtures);
  perform set_config('lms.audit_actor_id',coalesce(previous,''),true);
  return result;
end $$;
revoke all on function public.complete_lms_provider_run(uuid,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.complete_lms_provider_run(uuid,text,jsonb,jsonb) to service_role;
comment on table public.lms_audit_actors is 'Human IDs retain their profile UUID; the system actor is not an auth user and cannot sign in.';
commit;
