-- Phase 2K W-2 executable verification. Disposable local database only.
--
-- Proves that preview_lms_review_resolution projects exactly the winner set and prize
-- split that resolve_lms_review_case persists, for the governed revise_winners action on a
-- completed pot after a fixture-result correction.
--
-- Comparisons are set-level and monetary: player ids, share order and pence, not counts.
-- Prizes are deliberately non-zero, and one case uses a total that does not divide evenly
-- so the remainder distribution is exercised.
--
-- Self-contained: it creates its own administrator rather than assuming a seeded one.

begin;

insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000080a0','authenticated','authenticated','w2-admin@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000080a1','authenticated','authenticated','w2-a@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000080a2','authenticated','authenticated','w2-b@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000080a3','authenticated','authenticated','w2-c@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
update public.profiles set is_admin=true where id='00000000-0000-0000-0000-0000000080a0';
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000080a0',true);

insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at)
select -81000-g,'P2KW2',-81000-g,-81000-g,'W2 Team '||g,'W'||g,now() from generate_series(1,12) g;
-- Two independent GW38 pots need disjoint fixtures; pot 1 uses slots 1-3, pot 2 slots 4-6.
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at)
select -82000-s,-82000-s,'P2KW2',38,now()+interval '2 hours',-81000-s,-81000-(s+6),false,false,false,'scheduled',false,now(),now()
from generate_series(1,6) s;

-- Pot 1: three paid entries at 1000p -> a 3000p prize that divides evenly.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status)
values('00000000-0000-0000-0000-000000008101','W2 pot one','P2KW2',1000,1000,'draft','00000000-0000-0000-0000-0000000080a0','setup');
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('00000000-0000-0000-0000-000000008101',38,now()+interval '1 hour');
insert into public.pot_players(pot_id,player_id,payment_status) values
('00000000-0000-0000-0000-000000008101','00000000-0000-0000-0000-0000000080a1','paid'),
('00000000-0000-0000-0000-000000008101','00000000-0000-0000-0000-0000000080a2','paid'),
('00000000-0000-0000-0000-000000008101','00000000-0000-0000-0000-0000000080a3','paid');
select public.set_pot_test_mode('00000000-0000-0000-0000-000000008101',true);

-- Pot 2: two paid entries of three members -> a 2000p prize that does NOT divide by three.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status)
values('00000000-0000-0000-0000-000000008102','W2 pot two','P2KW2',1000,1000,'draft','00000000-0000-0000-0000-0000000080a0','setup');
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('00000000-0000-0000-0000-000000008102',38,now()+interval '1 hour');
insert into public.pot_players(pot_id,player_id,payment_status) values
('00000000-0000-0000-0000-000000008102','00000000-0000-0000-0000-0000000080a1','paid'),
('00000000-0000-0000-0000-000000008102','00000000-0000-0000-0000-0000000080a2','paid'),
('00000000-0000-0000-0000-000000008102','00000000-0000-0000-0000-0000000080a3','unpaid');
select public.set_pot_test_mode('00000000-0000-0000-0000-000000008102',true);

-- Drive both pots to a completed GW38 with a single survivor.
do $$
declare pot uuid; base bigint; pk bigint;
begin
 foreach pot in array array['00000000-0000-0000-0000-000000008101'::uuid,'00000000-0000-0000-0000-000000008102'::uuid] loop
  base:=case when pot='00000000-0000-0000-0000-000000008101' then 0 else 3 end;
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000080a1',true);
  perform public.confirm_team_pick(pot,-82000-(base+1),-81000-(base+1));
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000080a2',true);
  perform public.confirm_team_pick(pot,-82000-(base+2),-81000-(base+2));
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000080a3',true);
  perform public.confirm_team_pick(pot,-82000-(base+3),-81000-(base+3));
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000080a0',true);
  select id into pk from public.player_picks where pot_id=pot and player_id='00000000-0000-0000-0000-0000000080a1';
  perform public.set_test_pick_scenario(pot,pk,'won');
  select id into pk from public.player_picks where pot_id=pot and player_id='00000000-0000-0000-0000-0000000080a2';
  perform public.set_test_pick_scenario(pot,pk,'lost');
  select id into pk from public.player_picks where pot_id=pot and player_id='00000000-0000-0000-0000-0000000080a3';
  perform public.set_test_pick_scenario(pot,pk,'lost');
  perform public.process_pot_gameweek(pot,38,true);
 end loop;
end $$;

-- L. GW38 terminal rules must be untouched by this fix.
do $$ begin
 if not exists(select 1 from public.pot_completions where pot_id='00000000-0000-0000-0000-000000008101'
   and resolution_rule='gw38_survivors' and winner_count=1 and total_prize_pence=3000) then
   raise exception 'GW38 survivor rule or prize changed for pot one'; end if;
 if not exists(select 1 from public.pot_completions where pot_id='00000000-0000-0000-0000-000000008102'
   and resolution_rule='gw38_survivors' and winner_count=1 and total_prize_pence=2000) then
   raise exception 'GW38 survivor rule or prize changed for pot two'; end if;
 if (select count(*) from public.pot_winners where pot_id='00000000-0000-0000-0000-000000008101')<>1
   or (select prize_share_pence from public.pot_winners where pot_id='00000000-0000-0000-0000-000000008101')<>3000 then
   raise exception 'Original Phase 2G winner record changed'; end if;
end $$;

-- A correction on a processed round opens the governed review case.
do $$ declare ov jsonb; begin
 ov:=public.preview_fixture_result_override(-82002,0,3,'finished','W-2 verification: correction on a completed pot round.');
 perform public.create_fixture_result_override(-82002,0,3,'finished','W-2 verification: correction on a completed pot round.',ov->>'effective_version');
end $$;

-- D. Invalid nominations are refused identically by preview and apply. Zero winners is
-- never a legitimate revise_winners outcome, so the terminal rule is asserted instead.
do $$ declare cid uuid; pv jsonb;
begin
 select id into cid from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000008101' and status='open' order by opened_at desc limit 1;
 if cid is null then raise exception 'The correction did not open a review case'; end if;

 -- cardinality(null) is null, so the pre-fix guard never fired here.
 pv:=public.preview_lms_review_resolution(cid,'revise_winners',null);
 if coalesce((pv->>'proposed_valid')::boolean,true) then raise exception 'Preview accepted a revision with no nominated winners'; end if;
 if (pv->>'proposed_winner_count')::integer<>0 or pv->>'proposed_winners'<>'[]' then raise exception 'Invalid revision must project an empty winner set'; end if;
 begin
   perform public.resolve_lms_review_case(cid,'revise_winners','Applying a revision with no nominated winners must refuse.',pv->>'version_token',null);
   raise exception 'Apply accepted a revision with no nominated winners';
 exception when others then
   if sqlerrm='Apply accepted a revision with no nominated winners' then raise; end if;
   if sqlerrm<>'A completed pot and at least one winner are required' then raise exception 'Unexpected refusal for empty nomination: %',sqlerrm; end if;
 end;

 -- A non-member nominee used to leave apply distributing only part of the prize.
 pv:=public.preview_lms_review_resolution(cid,'revise_winners',array['00000000-0000-0000-0000-0000000080a1','00000000-0000-0000-0000-0000000080ff']::uuid[]);
 if coalesce((pv->>'proposed_valid')::boolean,true) then raise exception 'Preview accepted a non-member nominee'; end if;
 begin
   perform public.resolve_lms_review_case(cid,'revise_winners','Applying a revision naming a non-member must refuse.',pv->>'version_token',array['00000000-0000-0000-0000-0000000080a1','00000000-0000-0000-0000-0000000080ff']::uuid[]);
   raise exception 'Apply accepted a non-member nominee';
 exception when others then
   if sqlerrm='Apply accepted a non-member nominee' then raise; end if;
   if sqlerrm<>'Every nominated winner must be a member of this pot' then raise exception 'Unexpected refusal for non-member: %',sqlerrm; end if;
 end;

 pv:=public.preview_lms_review_resolution(cid,'revise_winners',array['00000000-0000-0000-0000-0000000080a1','00000000-0000-0000-0000-0000000080a1']::uuid[]);
 if coalesce((pv->>'proposed_valid')::boolean,true) then raise exception 'Preview accepted a duplicated nominee'; end if;
end $$;

-- J. Preview is a genuine projection: no persistent row changes.
do $$ declare before_state text; after_state text; cid uuid; pv jsonb;
begin
 select id into cid from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000008101' and status='open' order by opened_at desc limit 1;
 select md5(string_agg(x,'|' order by x)) into before_state from (
   select 'cases:'||(select count(*)::text from public.lms_review_cases) as x
   union all select 'case_row:'||(select md5(to_jsonb(r)::text) from public.lms_review_cases r where r.id=cid)
   union all select 'events:'||(select count(*)::text from public.lms_review_resolution_events)
   union all select 'adjudications:'||(select count(*)::text from public.pot_completion_adjudications)
   union all select 'adjudicated_winners:'||(select count(*)::text from public.pot_adjudicated_winners)
   union all select 'winners:'||(select md5(coalesce(string_agg(w.player_id::text||':'||w.prize_share_pence,',' order by w.share_order),'')) from public.pot_winners w)
   union all select 'completions:'||(select md5(coalesce(string_agg(c.pot_id::text||':'||c.total_prize_pence||':'||c.winner_count,',' order by c.pot_id),'')) from public.pot_completions c)
   union all select 'players:'||(select md5(coalesce(string_agg(m.player_id::text||':'||m.player_status,',' order by m.pot_id,m.player_id),'')) from public.pot_players m)
   union all select 'overrides:'||(select count(*)::text from public.fixture_result_overrides)
   union all select 'pots:'||(select md5(coalesce(string_agg(p.id::text||':'||p.lifecycle_status||':'||coalesce(p.review_status,''),',' order by p.id),'')) from public.pots p)
 ) s;

 for i in 1..3 loop
   pv:=public.preview_lms_review_resolution(cid,'revise_winners',array['00000000-0000-0000-0000-0000000080a2']::uuid[]);
   pv:=public.preview_lms_review_resolution(cid,'revise_winners',null);
   pv:=public.preview_lms_review_resolution(cid,'close_without_change',null);
   pv:=public.preview_lms_review_resolution(cid,'confirm_existing',null);
 end loop;

 select md5(string_agg(x,'|' order by x)) into after_state from (
   select 'cases:'||(select count(*)::text from public.lms_review_cases) as x
   union all select 'case_row:'||(select md5(to_jsonb(r)::text) from public.lms_review_cases r where r.id=cid)
   union all select 'events:'||(select count(*)::text from public.lms_review_resolution_events)
   union all select 'adjudications:'||(select count(*)::text from public.pot_completion_adjudications)
   union all select 'adjudicated_winners:'||(select count(*)::text from public.pot_adjudicated_winners)
   union all select 'winners:'||(select md5(coalesce(string_agg(w.player_id::text||':'||w.prize_share_pence,',' order by w.share_order),'')) from public.pot_winners w)
   union all select 'completions:'||(select md5(coalesce(string_agg(c.pot_id::text||':'||c.total_prize_pence||':'||c.winner_count,',' order by c.pot_id),'')) from public.pot_completions c)
   union all select 'players:'||(select md5(coalesce(string_agg(m.player_id::text||':'||m.player_status,',' order by m.pot_id,m.player_id),'')) from public.pot_players m)
   union all select 'overrides:'||(select count(*)::text from public.fixture_result_overrides)
   union all select 'pots:'||(select md5(coalesce(string_agg(p.id::text||':'||p.lifecycle_status||':'||coalesce(p.review_status,''),',' order by p.id),'')) from public.pots p)
 ) s;

 if before_state is distinct from after_state then raise exception 'Preview mutated persistent state'; end if;
end $$;

-- K. Stale-token protection must still refuse. A second governed issue arriving while the
-- operator was previewing changes the open-case count the token binds, which is exactly
-- the concurrency the token exists to catch.
do $$ declare cid uuid; stale text;
begin
 select id into cid from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000008101' and status='open' order by opened_at desc limit 1;
 stale:=(public.preview_lms_review_resolution(cid,'revise_winners',array['00000000-0000-0000-0000-0000000080a1']::uuid[]))->>'version_token';
 perform public.open_lms_review_case('00000000-0000-0000-0000-000000008101','late_buyback_revocation',
   'An independent governed issue arrived while the winner revision was being previewed',
   null,null,null,null,'{}'::jsonb,'admin');
 if (select count(*) from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000008101' and status='open')<>2 then
   raise exception 'The second review case was not opened'; end if;
 begin
   perform public.resolve_lms_review_case(cid,'revise_winners','Applying with a stale preview token must refuse.',stale,array['00000000-0000-0000-0000-0000000080a1']::uuid[]);
   raise exception 'Stale preview token accepted';
 exception when others then
   if sqlerrm='Stale preview token accepted' then raise; end if;
   if sqlerrm<>'Review state changed; preview again.' then raise exception 'Unexpected stale-token error: %',sqlerrm; end if;
 end;
end $$;

-- G / H / M. Set-level and monetary equality between preview and apply, twice over: the
-- existing winner retained, then a genuinely different winner. Each application consumes
-- one open review case.
do $$
declare cid uuid; pv jsonb; res jsonb; projected jsonb; persisted jsonb; adj uuid; nominees uuid[]; label text;
begin
 foreach label in array array['retain','change'] loop
   nominees:=case label when 'retain' then array['00000000-0000-0000-0000-0000000080a1']::uuid[]
                        else array['00000000-0000-0000-0000-0000000080a2']::uuid[] end;
   select id into cid from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000008101' and status='open' order by opened_at limit 1;
   if cid is null then raise exception 'Expected an open review case for the % case',label; end if;

   pv:=public.preview_lms_review_resolution(cid,'revise_winners',nominees);
   if not (pv->>'proposed_valid')::boolean then raise exception 'Preview rejected a valid % nomination: %',label,pv->>'proposed_problem'; end if;
   projected:=pv->'proposed_winners';
   if (pv->>'proposed_prize_total')::integer<>3000 then raise exception 'Preview prize total wrong for %',label; end if;

   res:=public.resolve_lms_review_case(cid,'revise_winners','Governed revision verification for the '||label||' case.',pv->>'version_token',nominees);
   adj:=(res->>'adjudication_id')::uuid;
   if adj is null then raise exception 'Apply recorded no adjudication for %',label; end if;

   select coalesce(jsonb_agg(jsonb_build_object('player_id',w.player_id,'prize_share_pence',w.prize_share_pence,'share_order',w.share_order) order by w.share_order),'[]')
   into persisted from public.pot_adjudicated_winners w where w.adjudication_id=adj;

   if projected is distinct from persisted then
     raise exception 'Preview/apply winner set disagreed for %: preview=% applied=%',label,projected,persisted; end if;
   if (select sum(prize_share_pence) from public.pot_adjudicated_winners where adjudication_id=adj)<>3000 then
     raise exception 'Adjudicated shares did not conserve the prize for %',label; end if;

   -- M. The audit trail apply is required to leave behind.
   if not exists(select 1 from public.pot_completion_adjudications a where a.id=adj
     and a.pot_id='00000000-0000-0000-0000-000000008101' and a.case_id=cid
     and a.original_total_prize_pence=3000 and a.created_by='00000000-0000-0000-0000-0000000080a0'
     and a.created_at is not null and char_length(trim(a.reason))>=10) then
     raise exception 'Adjudication audit fields missing for %',label; end if;
   if not exists(select 1 from public.lms_review_resolution_events e where e.case_id=cid
     and e.action='revise_winners' and e.event_type='resolved'
     and e.actor_id='00000000-0000-0000-0000-0000000080a0'
     and e.before_state is not null and e.after_state is not null) then
     raise exception 'Resolution event missing for %',label; end if;
   if (select status from public.lms_review_cases where id=cid)<>'resolved' then
     raise exception 'Case not resolved for %',label; end if;

   -- Phase 2H's stated design: the original completion and winners stay untouched.
   if (select count(*) from public.pot_winners where pot_id='00000000-0000-0000-0000-000000008101')<>1
     or not exists(select 1 from public.pot_winners where pot_id='00000000-0000-0000-0000-000000008101' and player_id='00000000-0000-0000-0000-0000000080a1' and prize_share_pence=3000) then
     raise exception 'Original Phase 2G winners were rewritten during %',label; end if;
 end loop;

 -- Revision numbering increments across successive adjudications.
 if (select count(distinct revision_number) from public.pot_completion_adjudications where pot_id='00000000-0000-0000-0000-000000008101')<>2 then
   raise exception 'Adjudication revision numbering did not increment'; end if;
end $$;

-- I. Multiple winners with a remainder: the split must be identical in preview and apply,
-- and must still total the prize to the penny.
do $$ declare ov jsonb; cid uuid; pv jsonb; res jsonb; projected jsonb; persisted jsonb; adj uuid; nominees uuid[];
begin
 ov:=public.preview_fixture_result_override(-82005,0,3,'finished','W-2 verification: split-case correction.');
 perform public.create_fixture_result_override(-82005,0,3,'finished','W-2 verification: split-case correction.',ov->>'effective_version');
 select id into cid from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000008102' and status='open' order by opened_at limit 1;
 if cid is null then raise exception 'No review case opened on the split pot'; end if;

 nominees:=array['00000000-0000-0000-0000-0000000080a1','00000000-0000-0000-0000-0000000080a2','00000000-0000-0000-0000-0000000080a3']::uuid[];
 pv:=public.preview_lms_review_resolution(cid,'revise_winners',nominees);
 if not (pv->>'proposed_valid')::boolean then raise exception 'Preview rejected the split nomination: %',pv->>'proposed_problem'; end if;
 if (pv->>'proposed_winner_count')::integer<>3 then raise exception 'Split preview winner count wrong'; end if;
 if (pv->>'proposed_prize_total')::integer<>2000 then raise exception 'Split preview prize total wrong'; end if;
 projected:=pv->'proposed_winners';
 -- 2000 across three winners is 666 each with two remainder pennies.
 if (select sum((w->>'prize_share_pence')::integer) from jsonb_array_elements(projected) w)<>2000 then
   raise exception 'Preview split did not total the prize: %',projected; end if;
 if (select count(*) from jsonb_array_elements(projected) w where (w->>'prize_share_pence')::integer=667)<>2
   or (select count(*) from jsonb_array_elements(projected) w where (w->>'prize_share_pence')::integer=666)<>1 then
   raise exception 'Preview remainder distribution wrong: %',projected; end if;

 res:=public.resolve_lms_review_case(cid,'revise_winners','Governed revision verification for the split case.',pv->>'version_token',nominees);
 adj:=(res->>'adjudication_id')::uuid;
 select coalesce(jsonb_agg(jsonb_build_object('player_id',w.player_id,'prize_share_pence',w.prize_share_pence,'share_order',w.share_order) order by w.share_order),'[]')
 into persisted from public.pot_adjudicated_winners w where w.adjudication_id=adj;
 if projected is distinct from persisted then
   raise exception 'Preview/apply split disagreed: preview=% applied=%',projected,persisted; end if;
 if (select sum(prize_share_pence) from public.pot_adjudicated_winners where adjudication_id=adj)<>2000 then
   raise exception 'Applied split did not conserve the prize'; end if;
end $$;

-- Actions that do not revise winners must project the winners that remain, not zero.
do $$ declare ov jsonb; cid uuid; pv jsonb;
begin
 ov:=public.preview_fixture_result_override(-82006,0,3,'finished','W-2 verification: unchanged-winner projection.');
 perform public.create_fixture_result_override(-82006,0,3,'finished','W-2 verification: unchanged-winner projection.',ov->>'effective_version');
 select id into cid from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000008102' and status='open' order by opened_at desc limit 1;
 pv:=public.preview_lms_review_resolution(cid,'close_without_change',null);
 if (pv->>'proposed_winner_count')::integer<>1 then raise exception 'close_without_change must project the winners that remain'; end if;
 if not exists(select 1 from jsonb_array_elements(pv->'proposed_winners') w
   where (w->>'player_id')::uuid='00000000-0000-0000-0000-0000000080a1' and (w->>'prize_share_pence')::integer=2000) then
   raise exception 'close_without_change projection did not match the recorded winner'; end if;
end $$;

-- N. Authorization and exposure are unchanged.
do $$ begin
 if not has_function_privilege('authenticated','public.preview_lms_review_resolution(uuid,text,uuid[])','execute')
   or not has_function_privilege('authenticated','public.resolve_lms_review_case(uuid,text,text,text,uuid[])','execute') then
   raise exception 'Governed review RPCs must remain callable by administrators'; end if;
 if has_function_privilege('anon','public.preview_lms_review_resolution(uuid,text,uuid[])','execute')
   or has_function_privilege('anon','public.resolve_lms_review_case(uuid,text,text,text,uuid[])','execute')
   or has_function_privilege('authenticated','public.lms_revised_winner_projection(uuid,uuid[])','execute')
   or has_function_privilege('anon','public.lms_revised_winner_projection(uuid,uuid[])','execute') then
   raise exception 'Winner projection helper or governed RPCs are over-exposed'; end if;
 if has_table_privilege('authenticated','public.pot_adjudicated_winners','insert')
   or has_table_privilege('authenticated','public.pot_completion_adjudications','insert')
   or has_table_privilege('authenticated','public.lms_review_cases','update') then
   raise exception 'Adjudication or review tables are writable by players'; end if;
end $$;

-- A non-administrator may neither preview nor apply a governed resolution.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000080a1',true);
do $$ declare cid uuid;
begin
 select id into cid from public.lms_review_cases where status='resolved' order by resolved_at desc limit 1;
 begin
   perform public.preview_lms_review_resolution(cid,'revise_winners',array['00000000-0000-0000-0000-0000000080a1']::uuid[]);
   raise exception 'Player previewed a governed resolution';
 exception when others then
   if sqlerrm='Player previewed a governed resolution' then raise; end if;
   if sqlerrm<>'Administrator access required' then raise exception 'Unexpected preview authorization error: %',sqlerrm; end if;
 end;
 begin
   perform public.resolve_lms_review_case(cid,'revise_winners','A player must not resolve a governed case.','token',array['00000000-0000-0000-0000-0000000080a1']::uuid[]);
   raise exception 'Player resolved a governed case';
 exception when others then
   if sqlerrm='Player resolved a governed case' then raise; end if;
   if sqlerrm<>'Administrator access required' then raise exception 'Unexpected resolve authorization error: %',sqlerrm; end if;
 end;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000080a0',true);

-- Evidence summary for the record.
select a.revision_number, a.original_total_prize_pence as prize,
       count(w.player_id) as winners, sum(w.prize_share_pence) as shares_total,
       string_agg(w.prize_share_pence::text,'+' order by w.share_order) as split
from public.pot_completion_adjudications a
left join public.pot_adjudicated_winners w on w.adjudication_id=a.id
group by a.id, a.revision_number, a.original_total_prize_pence, a.pot_id
order by a.pot_id, a.revision_number;

rollback;
