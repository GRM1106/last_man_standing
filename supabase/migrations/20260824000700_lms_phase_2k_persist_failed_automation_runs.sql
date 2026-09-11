-- Phase 2K: make a failed pot automation leave durable evidence.
--
-- Defect. run_lms_pot_automation_internal wrapped its whole body, including the
-- `running` insert, in one block with an `exception when others` handler. PostgreSQL
-- opens a subtransaction at such a block, so the exception rolled the body back — the
-- `running` row included — and the handler's `update ... status='failed'` then matched
-- no row. Re-raising discarded the handler's own work as well, so nothing survived and
-- get_lms_operations_health's failed count was structurally always zero.
--
-- Fix. The run row is inserted in the outer block, before the savepoint exists. Only the
-- game work runs inside an inner block, so an exception rolls back exactly that work and
-- nothing else. The handler then records the failure on the already-durable row, and the
-- function RETURNS a structured failure instead of re-raising.
--
--   failed game mutation rolls back  -> the inner subtransaction is discarded
--   failed run evidence survives     -> insert and final update sit outside it
--
-- Returning rather than re-raising is required, not stylistic: any re-raise would abort
-- the caller's subtransaction too (scan_lms_automation_internal catches per pot) and take
-- the audit row with it. Callers already read `status` from the returned object, so both
-- the scan summary and the admin wrapper still see the failure.
--
-- Genuinely exceptional conditions still propagate: authorization in the public wrapper,
-- and anything failing before the run row exists (advisory lock, round lookup, the insert
-- itself), where there is no row to annotate. scan_lms_automation_internal keeps its own
-- per-pot handler as a backstop for those.
--
-- Signature, security mode, search_path and grants are unchanged.
begin;

do $$
begin
  if to_regprocedure('public.run_lms_pot_automation_internal(uuid,text,uuid)') is null then
    raise exception 'Phase 2K automation persistence requires Phase 2I';
  end if;
  if to_regclass('public.lms_automation_runs') is null then
    raise exception 'Phase 2K automation persistence requires public.lms_automation_runs';
  end if;
end $$;

create or replace function public.run_lms_pot_automation_internal(selected_pot_id uuid,run_source text,run_actor uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare selected_round public.pot_rounds%rowtype;deadline timestamptz;operation text;attempt_no integer;run_id uuid;
declare assignment jsonb;readiness jsonb;processed jsonb;summary jsonb;final_status text:='succeeded';error_kind text;safe_message text;
begin
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),-9);
 select r.* into selected_round from public.pot_rounds r where r.pot_id=selected_pot_id and not exists(select 1 from public.pot_gameweek_processes x where x.round_id=r.id) order by r.sequence_number limit 1;
 if not found then
  operation:='pot:'||selected_pot_id||':complete';select coalesce(max(attempt),0)+1 into attempt_no from public.lms_automation_runs where operation_key=operation;
  insert into public.lms_automation_runs(operation_key,attempt,job_type,pot_id,status,source,actor_id,finished_at,result_summary,error_class,safe_error) values(operation,attempt_no,'pot_automation',selected_pot_id,'skipped',run_source,run_actor,clock_timestamp(),jsonb_build_object('state','complete_or_no_current_round'),'waiting','No current LMS round') returning id into run_id;
  return jsonb_build_object('run_id',run_id,'status','skipped','state','complete_or_no_current_round');
 end if;
 operation:='pot:'||selected_pot_id||':round:'||selected_round.id;select coalesce(max(attempt),0)+1 into attempt_no from public.lms_automation_runs where operation_key=operation;

 -- Outside every exception block below, so a rolled-back attempt still leaves this row.
 insert into public.lms_automation_runs(operation_key,attempt,job_type,pot_id,round_id,gameweek_number,status,source,actor_id) values(operation,attempt_no,'pot_automation',selected_pot_id,selected_round.id,selected_round.gameweek_number,'running',run_source,run_actor) returning id into run_id;

 -- Only the game work is protected. Its rollback discards competition mutations and
 -- nothing else, because the savepoint starts here.
 begin
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
 exception when others then
   -- The inner subtransaction is already rolled back, so no partial game state remains.
   -- Only sqlstate is retained; sqlerrm is deliberately never stored or returned.
   final_status:='failed';error_kind:='invariant';
   summary:=jsonb_build_object('state','failed','sqlstate',sqlstate);
 end;

 safe_message:=case error_kind when 'review' then 'Governed review blocks automation' when 'invariant' then case when final_status='failed' then 'Automation stopped on an internal invariant' else 'Competition invariant requires review' end when 'waiting' then 'Operation is not due or results are unfinished' end;
 update public.lms_automation_runs set status=final_status,finished_at=clock_timestamp(),result_summary=coalesce(summary,'{}'),error_class=error_kind,safe_error=safe_message where id=run_id;
 return coalesce(summary,'{}')||jsonb_build_object('run_id',run_id,'status',final_status,'attempt',attempt_no);
end $$;

revoke all on function public.run_lms_pot_automation_internal(uuid,text,uuid) from public,anon,authenticated;

do $$
begin
  if not exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='run_lms_pot_automation_internal'
      and p.prosecdef and array_to_string(p.proconfig,',') like 'search_path=%'
  ) then
    raise exception 'Phase 2K automation persistence must keep SECURITY DEFINER and an empty search_path';
  end if;
  if has_function_privilege('authenticated','public.run_lms_pot_automation_internal(uuid,text,uuid)','execute')
    or has_function_privilege('anon','public.run_lms_pot_automation_internal(uuid,text,uuid)','execute') then
    raise exception 'Phase 2K automation persistence must not expose the internal automation entry point';
  end if;
end $$;

commit;
