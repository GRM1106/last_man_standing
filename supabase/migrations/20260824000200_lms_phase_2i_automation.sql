-- Phase 2I: locally callable, idempotent competition automation foundation.
begin;
do $$ begin if to_regclass('public.lms_review_cases') is null then raise exception 'Phase 2I requires Phase 2H';end if;if to_regclass('public.lms_automation_runs') is not null then raise exception 'Phase 2I already installed';end if;end $$;
create table public.lms_automation_runs(
 id uuid primary key default gen_random_uuid(),operation_key text not null,attempt integer not null check(attempt>0),job_type text not null check(job_type in('pot_automation','global_scan')),pot_id uuid references public.pots(id),round_id uuid references public.pot_rounds(id),gameweek_number integer check(gameweek_number between 1 and 38),status text not null check(status in('running','succeeded','blocked','failed','skipped')),source text not null check(source in('system','admin')),actor_id uuid references public.profiles(id),started_at timestamptz not null default clock_timestamp(),finished_at timestamptz,result_summary jsonb not null default '{}',error_class text check(error_class in('waiting','review','retryable','invariant')),safe_error text,unique(operation_key,attempt)
);
create index lms_automation_runs_recent on public.lms_automation_runs(pot_id,started_at desc);
alter table public.lms_automation_runs enable row level security;
revoke all on public.lms_automation_runs from public,anon,authenticated;
grant select on public.lms_automation_runs to authenticated;
create policy "Admins see automation runs" on public.lms_automation_runs for select to authenticated using((select public.is_current_user_admin()));
create or replace function public.prevent_automation_run_mutation() returns trigger language plpgsql set search_path='' as $$ begin if tg_op='UPDATE' and old.status='running' and new.status in('succeeded','blocked','failed','skipped') then return new;end if;if tg_op='DELETE' and exists(select 1 from public.pots where id=old.pot_id and status='draft' and test_mode) then return old;end if;raise exception 'Automation run history is append-only';end $$;
create trigger lms_automation_runs_append_only before update or delete on public.lms_automation_runs for each row execute function public.prevent_automation_run_mutation();revoke all on function public.prevent_automation_run_mutation() from public,anon,authenticated;

create or replace function public.run_lms_pot_automation_internal(selected_pot_id uuid,run_source text,run_actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare selected_round public.pot_rounds%rowtype;deadline timestamptz;operation text;attempt_no integer;run_id uuid;assignment jsonb;readiness jsonb;processed jsonb;summary jsonb;final_status text:='succeeded';error_kind text;
begin
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),-9);
 select r.* into selected_round from public.pot_rounds r where r.pot_id=selected_pot_id and not exists(select 1 from public.pot_gameweek_processes x where x.round_id=r.id) order by r.sequence_number limit 1;
 if not found then
  operation:='pot:'||selected_pot_id||':complete';select coalesce(max(attempt),0)+1 into attempt_no from public.lms_automation_runs where operation_key=operation;
  insert into public.lms_automation_runs(operation_key,attempt,job_type,pot_id,status,source,actor_id,finished_at,result_summary,error_class,safe_error) values(operation,attempt_no,'pot_automation',selected_pot_id,'skipped',run_source,run_actor,clock_timestamp(),jsonb_build_object('state','complete_or_no_current_round'),'waiting','No current LMS round') returning id into run_id;
  return jsonb_build_object('run_id',run_id,'status','skipped','state','complete_or_no_current_round');
 end if;
 operation:='pot:'||selected_pot_id||':round:'||selected_round.id;select coalesce(max(attempt),0)+1 into attempt_no from public.lms_automation_runs where operation_key=operation;
 insert into public.lms_automation_runs(operation_key,attempt,job_type,pot_id,round_id,gameweek_number,status,source,actor_id) values(operation,attempt_no,'pot_automation',selected_pot_id,selected_round.id,selected_round.gameweek_number,'running',run_source,run_actor) returning id into run_id;
 if exists(select 1 from public.lms_review_cases where pot_id=selected_pot_id and status='open') then final_status:='blocked';error_kind:='review';summary:=jsonb_build_object('state','blocked_by_review');
 else
  select pick_deadline_at into deadline from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_round.gameweek_number;
  if deadline is null then final_status:='blocked';error_kind:='invariant';summary:=jsonb_build_object('state','deadline_missing');perform public.open_lms_review_case(selected_pot_id,'progression_failure','Automation cannot continue because the permanent round deadline is missing',selected_round.id,null,null,null,'{}','system');
  elsif now()<deadline and not (select test_mode from public.pots where id=selected_pot_id) then final_status:='skipped';error_kind:='waiting';summary:=jsonb_build_object('state','waiting_for_deadline','deadline',deadline);
  else
   update public.pots set lifecycle_status='in_progress',membership_locked_at=coalesce(membership_locked_at,case when selected_round.sequence_number=1 then deadline end) where id=selected_pot_id and lifecycle_status in('setup','open');
   assignment:=public.assign_random_missing_picks(selected_pot_id,selected_round.gameweek_number,false);
   if coalesce((assignment->>'missing')::integer,0)>0 and coalesce((assignment->>'ready')::boolean,false) then assignment:=public.assign_random_missing_picks(selected_pot_id,selected_round.gameweek_number,true);
   elsif coalesce((assignment->>'missing')::integer,0)>0 and (assignment->'problems') ? 'No eligible unstarted fixture remains for random assignment.' then final_status:='blocked';error_kind:='review';perform public.open_lms_review_case(selected_pot_id,'progression_failure','No safe random pick candidate exists for a missing entrant',selected_round.id,null,null,null,jsonb_build_object('assignment',assignment),'system');end if;
   if final_status<>'blocked' then begin readiness:=public.process_pot_gameweek(selected_pot_id,selected_round.gameweek_number,false);exception when others then if sqlerrm ilike '%not final%' then readiness:=jsonb_build_object('ready',false,'problems',jsonb_build_array('Fixture results are not final yet.'));else raise;end if;end;
    if coalesce((readiness->>'ready')::boolean,false) then begin processed:=public.process_pot_gameweek(selected_pot_id,selected_round.gameweek_number,true);summary:=jsonb_build_object('state',case when selected_round.gameweek_number=38 then 'complete' else 'processed' end,'assignment',assignment,'processing',processed);exception when others then if sqlerrm ilike '%not final%' then final_status:='skipped';error_kind:='waiting';summary:=jsonb_build_object('state','waiting_for_results','assignment',assignment);else raise;end if;end;
    else final_status:='skipped';error_kind:='waiting';summary:=jsonb_build_object('state','waiting_for_results','assignment',assignment,'readiness',readiness);end if;
   else summary:=jsonb_build_object('state','blocked_no_safe_pick','assignment',assignment);end if;
  end if;
 end if;
 update public.lms_automation_runs set status=final_status,finished_at=clock_timestamp(),result_summary=coalesce(summary,'{}'),error_class=error_kind,safe_error=case error_kind when 'review' then 'Governed review blocks automation' when 'invariant' then 'Competition invariant requires review' when 'waiting' then 'Operation is not due or results are unfinished' end where id=run_id;
 return coalesce(summary,'{}')||jsonb_build_object('run_id',run_id,'status',final_status,'attempt',attempt_no);
exception when others then
 if run_id is not null then update public.lms_automation_runs set status='failed',finished_at=clock_timestamp(),error_class='invariant',safe_error='Automation stopped on an internal invariant',result_summary=jsonb_build_object('sqlstate',sqlstate) where id=run_id;end if;raise;
end $$;revoke all on function public.run_lms_pot_automation_internal(uuid,text,uuid) from public,anon,authenticated;

create or replace function public.run_lms_pot_automation(selected_pot_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$ begin if not (select public.is_current_user_admin()) then raise exception 'Administrator access required';end if;return public.run_lms_pot_automation_internal(selected_pot_id,'admin',(select auth.uid()));end $$;
revoke all on function public.run_lms_pot_automation(uuid) from public,anon;grant execute on function public.run_lms_pot_automation(uuid) to authenticated;
create or replace function public.scan_lms_automation() returns jsonb language plpgsql security definer set search_path='' as $$ declare p record;results jsonb:='[]';item jsonb;begin if not (select public.is_current_user_admin()) then raise exception 'Administrator access required';end if;for p in select id from public.pots where lifecycle_status not in('complete') order by created_at loop begin item:=public.run_lms_pot_automation_internal(p.id,'admin',(select auth.uid()));exception when others then item:=jsonb_build_object('status','failed','pot_id',p.id,'safe_error','Pot automation failed independently');end;results:=results||jsonb_build_array(item||jsonb_build_object('pot_id',p.id));end loop;return results;end $$;
revoke all on function public.scan_lms_automation() from public,anon;grant execute on function public.scan_lms_automation() to authenticated;

create or replace function public.get_lms_automation_status(selected_pot_id uuid) returns jsonb language sql stable security definer set search_path='' as $$ select case when (select public.is_current_user_admin()) then jsonb_build_object('current_gameweek',public.current_pot_gameweek(selected_pot_id),'deadline',(select pick_deadline_at from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=public.current_pot_gameweek(selected_pot_id)),'blocked_by_review',exists(select 1 from public.lms_review_cases where pot_id=selected_pot_id and status='open'),'last_run',(select jsonb_build_object('status',status,'started_at',started_at,'finished_at',finished_at,'result',result_summary,'safe_error',safe_error) from public.lms_automation_runs where pot_id=selected_pot_id order by started_at desc limit 1)) else null end $$;
revoke all on function public.get_lms_automation_status(uuid) from public,anon;grant execute on function public.get_lms_automation_status(uuid) to authenticated;

alter function public.reset_draft_test_pot(uuid) rename to reset_draft_test_pot_phase2h_base;revoke all on function public.reset_draft_test_pot_phase2h_base(uuid) from public,anon,authenticated;
create or replace function public.reset_draft_test_pot(selected_pot_id uuid) returns void language plpgsql security definer set search_path='' as $$ begin if not (select public.is_current_user_admin()) then raise exception 'Administrator access required';end if;if not exists(select 1 from public.pots where id=selected_pot_id and status='draft' and test_mode) then raise exception 'Only a draft pot in test mode can be reset';end if;delete from public.lms_automation_runs where pot_id=selected_pot_id;perform public.reset_draft_test_pot_phase2h_base(selected_pot_id);end $$;
revoke all on function public.reset_draft_test_pot(uuid) from public,anon;grant execute on function public.reset_draft_test_pot(uuid) to authenticated;
commit;
