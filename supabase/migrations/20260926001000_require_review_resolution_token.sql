-- Require explicit preview evidence at the administrator RPC trust boundary.
-- Forward-only: preserve actions, attribution, locks, history and valid retries.
begin;

create or replace function public.resolve_lms_review_case(selected_case_id uuid,selected_action text,resolution_reason text,expected_version_token text,selected_player_ids uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare c public.lms_review_cases%rowtype;preview jsonb;before_json jsonb;after_json jsonb;adjudication uuid;total integer;projection jsonb;remaining integer;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required';end if;
 -- Reject absent or malformed evidence even on an idempotent retry.
 if expected_version_token is null or expected_version_token !~ '^[0-9a-f]{32}$' then
   raise exception 'A valid review preview token is required';
 end if;
 if nullif(trim(resolution_reason),'') is null or char_length(trim(resolution_reason))<10 then raise exception 'A meaningful resolution reason is required';end if;
 perform 1 from public.pots where id=(select pot_id from public.lms_review_cases where id=selected_case_id) for update;
 select * into c from public.lms_review_cases where id=selected_case_id for update;
 if not found then raise exception 'Review case not found';end if;
 if c.status<>'open' then return jsonb_build_object('resolved',true,'already_resolved',true);end if;
 preview:=public.preview_lms_review_resolution(selected_case_id,selected_action,selected_player_ids);
 if (preview->>'version_token') is distinct from expected_version_token then raise exception 'Review state changed; preview again.';end if;
 before_json:=jsonb_build_object('pot',(select to_jsonb(p) from public.pots p where id=c.pot_id),'case',to_jsonb(c),'original_completion',(select to_jsonb(x) from public.pot_completions x where pot_id=c.pot_id));

 if selected_action='set_player_active' then update public.pot_players set player_status='active' where pot_id=c.pot_id and player_id=coalesce(c.player_id,selected_player_ids[1]);
 elsif selected_action='set_player_eliminated' then update public.pot_players set player_status='eliminated' where pot_id=c.pot_id and player_id=coalesce(c.player_id,selected_player_ids[1]);
 elsif selected_action='revise_winners' then
  projection:=public.lms_revised_winner_projection(c.pot_id,selected_player_ids);
  if not (projection->>'valid')::boolean then raise exception '%',projection->>'problem';end if;
  total:=(projection->>'total_prize_pence')::integer;
  insert into public.pot_completion_adjudications(pot_id,case_id,original_total_prize_pence,revision_number,reason,created_by) values(c.pot_id,c.id,total,(select count(*)+1 from public.pot_completion_adjudications where pot_id=c.pot_id),trim(resolution_reason),(select auth.uid())) returning id into adjudication;
  insert into public.pot_adjudicated_winners(adjudication_id,player_id,prize_share_pence,share_order)
  select adjudication,(w->>'player_id')::uuid,(w->>'prize_share_pence')::integer,(w->>'share_order')::integer
  from jsonb_array_elements(projection->'winners') w;
 elsif selected_action not in('confirm_existing','close_without_change') then raise exception 'Unsupported governed action';end if;

 update public.lms_review_cases set status=case when selected_action='close_without_change' then 'dismissed' else 'resolved' end,resolved_at=now(),version=version+1 where id=c.id;
 select count(*) into remaining from public.lms_review_cases where pot_id=c.pot_id and status='open';
 update public.pots set lifecycle_status=case when remaining>0 then 'review' when exists(select 1 from public.pot_completions where pot_id=c.pot_id) then 'complete' else 'in_progress' end,review_status=case when remaining>0 then 'needs_review' else 'reviewed' end,review_reason=case when remaining>0 then (select summary from public.lms_review_cases where pot_id=c.pot_id and status='open' order by opened_at limit 1) else null end,review_status_changed_at=now() where id=c.pot_id;
 after_json:=jsonb_build_object('pot',(select to_jsonb(p) from public.pots p where id=c.pot_id),'adjudication_id',adjudication,'preview',preview);
 insert into public.lms_review_resolution_events(case_id,event_type,action,reason,actor_id,before_state,after_state) values(c.id,case when selected_action='close_without_change' then 'dismissed' else 'resolved' end,selected_action,trim(resolution_reason),(select auth.uid()),before_json,after_json);
 return jsonb_build_object('resolved',true,'remaining_open_cases',remaining,'adjudication_id',adjudication);
end $$;
revoke all on function public.resolve_lms_review_case(uuid,text,text,text,uuid[]) from public,anon;
grant execute on function public.resolve_lms_review_case(uuid,text,text,text,uuid[]) to authenticated;

commit;
