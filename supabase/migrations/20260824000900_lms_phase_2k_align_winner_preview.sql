-- Phase 2K: make the governed review preview project the winner set apply will persist.
--
-- Defect (Wave 4, W-2). preview_lms_review_resolution never projected anything. It set
--
--   count_w := coalesce(cardinality(selected_player_ids),0);
--   ... 'proposed_winner_count', count_w
--
-- so the field simply echoed how many ids the caller passed in. It consulted no winner
-- rule, read no completion, and returned neither the proposed winner ids nor their prize
-- shares. resolve_lms_review_case derived the real set independently and inline. Three
-- disagreements followed from that one cause:
--
--   nominees        preview said            apply actually persisted
--   --------------- ----------------------- ------------------------------------------
--   [A]             count 1, no ids/shares  {A: whole prize}   -- count agreed by luck
--   NULL            count 0                 an adjudication with ZERO winners, and it
--                                           reported success instead of refusing
--   [A, non-member] count 2                 {A: half the prize} -- half the pot's
--                                           pennies silently vanished
--
-- The NULL case is the one Wave 4 hit. The guard reads
--
--   if not exists(...completion...) or cardinality(selected_player_ids)<1 then raise
--
-- and cardinality(null) is null, so `false or null` is null and the branch never fires.
-- unnest(null) then yields no rows, so the adjudication was written with no winners at
-- all, which also breaks the penny-conserving property Phase 2H documents.
--
-- Fix. One source of truth: lms_revised_winner_projection computes the revised winner set
-- and its penny-conserving split, using exactly the arithmetic and ordering that were
-- inline in the apply path. Preview serialises that projection; apply validates it and
-- persists it. Neither computes winners on its own any more.
--
-- Scope. This changes no game rule and no winner rule. Phase 2H's design stands: a
-- revision is recorded in the immutable pot_completion_adjudications /
-- pot_adjudicated_winners ledger and the original Phase 2G completion and pot_winners
-- remain untouched. Preview reports that faithfully rather than inventing a number, and
-- the guard now refuses the inputs its own error message always claimed to refuse.

begin;

do $$
begin
  if to_regclass('public.pot_completion_adjudications') is null or to_regclass('public.pot_adjudicated_winners') is null then
    raise exception 'Phase 2K winner-preview alignment requires Phase 2H';
  end if;
end $$;

-- The single source of truth for a revised winner set. Read-only and stable: preview can
-- call it safely, and apply persists exactly what it returns. Invalid nominations come
-- back as a structured problem rather than an exception so preview can show the operator
-- why the action cannot be applied, while apply raises on the same problem.
create or replace function public.lms_revised_winner_projection(selected_pot_id uuid,selected_player_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare total integer; nominated integer; distinct_nominated integer; member_nominated integer; winners jsonb;
begin
 select total_prize_pence into total from public.pot_completions where pot_id=selected_pot_id;
 nominated:=coalesce(cardinality(selected_player_ids),0);

 -- coalesce, because cardinality(null) is null and `... < 1` on it is null, not true.
 if total is null or nominated<1 then
   return jsonb_build_object('valid',false,'problem','A completed pot and at least one winner are required',
     'winners','[]'::jsonb,'winner_count',0,'total_prize_pence',total);
 end if;

 select count(distinct u) into distinct_nominated from unnest(selected_player_ids) u;
 if distinct_nominated<>nominated then
   return jsonb_build_object('valid',false,'problem','A winner was nominated more than once',
     'winners','[]'::jsonb,'winner_count',0,'total_prize_pence',total);
 end if;

 select count(*) into member_nominated from unnest(selected_player_ids) u
 join public.pot_players m on m.pot_id=selected_pot_id and m.player_id=u;
 if member_nominated<>nominated then
   return jsonb_build_object('valid',false,'problem','Every nominated winner must be a member of this pot',
     'winners','[]'::jsonb,'winner_count',0,'total_prize_pence',total);
 end if;

 -- Same split and same ordering the apply path has always used: an equal base share, with
 -- the remainder pennies going to the earliest joiners, so the shares total the prize.
 select coalesce(jsonb_agg(jsonb_build_object(
          'player_id',x.player_id,'prize_share_pence',x.prize_share_pence,'share_order',x.share_order
        ) order by x.share_order),'[]') into winners
 from (
   select u as player_id,
          row_number() over(order by m.joined_at,u)::integer as share_order,
          (total/nominated)+case when row_number() over(order by m.joined_at,u)<=(total%nominated) then 1 else 0 end as prize_share_pence
   from unnest(selected_player_ids) u
   join public.pot_players m on m.pot_id=selected_pot_id and m.player_id=u
 ) x;

 return jsonb_build_object('valid',true,'problem',null,'winners',winners,
   'winner_count',nominated,'total_prize_pence',total);
end $$;
revoke all on function public.lms_revised_winner_projection(uuid,uuid[]) from public,anon,authenticated;

-- Preview: unchanged token, unchanged read-only contract, but the proposed outcome is now
-- the projection rather than the caller's array length. Actions other than revise_winners
-- leave the recorded winners untouched, so they project the current winners.
create or replace function public.preview_lms_review_resolution(selected_case_id uuid,selected_action text,selected_player_ids uuid[] default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.lms_review_cases%rowtype;token text;original jsonb;total integer;projection jsonb;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 select * into c from public.lms_review_cases where id=selected_case_id;
 if not found then raise exception 'Review case not found'; end if;

 -- Token composition is deliberately unchanged: stale-preview protection must behave
 -- exactly as Phase 2H established and Wave 4 proved.
 token:=md5(c.id::text||':'||c.version||':'||c.status||':'||(select count(*) from public.lms_review_cases where pot_id=c.pot_id and status='open')||':'||coalesce((select completed_at::text from public.pot_completions where pot_id=c.pot_id),'none'));

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

-- Apply: persists the projection instead of recomputing it. Everything else -- the
-- administrator check, the reason requirement, the token check, the adjudication ledger,
-- the resolution event and the lifecycle update -- is unchanged.
create or replace function public.resolve_lms_review_case(selected_case_id uuid,selected_action text,resolution_reason text,expected_version_token text,selected_player_ids uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare c public.lms_review_cases%rowtype;preview jsonb;before_json jsonb;after_json jsonb;adjudication uuid;total integer;projection jsonb;remaining integer;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required';end if;
 if nullif(trim(resolution_reason),'') is null or char_length(trim(resolution_reason))<10 then raise exception 'A meaningful resolution reason is required';end if;
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

do $$
begin
  -- Both public RPCs keep their signatures, hardening and grants.
  if not exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('preview_lms_review_resolution','resolve_lms_review_case','lms_revised_winner_projection')
      and p.prosecdef and array_to_string(p.proconfig,',') like 'search_path=%'
    having count(*)=3
  ) then
    raise exception 'Winner-preview alignment must keep SECURITY DEFINER and an empty search_path';
  end if;
  if not has_function_privilege('authenticated','public.preview_lms_review_resolution(uuid,text,uuid[])','execute')
    or not has_function_privilege('authenticated','public.resolve_lms_review_case(uuid,text,text,text,uuid[])','execute') then
    raise exception 'Governed review RPCs must remain available to administrators';
  end if;
  if has_function_privilege('anon','public.preview_lms_review_resolution(uuid,text,uuid[])','execute')
    or has_function_privilege('anon','public.resolve_lms_review_case(uuid,text,text,text,uuid[])','execute') then
    raise exception 'Governed review RPCs must not be reachable anonymously';
  end if;
  if has_function_privilege('authenticated','public.lms_revised_winner_projection(uuid,uuid[])','execute')
    or has_function_privilege('anon','public.lms_revised_winner_projection(uuid,uuid[])','execute') then
    raise exception 'The winner projection helper must stay internal';
  end if;
  -- Preview must remain read-only.
  if (select provolatile from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='preview_lms_review_resolution')<>'s' then
    raise exception 'preview_lms_review_resolution must remain STABLE';
  end if;
  if (select provolatile from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='lms_revised_winner_projection')<>'s' then
    raise exception 'lms_revised_winner_projection must remain STABLE';
  end if;
end $$;

commit;
