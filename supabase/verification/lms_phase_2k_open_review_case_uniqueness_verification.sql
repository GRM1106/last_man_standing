-- Phase 2K open-review-case uniqueness executable verification. Disposable local database only.
--
-- Proves that a governed issue of the same target shape can be corrected any number of
-- times, while at most one case of that shape is ever open at once, and that
-- open_lms_review_case's deduplication is unchanged.
--
-- Self-contained: it creates its own administrator rather than assuming a seeded one.

begin;

insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000093a0','authenticated','authenticated','p5-admin@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000093a1','authenticated','authenticated','p5-player@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
update public.profiles set is_admin=true where id='00000000-0000-0000-0000-0000000093a0';
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000093a0',true);

insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
(-93001,'P5SEASON',-93001,-93001,'P5 Home','P5H',now()),(-93002,'P5SEASON',-93002,-93002,'P5 Away','P5A',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values
(-93101,-93101,'P5SEASON',10,now()+interval '2 hours',-93001,-93002,false,false,false,'scheduled',false,now(),now()),
(-93102,-93102,'P5SEASON',11,now()+interval '9 days',-93001,-93002,false,false,false,'scheduled',false,now(),now());

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status) values
('00000000-0000-0000-0000-000000009a01','P5 pot one','P5SEASON',1000,1000,'draft','00000000-0000-0000-0000-0000000093a0','setup'),
('00000000-0000-0000-0000-000000009a02','P5 pot two','P5SEASON',1000,1000,'draft','00000000-0000-0000-0000-0000000093a0','setup');
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values
('00000000-0000-0000-0000-000000009a01',10,now()+interval '1 hour'),
('00000000-0000-0000-0000-000000009a01',11,now()+interval '8 days');
insert into public.pot_players(pot_id,player_id) values
('00000000-0000-0000-0000-000000009a01','00000000-0000-0000-0000-0000000093a1');

-- CASE A. Opening the same shape twice while it is open must deduplicate onto one row.
do $$ declare first_id uuid; second_id uuid; row_count integer; merged jsonb; opened timestamptz; opener uuid;
begin
 first_id:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_result_correction','first opening of the pot-level shape',null,null,null,null,'{"a":1}'::jsonb,'admin');
 select opened_at,opened_by into opened,opener from public.lms_review_cases where id=first_id;
 if (select version from public.lms_review_cases where id=first_id)<>1 then raise exception 'A first opening must start at version 1'; end if;
 if (select status from public.lms_review_cases where id=first_id)<>'open' then raise exception 'A newly opened case must be open'; end if;

 second_id:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_result_correction','second opening of the pot-level shape',null,null,null,null,'{"b":2}'::jsonb,'admin');
 select count(*) into row_count from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01';
 select evidence into merged from public.lms_review_cases where id=second_id;

 if second_id is distinct from first_id then raise exception 'Reopening an open shape must return the same case'; end if;
 if row_count<>1 then raise exception 'Reopening an open shape must not create a second row, got %',row_count; end if;
 if (select version from public.lms_review_cases where id=second_id)<>2 then raise exception 'Reopening must increment version'; end if;
 if merged is distinct from '{"a":1,"b":2}'::jsonb then raise exception 'Evidence must merge, got %',merged; end if;
 if (select impact_snapshot from public.lms_review_cases where id=second_id) is null then raise exception 'Impact snapshot must be refreshed'; end if;
 if (select opened_at from public.lms_review_cases where id=second_id) is distinct from opened
   or (select opened_by from public.lms_review_cases where id=second_id) is distinct from opener then
   raise exception 'Deduplication must preserve opened_at/opened_by'; end if;
end $$;

-- CASE B. Resolve, reopen, resolve again. Two resolved cases of one shape may coexist.
do $$ declare first_id uuid; second_id uuid;
begin
 select id into first_id from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01' and status='open';
 update public.lms_review_cases set status='resolved',resolved_at=now() where id=first_id;

 second_id:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_result_correction','the same issue recurs after the first correction',null,null,null,null,'{}'::jsonb,'admin');
 if second_id=first_id then raise exception 'A resolved case must not be reused as the open case'; end if;
 if (select count(*) from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01' and status='open')<>1 then
   raise exception 'Exactly one open case of the shape should exist'; end if;

 update public.lms_review_cases set status='resolved',resolved_at=now() where id=second_id;
 if (select count(*) from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01' and status='resolved')<>2 then
   raise exception 'Two resolved cases of the same shape must be able to coexist'; end if;
 if (select count(*) from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01' and status='open')<>0 then
   raise exception 'No open case should remain'; end if;
end $$;

-- CASE C. The same for dismissals.
do $$ declare a uuid; b uuid;
begin
 a:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_result_correction','a third occurrence to be dismissed',null,null,null,null,'{}'::jsonb,'admin');
 update public.lms_review_cases set status='dismissed',resolved_at=now() where id=a;
 b:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_result_correction','a fourth occurrence to be dismissed',null,null,null,null,'{}'::jsonb,'admin');
 update public.lms_review_cases set status='dismissed',resolved_at=now() where id=b;
 if (select count(*) from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01' and status='dismissed')<>2 then
   raise exception 'Two dismissed cases of the same shape must be able to coexist'; end if;
end $$;

-- CASE D. A shape may accumulate mixed terminal states without limit.
do $$ declare c uuid; resolved_count integer; dismissed_count integer;
begin
 for i in 1..4 loop
   c:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_result_correction','recurring occurrence number '||i::text,null,null,null,null,'{}'::jsonb,'admin');
   update public.lms_review_cases set status=case when i%2=1 then 'resolved' else 'dismissed' end,resolved_at=now() where id=c;
 end loop;
 select count(*) filter (where status='resolved'),count(*) filter (where status='dismissed')
 into resolved_count,dismissed_count
 from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01';
 -- Case B left 2 resolved, Case C left 2 dismissed, this loop adds 2 of each.
 if resolved_count<>4 or dismissed_count<>4 then
   raise exception 'Expected four resolved and four dismissed, got % and %',resolved_count,dismissed_count; end if;
 if (select count(*) from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01' and status='open')<>0 then
   raise exception 'No open case should remain after the mixed run'; end if;
end $$;

-- CASE E. The database itself, not just the RPC, rejects a second open case of a shape.
do $$ declare a uuid;
begin
 a:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','progression_failure','an open case guarded directly by the index',null,null,null,null,'{}'::jsonb,'admin');
 begin
   insert into public.lms_review_cases(pot_id,case_type,summary,opened_source,status)
   values('00000000-0000-0000-0000-000000009a01','progression_failure','a duplicate open case inserted directly','admin','open');
   raise exception 'A second open case of the same shape was accepted';
 exception when unique_violation then null;
 end;
 -- A terminal duplicate of that same shape must be accepted, twice over.
 insert into public.lms_review_cases(pot_id,case_type,summary,opened_source,status,resolved_at)
 values('00000000-0000-0000-0000-000000009a01','progression_failure','a historical resolved twin','admin','resolved',now()),
       ('00000000-0000-0000-0000-000000009a01','progression_failure','another historical resolved twin','admin','resolved',now());
 if (select count(*) from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000009a01' and case_type='progression_failure' and status='resolved')<>2 then
   raise exception 'Terminal rows must not be constrained'; end if;
 update public.lms_review_cases set status='dismissed',resolved_at=now() where id=a;
end $$;

-- CASE F. Null targets deduplicate; non-null targets deduplicate on their own values.
do $$ declare a uuid; b uuid; c uuid; d uuid;
begin
 -- Null fixture and player: PostgreSQL would normally treat these as distinct.
 a:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a02','migration_review','pot-level null-target case',null,null,null,null,'{}'::jsonb,'admin');
 b:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a02','migration_review','pot-level null-target case again',null,null,null,null,'{}'::jsonb,'admin');
 if a is distinct from b then raise exception 'Null targets must be treated as equal for deduplication'; end if;

 -- Fixture-level: same fixture merges, a different fixture does not.
 c:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_context_change','fixture-level case',null,-93101,null,null,'{}'::jsonb,'admin');
 d:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_context_change','fixture-level case again',null,-93101,null,null,'{}'::jsonb,'admin');
 if c is distinct from d then raise exception 'The same fixture target must deduplicate'; end if;
 d:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_context_change','a different fixture',null,-93102,null,null,'{}'::jsonb,'admin');
 if d=c then raise exception 'A different fixture must open its own case'; end if;

 -- Player-level, and a null player against a set player.
 c:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','late_buyback_revocation','player-level case',null,null,null,'00000000-0000-0000-0000-0000000093a1','{}'::jsonb,'admin');
 d:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','late_buyback_revocation','player-level case again',null,null,null,'00000000-0000-0000-0000-0000000093a1','{}'::jsonb,'admin');
 if c is distinct from d then raise exception 'The same player target must deduplicate'; end if;
 d:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','late_buyback_revocation','the pot-level variant of that type',null,null,null,null,'{}'::jsonb,'admin');
 if d=c then raise exception 'A null player target must not merge into a specific player case'; end if;
end $$;

-- CASE G. Cases differing by any target dimension stay independent.
do $$ declare pot_one uuid; pot_two uuid;
begin
 pot_one:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','completed_pot_correction','shape on pot one',null,null,null,null,'{}'::jsonb,'admin');
 pot_two:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a02','completed_pot_correction','the same shape on a different pot',null,null,null,null,'{}'::jsonb,'admin');
 if pot_one=pot_two then raise exception 'Different pots must not share a case'; end if;
 if (select count(*) from public.lms_review_cases where case_type='completed_pot_correction' and status='open')<>2 then
   raise exception 'Both pots should hold their own open case'; end if;
end $$;

-- Resolution-flow regression: the governed lifecycle still works over the new index.
do $$ declare case_id uuid; token text; result jsonb; before_events integer; after_events integer;
begin
 select count(*) into before_events from public.lms_review_resolution_events;

 -- open -> resolved, through the real RPC
 case_id:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','exceptional_status_reversal','a reversal that will be confirmed',null,null,null,null,'{}'::jsonb,'admin');
 token:=(public.preview_lms_review_resolution(case_id,'confirm_existing',null))->>'version_token';
 result:=public.resolve_lms_review_case(case_id,'confirm_existing','Confirming the existing competition state after review.',token,null);
 if coalesce((result->>'resolved')::boolean,false) is not true then raise exception 'confirm_existing did not resolve'; end if;
 if (select status from public.lms_review_cases where id=case_id)<>'resolved' then raise exception 'Case should be resolved'; end if;

 -- a second resolution attempt must be refused as already handled, never applied twice
 result:=public.resolve_lms_review_case(case_id,'confirm_existing','A second attempt at the same resolution.',token,null);
 if coalesce((result->>'already_resolved')::boolean,false) is not true then raise exception 'A case must not transition twice'; end if;

 -- open -> dismissed, through the real RPC, for the same shape as the resolved one
 case_id:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','exceptional_status_reversal','the same reversal shape recurring',null,null,null,null,'{}'::jsonb,'admin');
 token:=(public.preview_lms_review_resolution(case_id,'close_without_change',null))->>'version_token';
 result:=public.resolve_lms_review_case(case_id,'close_without_change','Closing this occurrence without any competition change.',token,null);
 if (select status from public.lms_review_cases where id=case_id)<>'dismissed' then raise exception 'close_without_change should dismiss'; end if;

 -- stale-token protection is untouched
 case_id:=public.open_lms_review_case('00000000-0000-0000-0000-000000009a01','fixture_context_change','a case used for the stale-token check',null,-93101,null,null,'{}'::jsonb,'admin');
 token:=(public.preview_lms_review_resolution(case_id,'confirm_existing',null))->>'version_token';
 update public.lms_review_cases set version=version+1 where id=case_id;
 begin
   perform public.resolve_lms_review_case(case_id,'confirm_existing','Applying with a deliberately stale token.',token,null);
   raise exception 'Stale preview token accepted';
 exception when others then
   if sqlerrm='Stale preview token accepted' then raise; end if;
   if sqlerrm<>'Review state changed; preview again.' then raise exception 'Unexpected stale-token error: %',sqlerrm; end if;
 end;

 select count(*) into after_events from public.lms_review_resolution_events;
 if after_events<>before_events+2 then
   raise exception 'Expected exactly two new resolution events, got %',after_events-before_events; end if;
end $$;

-- Audit history remains append-only.
do $$ begin
 begin
   update public.lms_review_resolution_events set reason='tampered reason for the probe';
   raise exception 'Resolution events were mutable';
 exception when others then
   if sqlerrm='Resolution events were mutable' then raise; end if;
   if sqlerrm<>'Review adjudication history is append-only' then raise exception 'Unexpected audit error: %',sqlerrm; end if;
 end;
end $$;

-- The uniqueness rule itself, as the database reports it.
do $$ declare index_definition text;
begin
 if exists(select 1 from pg_constraint where conrelid='public.lms_review_cases'::regclass
   and conname='lms_review_cases_pot_id_case_type_fixture_id_player_id_stat_key') then
   raise exception 'The status-bearing constraint is still present'; end if;
 select indexdef into index_definition from pg_indexes
 where schemaname='public' and indexname='lms_review_cases_one_open_per_target';
 if index_definition is null then raise exception 'The open-only index is missing'; end if;
 if index_definition not like '%NULLS NOT DISTINCT%' then raise exception 'Null targets must be treated as equal'; end if;
 if index_definition not like '%WHERE (status = ''open''::text)%' then raise exception 'The index must be restricted to open cases'; end if;
end $$;

-- Evidence summary for the record.
select p.name as pot, c.case_type, c.status, count(*) as cases
from public.lms_review_cases c join public.pots p on p.id=c.pot_id
group by p.name, c.case_type, c.status
order by p.name, c.case_type, c.status;

rollback;
