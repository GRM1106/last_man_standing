-- Phase 2D: auditable fixture selection blocks and pick-local exceptional auto-wins.
begin;
do $$ begin if to_regclass('public.pot_player_team_cycles') is null then raise exception 'Phase 2D requires Phase 2C'; end if;
 if to_regclass('public.fixture_selection_block_events') is not null then raise exception 'Phase 2D already installed'; end if; end $$;

create table public.fixture_selection_block_events(
 id uuid primary key default gen_random_uuid(), fixture_id bigint not null references public.football_fixtures(id),
 blocked boolean not null, reason text not null check(char_length(trim(reason)) between 5 and 500),
 created_by uuid not null references public.profiles(id), created_at timestamptz not null default now()
);
create index fixture_selection_block_events_latest on public.fixture_selection_block_events(fixture_id,created_at desc,id desc);
alter table public.fixture_selection_block_events enable row level security;
revoke all on public.fixture_selection_block_events from public,anon,authenticated;

create or replace function public.fixture_is_selection_blocked(selected_fixture_id bigint) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce((select blocked from public.fixture_selection_block_events where fixture_id=selected_fixture_id order by created_at desc,id desc limit 1),false);
$$;
revoke all on function public.fixture_is_selection_blocked(bigint) from public,anon,authenticated;

create or replace function public.set_fixture_selection_block(selected_fixture_id bigint,blocked boolean,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare created public.fixture_selection_block_events%rowtype;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 if nullif(trim(reason),'') is null or char_length(trim(reason))<5 then raise exception 'A meaningful reason is required'; end if;
 if not exists(select 1 from public.football_fixtures where id=selected_fixture_id) then raise exception 'Fixture not found'; end if;
 insert into public.fixture_selection_block_events(fixture_id,blocked,reason,created_by)
 values(selected_fixture_id,blocked,trim(reason),(select auth.uid())) returning * into created;
 insert into public.admin_audit_events(administrator_id,action,target_type,target_identifier,before_state,after_state,reason)
 values((select auth.uid()),case when blocked then 'fixture_selection_blocked' else 'fixture_selection_unblocked' end,
  'football_fixture',selected_fixture_id::text,null,jsonb_build_object('blocked',blocked,'event_id',created.id),trim(reason));
 return jsonb_build_object('fixture_id',selected_fixture_id,'blocked',blocked,'reason',created.reason,'created_at',created.created_at);
end $$;
revoke all on function public.set_fixture_selection_block(bigint,boolean,text) from public,anon;
grant execute on function public.set_fixture_selection_block(bigint,boolean,text) to authenticated;

alter table public.player_picks add column selected_fixture_status text;
alter table public.player_picks add column selected_provider_observed_at timestamptz;
alter table public.player_picks add column selected_while_blocked boolean not null default false;
alter table public.player_picks add column selection_eligible boolean not null default false;
alter table public.player_picks add column exceptional_resolution_type text;
alter table public.player_picks add column exceptional_fixture_status text;
alter table public.player_picks add column exceptional_resolved_at timestamptz;
alter table public.player_picks add constraint player_picks_selected_status_check check(selected_fixture_status is null or selected_fixture_status in('scheduled','live','finished','postponed','abandoned','void'));
alter table public.player_picks add constraint player_picks_exceptional_check check(
 (exceptional_resolution_type is null and exceptional_fixture_status is null and exceptional_resolved_at is null)
 or (exceptional_resolution_type='auto_win' and exceptional_fixture_status in('postponed','abandoned','void') and exceptional_resolved_at is not null));

create or replace function public.capture_pick_fixture_eligibility() returns trigger language plpgsql security definer set search_path='' as $$
declare fixture public.football_fixtures%rowtype; declare blocked boolean;
begin
 select * into fixture from public.football_fixtures where id=new.fixture_id for share;
 if not found then raise exception 'Fixture not found'; end if;
 blocked:=public.fixture_is_selection_blocked(fixture.id);
 if blocked then raise exception 'That fixture is temporarily unavailable for selection'; end if;
 if fixture.status in('postponed','abandoned','void') then raise exception 'That fixture is unavailable for selection'; end if;
 new.selected_fixture_status:=fixture.status; new.selected_provider_observed_at:=fixture.provider_synced_at;
 new.selected_while_blocked:=false; new.selection_eligible:=true; return new;
end $$;
create trigger player_picks_capture_fixture_eligibility before insert on public.player_picks
for each row execute function public.capture_pick_fixture_eligibility();
revoke all on function public.capture_pick_fixture_eligibility() from public,anon,authenticated;

create or replace function public.resolve_fixture_exceptional_picks() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status in('postponed','abandoned','void') and old.status is distinct from new.status then
  update public.player_picks set exceptional_resolution_type='auto_win',exceptional_fixture_status=new.status,
   exceptional_resolved_at=coalesce(new.provider_synced_at,now())
  where fixture_id=new.id and selection_eligible and not selected_while_blocked and exceptional_resolution_type is null
   and confirmed_at<=coalesce(new.provider_synced_at,now()) and resolved_at is null;
 end if; return new;
end $$;
create trigger football_fixtures_resolve_exceptional_picks after update of status on public.football_fixtures
for each row execute function public.resolve_fixture_exceptional_picks();
revoke all on function public.resolve_fixture_exceptional_picks() from public,anon,authenticated;

create or replace function public.prevent_exceptional_resolution_change() returns trigger language plpgsql set search_path='' as $$
begin
 if old.exceptional_resolution_type is not null and (new.exceptional_resolution_type is distinct from old.exceptional_resolution_type
  or new.exceptional_fixture_status is distinct from old.exceptional_fixture_status or new.exceptional_resolved_at is distinct from old.exceptional_resolved_at)
 then raise exception 'Exceptional pick resolution is immutable'; end if; return new;
end $$;
create trigger player_picks_exceptional_resolution_immutable before update on public.player_picks
for each row execute function public.prevent_exceptional_resolution_change();
revoke all on function public.prevent_exceptional_resolution_change() from public,anon,authenticated;

do $$ declare d text; original text; begin
 d:=pg_get_functiondef('public.assign_random_missing_picks(uuid,integer,boolean)'::regprocedure); original:=d;
 d:=replace(d,'and NOT fixture.started AND NOT fixture.finished','and NOT fixture.started AND NOT fixture.finished AND fixture.status NOT IN (''postponed'',''abandoned'',''void'') AND NOT public.fixture_is_selection_blocked(fixture.id)');
 d:=replace(d,'and not fixture.started and not fixture.finished','and not fixture.started and not fixture.finished and fixture.status not in(''postponed'',''abandoned'',''void'') and not public.fixture_is_selection_blocked(fixture.id)');
 if d=original then raise exception 'Unexpected random assignment baseline'; end if; execute d;

 d:=pg_get_functiondef('public.process_pot_gameweek_p2_base(uuid,integer,boolean)'::regprocedure); original:=d;
 d:=replace(d,'ELSE effective.processable END','ELSE (effective.processable OR pick.exceptional_resolution_type=''auto_win'') END');
 d:=replace(d,'else effective.processable end','else (effective.processable or pick.exceptional_resolution_type=''auto_win'') end');
 d:=replace(d,'WHEN NOT effective.processable THEN ''pending''','WHEN pick.exceptional_resolution_type=''auto_win'' THEN ''won'' WHEN NOT effective.processable THEN ''pending''');
 d:=replace(d,'when not effective.processable then ''pending''','when pick.exceptional_resolution_type=''auto_win'' then ''won'' when not effective.processable then ''pending''');
 d:=replace(d,'ELSE effective.result_source END','ELSE case when pick.exceptional_resolution_type=''auto_win'' then pick.exceptional_fixture_status else effective.result_source end END');
 d:=replace(d,'else effective.result_source end','else case when pick.exceptional_resolution_type=''auto_win'' then pick.exceptional_fixture_status else effective.result_source end end');
 d:=replace(d,'locked_result.status <> ''finished''::text OR locked_result.home_score IS NULL OR locked_result.away_score IS NULL','locked_result.status NOT IN (''finished'',''postponed'',''abandoned'',''void'') OR (locked_result.status=''finished'' AND (locked_result.home_score IS NULL OR locked_result.away_score IS NULL))');
 d:=replace(d,'locked_result.status<>''finished'' or locked_result.home_score is null or locked_result.away_score is null','locked_result.status not in(''finished'',''postponed'',''abandoned'',''void'') or (locked_result.status=''finished'' and (locked_result.home_score is null or locked_result.away_score is null))');
 if d=original or position('exceptional_resolution_type' in d)=0 then raise exception 'Unexpected processing baseline'; end if; execute d;
end $$;

commit;
