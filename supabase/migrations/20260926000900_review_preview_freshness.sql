-- Invalidate review previews when another correction arrives during an open review.
-- No existing rows are rewritten. Only preview freshness and resolution locking change.
begin;

create or replace function public.preview_lms_review_resolution(selected_case_id uuid,selected_action text,selected_player_ids uuid[] default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.lms_review_cases%rowtype;token text;original jsonb;total integer;projection jsonb;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 select * into c from public.lms_review_cases where id=selected_case_id;
 if not found then raise exception 'Review case not found'; end if;

 -- A further correction updates the pot review timestamp even when the existing
 -- review case and its version remain unchanged. Include that evidence revision.
 token:=md5(c.id::text||':'||c.version||':'||c.status||':'||(select count(*) from public.lms_review_cases where pot_id=c.pot_id and status='open')||':'||coalesce((select completed_at::text from public.pot_completions where pot_id=c.pot_id),'none')||':'||coalesce((select review_status_changed_at::text from public.pots where id=c.pot_id),'none'));

 select coalesce(jsonb_agg(jsonb_build_object('player_id',player_id,'share',prize_share_pence) order by share_order),'[]') into original from public.pot_winners where pot_id=c.pot_id;
 select total_prize_pence into total from public.pot_completions where pot_id=c.pot_id;

 if selected_action='revise_winners' then
   projection:=public.lms_revised_winner_projection(c.pot_id,selected_player_ids);
 else
   projection:=jsonb_build_object('valid',true,'problem',null,
     'winners',coalesce((select jsonb_agg(jsonb_build_object('player_id',player_id,'prize_share_pence',prize_share_pence,'share_order',share_order) order by share_order) from public.pot_winners where pot_id=c.pot_id),'[]'::jsonb),
     'winner_count',(select count(*) from public.pot_winners where pot_id=c.pot_id),
     'total_prize_pence',total);
 end if;

 return jsonb_build_object('case_id',c.id,'status',c.status,'version_token',token,'action',selected_action,
   'affected_round',c.source_round_id,'player_id',c.player_id,'impact',c.impact_snapshot,
   'original_winners',original,
   'proposed_winners',projection->'winners',
   'proposed_winner_count',(projection->>'winner_count')::integer,
   'proposed_prize_total',(projection->>'total_prize_pence')::integer,
   'proposed_valid',(projection->>'valid')::boolean,
   'proposed_problem',projection->>'problem',
   'prize_total',total,
   'pot_after',case when (select count(*) from public.lms_review_cases where pot_id=c.pot_id and status='open')>1 then 'review' when exists(select 1 from public.pot_completions where pot_id=c.pot_id) then 'complete' else 'in_progress' end);
end $$;
revoke all on function public.preview_lms_review_resolution(uuid,text,uuid[]) from public,anon;
grant execute on function public.preview_lms_review_resolution(uuid,text,uuid[]) to authenticated;

-- Serialise correction and resolution on the pot row before locking the case.
-- Keep the existing actions, projection, permissions and append-only decision record.
create or replace function public.resolve_lms_review_case(selected_case_id uuid,selected_action text,resolution_reason text,expected_version_token text,selected_player_ids uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare c public.lms_review_cases%rowtype;preview jsonb;before_json jsonb;after_json jsonb;adjudication uuid;total integer;projection jsonb;remaining integer;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required';end if;
 if nullif(trim(resolution_reason),'') is null or char_length(trim(resolution_reason))<10 then raise exception 'A meaningful resolution reason is required';end if;
 perform 1 from public.pots where id=(select pot_id from public.lms_review_cases where id=selected_case_id) for update;
 select * into c from public.lms_review_cases where id=selected_case_id for update;
 if not found then raise exception 'Review case not found';end if;
 if c.status<>'open' then return jsonb_build_object('resolved',true,'already_resolved',true);end if;
 preview:=public.preview_lms_review_resolution(selected_case_id,selected_action,selected_player_ids);
 if preview->>'version_token'<>expected_version_token then raise exception 'Review state changed; preview again.';end if;
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

-- Internal case creation uses the same pot-before-case order, including provider reversals.
create or replace function public.open_lms_review_case(selected_pot_id uuid,selected_case_type text,selected_summary text,selected_round_id uuid default null,selected_fixture_id bigint default null,selected_pick_id bigint default null,selected_player_id uuid default null,selected_evidence jsonb default '{}',selected_source text default 'system') returns uuid language plpgsql security definer set search_path='' as $$
declare created_id uuid;impact jsonb;
begin
 if selected_source='admin' and not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 perform 1 from public.pots where id=selected_pot_id for update;
 select jsonb_build_object('later_rounds',(select count(*) from public.pot_rounds r where r.pot_id=selected_pot_id and (selected_round_id is null or r.sequence_number>(select sequence_number from public.pot_rounds where id=selected_round_id))),'later_picks',(select count(*) from public.player_picks p where p.pot_id=selected_pot_id and (selected_round_id is null or p.gameweek_number>(select gameweek_number from public.pot_rounds where id=selected_round_id))),'completed',exists(select 1 from public.pot_completions where pot_id=selected_pot_id)) into impact;
 insert into public.lms_review_cases(pot_id,source_round_id,fixture_id,pick_id,player_id,case_type,summary,evidence,impact_snapshot,opened_by,opened_source)
 values(selected_pot_id,selected_round_id,selected_fixture_id,selected_pick_id,selected_player_id,selected_case_type,trim(selected_summary),selected_evidence,impact,case when selected_source='system' then null else (select auth.uid()) end,selected_source)
 on conflict(pot_id,case_type,fixture_id,player_id) where status='open' do update set evidence=lms_review_cases.evidence||excluded.evidence,impact_snapshot=excluded.impact_snapshot,version=lms_review_cases.version+1 returning id into created_id;
 perform set_config('lms.review_case_opening','1',true);
 update public.pots set lifecycle_status='review',review_status='needs_review',review_reason=trim(selected_summary),review_status_changed_at=now() where id=selected_pot_id;
 perform set_config('lms.review_case_opening','0',true);
 return created_id;
end $$;
revoke all on function public.open_lms_review_case(uuid,text,text,uuid,bigint,bigint,uuid,jsonb,text) from public,anon,authenticated;

commit;
