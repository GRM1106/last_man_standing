-- Phase 2H: governed review cases, version-safe previews and append-only adjudication.
begin;
do $$ begin if to_regclass('public.pot_completions') is null then raise exception 'Phase 2H requires Phase 2G'; end if; if to_regclass('public.lms_review_cases') is not null then raise exception 'Phase 2H already installed'; end if; end $$;

create table public.lms_review_cases(
 id uuid primary key default gen_random_uuid(),pot_id uuid not null references public.pots(id),source_round_id uuid references public.pot_rounds(id),fixture_id bigint references public.football_fixtures(id),pick_id bigint references public.player_picks(id),player_id uuid references public.profiles(id),
 case_type text not null check(case_type in('fixture_result_correction','fixture_context_change','exceptional_status_reversal','late_buyback_revocation','downstream_result_correction','completed_pot_correction','progression_failure','migration_review')),
 status text not null default 'open' check(status in('open','resolved','dismissed')),summary text not null check(char_length(trim(summary)) between 5 and 500),evidence jsonb not null default '{}',impact_snapshot jsonb not null default '{}',opened_by uuid references public.profiles(id),opened_source text not null check(opened_source in('system','admin','migration')),opened_at timestamptz not null default now(),version integer not null default 1 check(version>0),resolved_at timestamptz,unique nulls not distinct(pot_id,case_type,fixture_id,player_id,status)
);
create table public.lms_review_resolution_events(
 id uuid primary key default gen_random_uuid(),case_id uuid not null references public.lms_review_cases(id),event_type text not null check(event_type in('resolved','dismissed')),action text not null check(action in('confirm_existing','set_player_active','set_player_eliminated','revise_winners','close_without_change')),reason text not null check(char_length(trim(reason)) between 10 and 1000),actor_id uuid not null references public.profiles(id),before_state jsonb not null,after_state jsonb not null,created_at timestamptz not null default now(),unique(case_id,event_type)
);
create table public.pot_completion_adjudications(
 id uuid primary key default gen_random_uuid(),pot_id uuid not null references public.pot_completions(pot_id),case_id uuid not null unique references public.lms_review_cases(id),original_total_prize_pence integer not null,revision_number integer not null check(revision_number>0),reason text not null,created_by uuid not null references public.profiles(id),created_at timestamptz not null default now(),unique(pot_id,revision_number)
);
create table public.pot_adjudicated_winners(
 adjudication_id uuid not null references public.pot_completion_adjudications(id),player_id uuid not null references public.profiles(id),prize_share_pence integer not null check(prize_share_pence>=0),share_order integer not null check(share_order>0),primary key(adjudication_id,player_id),unique(adjudication_id,share_order)
);
alter table public.lms_review_cases enable row level security;alter table public.lms_review_resolution_events enable row level security;alter table public.pot_completion_adjudications enable row level security;alter table public.pot_adjudicated_winners enable row level security;
revoke all on public.lms_review_cases,public.lms_review_resolution_events,public.pot_completion_adjudications,public.pot_adjudicated_winners from public,anon,authenticated;
grant select on public.lms_review_cases,public.lms_review_resolution_events,public.pot_completion_adjudications,public.pot_adjudicated_winners to authenticated;
create policy "Members see review summaries" on public.lms_review_cases for select to authenticated using(exists(select 1 from public.pot_players m where m.pot_id=lms_review_cases.pot_id and m.player_id=(select auth.uid())) or (select public.is_current_user_admin()));
create policy "Admins see review decisions" on public.lms_review_resolution_events for select to authenticated using((select public.is_current_user_admin()));
create policy "Members see completion adjudications" on public.pot_completion_adjudications for select to authenticated using(exists(select 1 from public.pot_players m where m.pot_id=pot_completion_adjudications.pot_id and m.player_id=(select auth.uid())) or (select public.is_current_user_admin()));
create policy "Members see adjudicated winners" on public.pot_adjudicated_winners for select to authenticated using(exists(select 1 from public.pot_completion_adjudications a join public.pot_players m on m.pot_id=a.pot_id where a.id=pot_adjudicated_winners.adjudication_id and m.player_id=(select auth.uid())) or (select public.is_current_user_admin()));

create or replace function public.open_lms_review_case(selected_pot_id uuid,selected_case_type text,selected_summary text,selected_round_id uuid default null,selected_fixture_id bigint default null,selected_pick_id bigint default null,selected_player_id uuid default null,selected_evidence jsonb default '{}',selected_source text default 'system') returns uuid language plpgsql security definer set search_path='' as $$
declare created_id uuid;impact jsonb;
begin
 if selected_source='admin' and not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 select jsonb_build_object('later_rounds',(select count(*) from public.pot_rounds r where r.pot_id=selected_pot_id and (selected_round_id is null or r.sequence_number>(select sequence_number from public.pot_rounds where id=selected_round_id))),'later_picks',(select count(*) from public.player_picks p where p.pot_id=selected_pot_id and (selected_round_id is null or p.gameweek_number>(select gameweek_number from public.pot_rounds where id=selected_round_id))),'completed',exists(select 1 from public.pot_completions where pot_id=selected_pot_id)) into impact;
 insert into public.lms_review_cases(pot_id,source_round_id,fixture_id,pick_id,player_id,case_type,summary,evidence,impact_snapshot,opened_by,opened_source)
 values(selected_pot_id,selected_round_id,selected_fixture_id,selected_pick_id,selected_player_id,selected_case_type,trim(selected_summary),selected_evidence,impact,case when selected_source='system' then null else (select auth.uid()) end,selected_source)
 on conflict(pot_id,case_type,fixture_id,player_id,status) do update set evidence=lms_review_cases.evidence||excluded.evidence,impact_snapshot=excluded.impact_snapshot,version=lms_review_cases.version+1 returning id into created_id;
 perform set_config('lms.review_case_opening','1',true);
 update public.pots set lifecycle_status='review',review_status='needs_review',review_reason=trim(selected_summary),review_status_changed_at=now() where id=selected_pot_id;
 perform set_config('lms.review_case_opening','0',true);
 return created_id;
end $$;
revoke all on function public.open_lms_review_case(uuid,text,text,uuid,bigint,bigint,uuid,jsonb,text) from public,anon,authenticated;

create or replace function public.capture_pot_review_flag() returns trigger language plpgsql security definer set search_path='' as $$
declare kind text;
begin
 if new.review_status='needs_review' and old.review_status is distinct from new.review_status and coalesce(current_setting('lms.review_case_opening',true),'0')<>'1' then
  kind:=case when new.review_reason ilike '%buy-back%' then 'late_buyback_revocation' when new.review_reason ilike '%fixture%changed gameweek or participants%' then 'fixture_context_change' when new.review_reason ilike '%fixture correction%' then case when new.status='complete' then 'completed_pot_correction' else 'downstream_result_correction' end when new.review_reason ilike '%collective reinstatement%' then 'progression_failure' else 'migration_review' end;
  perform public.open_lms_review_case(new.id,kind,coalesce(new.review_reason,'Pot entered governed review'),null,null,null,null,jsonb_build_object('pot_flag_source',true),'system');
 end if;return new;
end $$;
create trigger pots_capture_governed_review after update of review_status on public.pots for each row execute function public.capture_pot_review_flag();
revoke all on function public.capture_pot_review_flag() from public,anon,authenticated;

create or replace function public.capture_exceptional_status_reversal() returns trigger language plpgsql security definer set search_path='' as $$
declare affected record;
begin
 if old.status in('postponed','abandoned','void') and new.status not in('postponed','abandoned','void') then
  for affected in select distinct p.pot_id,p.round_id,p.id pick_id,p.player_id from public.player_picks p where p.fixture_id=new.id and p.exceptional_resolution_type='auto_win' loop
   perform public.open_lms_review_case(affected.pot_id,'exceptional_status_reversal','Provider status reversed after an exceptional automatic win',affected.round_id,new.id,affected.pick_id,affected.player_id,jsonb_build_object('old_status',old.status,'new_status',new.status,'exceptional_resolution_preserved',true),'system');
  end loop;
 end if;return new;
end $$;
create trigger football_fixtures_capture_exceptional_reversal after update of status on public.football_fixtures for each row execute function public.capture_exceptional_status_reversal();
revoke all on function public.capture_exceptional_status_reversal() from public,anon,authenticated;

insert into public.lms_review_cases(pot_id,case_type,status,summary,evidence,impact_snapshot,opened_source,opened_at)
select id,'migration_review','open',coalesce(nullif(trim(review_reason),''),'Existing review flag requires adjudication'),jsonb_build_object('backfill',true,'actor_provenance','unknown'),'{}','migration',coalesce(review_status_changed_at,created_at) from public.pots where review_status='needs_review';

create or replace function public.preview_lms_review_resolution(selected_case_id uuid,selected_action text,selected_player_ids uuid[] default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.lms_review_cases%rowtype;token text;original jsonb;total integer;count_w integer;
begin if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;select * into c from public.lms_review_cases where id=selected_case_id;if not found then raise exception 'Review case not found';end if;
 token:=md5(c.id::text||':'||c.version||':'||c.status||':'||(select count(*) from public.lms_review_cases where pot_id=c.pot_id and status='open')||':'||coalesce((select completed_at::text from public.pot_completions where pot_id=c.pot_id),'none'));
 select coalesce(jsonb_agg(jsonb_build_object('player_id',player_id,'share',prize_share_pence) order by share_order),'[]') into original from public.pot_winners where pot_id=c.pot_id;select total_prize_pence into total from public.pot_completions where pot_id=c.pot_id;count_w:=coalesce(cardinality(selected_player_ids),0);
 return jsonb_build_object('case_id',c.id,'status',c.status,'version_token',token,'action',selected_action,'affected_round',c.source_round_id,'player_id',c.player_id,'impact',c.impact_snapshot,'original_winners',original,'proposed_winner_count',count_w,'prize_total',total,'pot_after',case when (select count(*) from public.lms_review_cases where pot_id=c.pot_id and status='open')>1 then 'review' when exists(select 1 from public.pot_completions where pot_id=c.pot_id) then 'complete' else 'in_progress' end);
end $$;revoke all on function public.preview_lms_review_resolution(uuid,text,uuid[]) from public,anon;grant execute on function public.preview_lms_review_resolution(uuid,text,uuid[]) to authenticated;

create or replace function public.resolve_lms_review_case(selected_case_id uuid,selected_action text,resolution_reason text,expected_version_token text,selected_player_ids uuid[] default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.lms_review_cases%rowtype;preview jsonb;before_json jsonb;after_json jsonb;adjudication uuid;total integer;base integer;remainder integer;remaining integer;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required';end if;if nullif(trim(resolution_reason),'') is null or char_length(trim(resolution_reason))<10 then raise exception 'A meaningful resolution reason is required';end if;
 select * into c from public.lms_review_cases where id=selected_case_id for update;if not found then raise exception 'Review case not found';end if;if c.status<>'open' then return jsonb_build_object('resolved',true,'already_resolved',true);end if;
 preview:=public.preview_lms_review_resolution(selected_case_id,selected_action,selected_player_ids);if preview->>'version_token'<>expected_version_token then raise exception 'Review state changed; preview again.';end if;
 before_json:=jsonb_build_object('pot',(select to_jsonb(p) from public.pots p where id=c.pot_id),'case',to_jsonb(c),'original_completion',(select to_jsonb(x) from public.pot_completions x where pot_id=c.pot_id));
 if selected_action='set_player_active' then update public.pot_players set player_status='active' where pot_id=c.pot_id and player_id=coalesce(c.player_id,selected_player_ids[1]);
 elsif selected_action='set_player_eliminated' then update public.pot_players set player_status='eliminated' where pot_id=c.pot_id and player_id=coalesce(c.player_id,selected_player_ids[1]);
 elsif selected_action='revise_winners' then
  if not exists(select 1 from public.pot_completions where pot_id=c.pot_id) or cardinality(selected_player_ids)<1 then raise exception 'A completed pot and at least one winner are required';end if;
  select total_prize_pence into total from public.pot_completions where pot_id=c.pot_id;base:=total/cardinality(selected_player_ids);remainder:=total%cardinality(selected_player_ids);
  insert into public.pot_completion_adjudications(pot_id,case_id,original_total_prize_pence,revision_number,reason,created_by) values(c.pot_id,c.id,total,(select count(*)+1 from public.pot_completion_adjudications where pot_id=c.pot_id),trim(resolution_reason),(select auth.uid())) returning id into adjudication;
  insert into public.pot_adjudicated_winners(adjudication_id,player_id,prize_share_pence,share_order) select adjudication,x.player_id,base+case when x.ord<=remainder then 1 else 0 end,x.ord from(select u player_id,row_number() over(order by m.joined_at,u)::integer ord from unnest(selected_player_ids) u join public.pot_players m on m.pot_id=c.pot_id and m.player_id=u)x;
 elsif selected_action not in('confirm_existing','close_without_change') then raise exception 'Unsupported governed action';end if;
 update public.lms_review_cases set status=case when selected_action='close_without_change' then 'dismissed' else 'resolved' end,resolved_at=now(),version=version+1 where id=c.id;
 select count(*) into remaining from public.lms_review_cases where pot_id=c.pot_id and status='open';
 update public.pots set lifecycle_status=case when remaining>0 then 'review' when exists(select 1 from public.pot_completions where pot_id=c.pot_id) then 'complete' else 'in_progress' end,review_status=case when remaining>0 then 'needs_review' else 'reviewed' end,review_reason=case when remaining>0 then (select summary from public.lms_review_cases where pot_id=c.pot_id and status='open' order by opened_at limit 1) else null end,review_status_changed_at=now() where id=c.pot_id;
 after_json:=jsonb_build_object('pot',(select to_jsonb(p) from public.pots p where id=c.pot_id),'adjudication_id',adjudication,'preview',preview);
 insert into public.lms_review_resolution_events(case_id,event_type,action,reason,actor_id,before_state,after_state) values(c.id,case when selected_action='close_without_change' then 'dismissed' else 'resolved' end,selected_action,trim(resolution_reason),(select auth.uid()),before_json,after_json);
 return jsonb_build_object('resolved',true,'remaining_open_cases',remaining,'adjudication_id',adjudication);
end $$;revoke all on function public.resolve_lms_review_case(uuid,text,text,text,uuid[]) from public,anon;grant execute on function public.resolve_lms_review_case(uuid,text,text,text,uuid[]) to authenticated;

create or replace function public.prevent_review_history_mutation() returns trigger language plpgsql set search_path='' as $$ begin raise exception 'Review adjudication history is append-only';end $$;
create trigger review_resolution_events_immutable before update or delete on public.lms_review_resolution_events for each row execute function public.prevent_review_history_mutation();
create trigger completion_adjudications_immutable before update or delete on public.pot_completion_adjudications for each row execute function public.prevent_review_history_mutation();
create trigger adjudicated_winners_immutable before update or delete on public.pot_adjudicated_winners for each row execute function public.prevent_review_history_mutation();
revoke all on function public.prevent_review_history_mutation() from public,anon,authenticated;

create or replace function public.get_my_pot_review_state(selected_pot_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
select case when exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid())) or (select public.is_current_user_admin()) then jsonb_build_object('under_review',exists(select 1 from public.lms_review_cases where pot_id=selected_pot_id and status='open'),'open_count',(select count(*) from public.lms_review_cases where pot_id=selected_pot_id and status='open'),'cases',case when (select public.is_current_user_admin()) then coalesce((select jsonb_agg(jsonb_build_object('id',id,'type',case_type,'status',status,'summary',summary,'opened_at',opened_at,'round_id',source_round_id,'fixture_id',fixture_id,'player_id',player_id,'evidence',evidence,'impact',impact_snapshot) order by opened_at) from public.lms_review_cases where pot_id=selected_pot_id),'[]') else '[]'::jsonb end) else null end;
$$;revoke all on function public.get_my_pot_review_state(uuid) from public,anon;grant execute on function public.get_my_pot_review_state(uuid) to authenticated;

commit;
