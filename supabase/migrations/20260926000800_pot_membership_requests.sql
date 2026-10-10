-- Account access is independent of pot membership. Existing pots stay private.
begin;
alter table public.pots add column is_discoverable boolean not null default false;

create table public.pot_join_requests (
  pot_id uuid not null references public.pots(id) on delete cascade,
  player_id uuid not null references public.profiles(id),
  status text not null check (status in ('pending','accepted','declined')),
  version integer not null default 1 check (version > 0),
  requested_at timestamptz not null default clock_timestamp(),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id),
  primary key (pot_id,player_id),
  check ((status='pending' and decided_at is null and decided_by is null)
    or (status<>'pending' and decided_at is not null and decided_by is not null))
);
create index pot_join_requests_player_idx on public.pot_join_requests(player_id,pot_id);
create table public.pot_membership_events (
  id uuid primary key default gen_random_uuid(),
  pot_id uuid not null,
  player_id uuid,
  actor_id uuid not null references public.profiles(id),
  action text not null check(action in ('requested','accepted','declined','assigned','discovery_changed')),
  before_state jsonb,
  after_state jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
create index pot_membership_events_pot_idx on public.pot_membership_events(pot_id,created_at);
alter table public.pot_join_requests enable row level security;
alter table public.pot_membership_events enable row level security;
revoke all on public.pot_join_requests, public.pot_membership_events from public,anon,authenticated;
grant select on public.pot_join_requests, public.pot_membership_events to authenticated;
create policy join_requests_read on public.pot_join_requests for select to authenticated
  using (player_id=(select auth.uid()) or (select public.is_current_user_admin()));
create policy membership_events_admin_read on public.pot_membership_events for select to authenticated
  using ((select public.is_current_user_admin()));
create function public.prevent_membership_event_change() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Membership audit events are append-only'; end $$;
revoke all on function public.prevent_membership_event_change() from public,anon,authenticated;
create trigger membership_events_append_only before update or delete on public.pot_membership_events
  for each row execute function public.prevent_membership_event_change();

-- Internal eligibility projection. A missing first deadline is not permission to join.
create function public.lms_pot_accepts_members(selected_pot_id uuid) returns boolean
language sql security definer set search_path='' as $$
 select coalesce((select p.status in ('draft','open') and p.lifecycle_status in ('setup','open')
   and p.membership_locked_at is null and p.review_status='none' and not p.test_mode
   and (select min(g.pick_deadline_at) from public.pot_gameweeks g where g.pot_id=p.id)>clock_timestamp()
 from public.pots p where p.id=selected_pot_id),false)
$$;
revoke all on function public.lms_pot_accepts_members(uuid) from public,anon,authenticated;

create function public.set_pot_discoverable(selected_pot_id uuid, discoverable boolean) returns void
language plpgsql security definer set search_path='' as $$
declare p public.pots%rowtype;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 if discoverable is null then raise exception 'Choose whether requests are open'; end if;
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),-2);
 select * into p from public.pots where id=selected_pot_id for update;
 if not found then raise exception 'Pot not found'; end if;
 if discoverable and (p.status<>'open' or not public.lms_pot_accepts_members(p.id)) then
   raise exception 'Open a non-test pot with a future first deadline before enabling requests'; end if;
 if p.is_discoverable=discoverable then return; end if;
 update public.pots set is_discoverable=discoverable where id=p.id;
 insert into public.pot_membership_events(pot_id,actor_id,action,before_state,after_state)
 values(p.id,auth.uid(),'discovery_changed',jsonb_build_object('is_discoverable',p.is_discoverable),jsonb_build_object('is_discoverable',discoverable));
end $$;

create function public.get_available_pots() returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'season',p.season,
 'entry_fee_pence',p.entry_fee_pence,'buy_back_fee_pence',p.buy_back_fee_pence,
 'deadline',(select min(g.pick_deadline_at) from public.pot_gameweeks g where g.pot_id=p.id),
 'request_status',r.status,'state',case
 when not (p.is_discoverable and p.status='open' and public.lms_pot_accepts_members(p.id)) then 'unavailable'
 when r.status='pending' then 'pending' when r.status='declined' then 'declined' else 'available' end)
 order by p.created_at desc),'[]'::jsonb)
 from public.pots p left join public.pot_join_requests r on r.pot_id=p.id and r.player_id=(select auth.uid())
 where (select auth.uid()) is not null and not exists(select 1 from public.pot_players m where m.pot_id=p.id and m.player_id=(select auth.uid()))
 and ((p.is_discoverable and p.status='open' and public.lms_pot_accepts_members(p.id)) or r.player_id is not null)
$$;

create function public.request_pot_membership(selected_pot_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p public.pots%rowtype; r public.pot_join_requests%rowtype; previous jsonb; actor uuid:=(select auth.uid());
begin
 if actor is null or not exists(select 1 from public.profiles where id=actor) then raise exception 'Registered account required'; end if;
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),-2);
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),0);
 select * into p from public.pots where id=selected_pot_id for update;
 if exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=actor) then return jsonb_build_object('state','member'); end if;
 if p.id is null or not p.is_discoverable or p.status<>'open' or not public.lms_pot_accepts_members(p.id) then raise exception 'This pot is not available for requests'; end if;
 select * into r from public.pot_join_requests where pot_id=p.id and player_id=actor for update;
 if r.status='pending' then return jsonb_build_object('state','pending','version',r.version); end if;
 previous:=case when r.pot_id is null then null else to_jsonb(r) end;
 insert into public.pot_join_requests(pot_id,player_id,status) values(p.id,actor,'pending')
 on conflict(pot_id,player_id) do update set status='pending',version=pot_join_requests.version+1,
 requested_at=clock_timestamp(),decided_at=null,decided_by=null returning * into r;
 insert into public.pot_membership_events(pot_id,player_id,actor_id,action,before_state,after_state)
 values(p.id,actor,actor,'requested',previous,to_jsonb(r));
 return jsonb_build_object('state','pending','version',r.version);
end $$;

-- Keep the existing membership rules and use its unique (pot,player) key.
-- Lock order matches processing/deletion: schedule lock, membership lock, pot row.
alter function public.add_player_to_pot(uuid,uuid) rename to add_player_to_pot_before_requests;
revoke all on function public.add_player_to_pot_before_requests(uuid,uuid) from public,anon,authenticated;
create function public.add_player_to_pot(selected_pot_id uuid,selected_player_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare existed boolean; r public.pot_join_requests%rowtype; previous jsonb;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),-2);
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),0);
 perform 1 from public.pots where id=selected_pot_id for update;
 existed:=exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=selected_player_id);
 if not existed then
   -- Recheck wall-clock eligibility after waiting for locks. The original RPC
   -- uses transaction time; retain its draft/no-fixture and test-pot support.
   if exists(select 1 from public.pots p where p.id=selected_pot_id and
     (p.status not in ('draft','open') or p.review_status<>'none' or exists(
       select 1 from public.pot_gameweeks g where g.pot_id=p.id and g.pick_deadline_at<=clock_timestamp()))) then
     raise exception 'Membership is locked for this pot';
   end if;
   perform public.add_player_to_pot_before_requests(selected_pot_id,selected_player_id);
   insert into public.pot_membership_events(pot_id,player_id,actor_id,action,after_state)
   values(selected_pot_id,selected_player_id,auth.uid(),'assigned',jsonb_build_object('membership','active'));
 end if;
 select * into r from public.pot_join_requests where pot_id=selected_pot_id and player_id=selected_player_id for update;
 if r.status='pending' then
   previous:=to_jsonb(r);
   update public.pot_join_requests set status='accepted',version=version+1,decided_at=clock_timestamp(),decided_by=auth.uid()
   where pot_id=selected_pot_id and player_id=selected_player_id returning * into r;
   insert into public.pot_membership_events(pot_id,player_id,actor_id,action,before_state,after_state)
   values(selected_pot_id,selected_player_id,auth.uid(),'accepted',previous,to_jsonb(r));
 end if;
end $$;

create function public.decide_pot_membership(selected_pot_id uuid,selected_player_id uuid,expected_version integer,accept_request boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.pot_join_requests%rowtype; previous jsonb; decision text; p public.pots%rowtype;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 if accept_request is null or expected_version is null then raise exception 'A request decision and version are required'; end if;
 decision:=case when accept_request then 'accepted' else 'declined' end;
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),-2);
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),0);
 select * into p from public.pots where id=selected_pot_id for update;
 select * into r from public.pot_join_requests where pot_id=selected_pot_id and player_id=selected_player_id for update;
 if not found then raise exception 'Request not found'; end if;
 if r.status=decision and r.version=expected_version+1 then return jsonb_build_object('state',r.status,'version',r.version); end if;
 if r.status<>'pending' or r.version<>expected_version then raise exception 'Request state changed; refresh and try again'; end if;
 if accept_request then
   if not exists(select 1 from public.pot_players where pot_id=p.id and player_id=selected_player_id)
     and (not p.is_discoverable or p.status<>'open' or not public.lms_pot_accepts_members(p.id)) then raise exception 'This pot is no longer available for joining'; end if;
   perform public.add_player_to_pot(p.id,selected_player_id);
 else
   previous:=to_jsonb(r);
   update public.pot_join_requests set status='declined',version=version+1,decided_at=clock_timestamp(),decided_by=auth.uid()
   where pot_id=p.id and player_id=selected_player_id returning * into r;
   insert into public.pot_membership_events(pot_id,player_id,actor_id,action,before_state,after_state)
   values(p.id,selected_player_id,auth.uid(),'declined',previous,to_jsonb(r));
 end if;
 select * into r from public.pot_join_requests where pot_id=p.id and player_id=selected_player_id;
 return jsonb_build_object('state',r.status,'version',r.version);
end $$;

create function public.get_pot_join_requests(selected_pot_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 return (select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('name',public.lms_player_display_name(p.first_name,p.last_name,p.display_name,p.email),'email',p.email) order by r.requested_at),'[]')
 from public.pot_join_requests r join public.profiles p on p.id=r.player_id where r.pot_id=selected_pot_id and r.status='pending');
end $$;

create function public.get_admin_player_memberships(selected_player_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 return jsonb_build_object(
 'memberships',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('name',p.name,'season',p.season,'pot_status',p.status,'buy_back_fee_pence',p.buy_back_fee_pence) order by p.created_at desc)
 from public.pot_players m join public.pots p on p.id=m.pot_id where m.player_id=selected_player_id),'[]'),
 'requests',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('name',p.name) order by r.requested_at desc)
 from public.pot_join_requests r join public.pots p on p.id=r.pot_id where r.player_id=selected_player_id),'[]'),
 'assignable_pots',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'season',p.season) order by p.created_at desc)
 from public.pots p where p.status in('draft','open') and p.lifecycle_status in('setup','open') and p.membership_locked_at is null and p.review_status='none'
 and not exists(select 1 from public.pot_gameweeks g where g.pot_id=p.id and g.pick_deadline_at<=clock_timestamp())
 and not exists(select 1 from public.pot_players m where m.pot_id=p.id and m.player_id=selected_player_id)),'[]'));
end $$;

revoke all on function public.set_pot_discoverable(uuid,boolean),public.get_available_pots(),public.request_pot_membership(uuid),public.add_player_to_pot(uuid,uuid),public.decide_pot_membership(uuid,uuid,integer,boolean),public.get_pot_join_requests(uuid),public.get_admin_player_memberships(uuid) from public,anon;
grant execute on function public.set_pot_discoverable(uuid,boolean),public.get_available_pots(),public.request_pot_membership(uuid),public.add_player_to_pot(uuid,uuid),public.decide_pot_membership(uuid,uuid,integer,boolean),public.get_pot_join_requests(uuid),public.get_admin_player_memberships(uuid) to authenticated;
commit;
