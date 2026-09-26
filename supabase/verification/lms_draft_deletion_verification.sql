-- Real-role, rollback-only regression for the administrator draft-deletion RPC.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
('00000000-0000-0000-0000-000000026801','draft-admin@example.test','{}'),
('00000000-0000-0000-0000-000000026802','draft-other-admin@example.test','{}'),
('00000000-0000-0000-0000-000000026803','draft-player@example.test','{}'),
('00000000-0000-0000-0000-000000026804','draft-outsider@example.test','{}');
update public.profiles set is_admin=true where id in('00000000-0000-0000-0000-000000026801','00000000-0000-0000-0000-000000026802');
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name) values
(-926801,'DRAFT-DELETE',-926801,926801,'Draft Home','DH'),(-926802,'DRAFT-DELETE',-926802,926802,'Draft Away','DA');
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,status,provider_synced_at)
values(-926801,-926801,'DRAFT-DELETE',1,now()+interval '2 days',-926801,-926802,'scheduled',now());
create temporary table draft_checks(label text primary key);
create temporary table draft_context(label text primary key,pot_id uuid);
create temporary table draft_snapshot(value jsonb);
grant select,insert on draft_checks,draft_context to authenticated,anon;
create function pg_temp.check_draft(label text,ok boolean) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'Draft assertion failed: %',label; end if;
 insert into draft_checks values(label);
end $$;
create function pg_temp.deny_draft(label text,pot uuid,confirmation text,expected_message text default null)
returns void language plpgsql as $$
declare denied boolean:=false;
begin
 begin perform public.delete_draft_pot(pot,confirmation);
 exception
 when insufficient_privilege then denied:=expected_message is null;
 when raise_exception then denied:=sqlerrm=expected_message;
 end;
 perform pg_temp.check_draft(label,denied);
end $$;
-- Compare every public table, excluding only the selected draft's disposable rows.
-- This includes unrelated users, memberships, payments, picks, results and audits.
create function pg_temp.draft_surroundings(target uuid) returns jsonb language plpgsql as $$
declare t record; rows jsonb; result jsonb:='{}'; predicate text;
begin
 for t in select tablename from pg_tables where schemaname='public' order by tablename loop
  predicate:=case when t.tablename='pots' then ' where $1 is null or id<>$1'
   when t.tablename=any(array['pot_gameweeks','pot_players','pot_rounds','pot_round_players','player_picks','pot_player_team_cycles','pot_fixture_test_results']) then ' where $1 is null or pot_id<>$1'
   else '' end;
  execute format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from public.%I t%s',t.tablename,predicate) into rows using target;
  result:=result||jsonb_build_object(t.tablename,rows);
 end loop;
 return result;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026801',true);
insert into draft_context select label,public.create_pot(label,'DRAFT-DELETE',1000,500,array[1],array['00000000-0000-0000-0000-000000026803'::uuid])
from unnest(array['reset draft','pending draft','ordinary draft','protected draft','unrelated draft','review draft']) label;
select public.set_pot_test_mode(pot_id,true) from draft_context where label='reset draft';
select public.assign_random_missing_picks(pot_id,1,true) from draft_context where label='reset draft';
select public.reset_draft_test_pot(pot_id) from draft_context where label='reset draft';
select pg_temp.check_draft('Reset leaves the exact regression cohort',
 (select count(*)=1 from public.pot_round_players where pot_id=(select pot_id from draft_context where label='reset draft'))
 and not exists(select 1 from public.player_picks where pot_id=(select pot_id from draft_context where label='reset draft')));
reset role;
insert into public.admin_audit_events(administrator_id,action,target_type,target_identifier,reason)
select '00000000-0000-0000-0000-000000026801','draft_regression_evidence','pot',pot_id::text,'Synthetic audit must survive draft deletion'
from draft_context where label='reset draft';
insert into draft_snapshot select pg_temp.draft_surroundings(pot_id) from draft_context where label='reset draft';
set local role authenticated;
select public.delete_draft_pot(pot_id,label) from draft_context where label='reset draft';
reset role;
select pg_temp.check_draft('Reset draft deleted without altering unrelated data',
 (select value from draft_snapshot)=pg_temp.draft_surroundings((select pot_id from draft_context where label='reset draft')));
select pg_temp.check_draft('All reset draft dependants removed',not exists(
 select 1 from (select id pot_id from public.pots union all select pot_id from public.pot_players
 union all select pot_id from public.pot_gameweeks union all select pot_id from public.pot_rounds
 union all select pot_id from public.pot_round_players union all select pot_id from public.pot_player_team_cycles
 union all select pot_id from public.player_picks union all select pot_id from public.pot_fixture_test_results) t
 where pot_id=(select pot_id from draft_context where label='reset draft')));

set local role anon;
select set_config('request.jwt.claim.sub','',true);
select pg_temp.deny_draft('Anonymous cannot delete',pot_id,label) from draft_context where label='protected draft';
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026803',true);
select pg_temp.deny_draft('Member cannot delete organiser pot',pot_id,label,'Administrator access required') from draft_context where label='protected draft';
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026804',true);
select pg_temp.deny_draft('Unrelated player cannot delete another pot',pot_id,label,'Administrator access required') from draft_context where label='unrelated draft';
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026801',true);
select pg_temp.deny_draft('NULL confirmation rejected',pot_id,null,'Pot name confirmation did not match') from draft_context where label='protected draft';
select pg_temp.deny_draft('Wrong-pot confirmation rejected',pot_id,'unrelated draft','Pot name confirmation did not match') from draft_context where label='protected draft';
select pg_temp.deny_draft('Unknown pot fails explicitly','00000000-0000-0000-0000-000000026899','unknown','Pot not found');
select pg_temp.deny_draft('Repeated deletion fails explicitly',pot_id,label,'Pot not found') from draft_context where label='reset draft';
-- Administrators govern all pots: created_by is attribution, not private ownership.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026802',true);
select public.delete_draft_pot(pot_id,label) from draft_context where label='ordinary draft';
select pg_temp.check_draft('Second administrator can delete ordinary draft',not exists(select 1 from public.pots where id=(select pot_id from draft_context where label='ordinary draft')));
-- Pending picks are disposable; exercise their real trigger-created dependencies.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026803',true);
select public.confirm_team_pick(pot_id,-926801,-926801) from draft_context where label='pending draft';
reset role;
truncate draft_snapshot;
insert into draft_snapshot select pg_temp.draft_surroundings(pot_id) from draft_context where label='pending draft';
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026801',true);
select public.delete_draft_pot(pot_id,label) from draft_context where label='pending draft';
reset role;
select pg_temp.check_draft('Pending pick and cohort deletion preserves surroundings',
 (select value from draft_snapshot)=pg_temp.draft_surroundings((select pot_id from draft_context where label='pending draft'))
 and not exists(select 1 from public.player_picks where pot_id=(select pot_id from draft_context where label='pending draft')));

-- Exercise each protected state independently, even if an old client leaves
-- the legacy status field as draft. Failed RPCs must leave all tables unchanged.
do $$ declare c record; target uuid; before_state jsonb; begin
 select pot_id into target from draft_context where label='protected draft';
 for c in select * from (values
 ('open','open','open',null::timestamptz,'Only draft pots can be deleted'),
 ('active','active','in_progress',now(),'Only draft pots can be deleted'),
 ('complete','complete','complete',now(),'Only draft pots can be deleted'),
 ('legacy started draft','draft','in_progress',null,'Only an unlocked setup draft can be deleted'),
 ('locked draft','draft','setup',now(),'Only an unlocked setup draft can be deleted')
 ) cases(label,status,lifecycle,locked,message) loop
  update public.pots set status=c.status,lifecycle_status=c.lifecycle,membership_locked_at=c.locked where id=target;
  before_state:=pg_temp.draft_surroundings(null);
  execute 'set local role authenticated';
  perform pg_temp.deny_draft(c.label,target,'protected draft',c.message);
  execute 'reset role';
  perform pg_temp.check_draft(c.label||' remains unchanged',before_state=pg_temp.draft_surroundings(null));
 end loop;
 update public.pots set status='draft',lifecycle_status='setup',membership_locked_at=null where id=target;
 -- A finalised cohort remains protected even after test reset removes processes.
 update public.pot_rounds set cohort_finalized_at=now() where pot_id=target;
 execute 'set local role authenticated';
 perform pg_temp.deny_draft('Finalised round cannot be deleted',target,'protected draft','A draft with competition or review history cannot be deleted');
 execute 'reset role';
 perform pg_temp.check_draft('Finalised round retained',exists(select 1 from public.pot_rounds where pot_id=target and cohort_finalized_at is not null));
end $$;
insert into public.lms_review_cases(pot_id,case_type,summary,opened_source)
select pot_id,'migration_review','Historical review must prevent deletion','migration' from draft_context where label='review draft';
truncate draft_snapshot;
insert into draft_snapshot select pg_temp.draft_surroundings(null);
set local role authenticated;
select pg_temp.deny_draft('Review history cannot be deleted',pot_id,label,'A draft with competition or review history cannot be deleted') from draft_context where label='review draft';
reset role;
select pg_temp.check_draft('Review denial leaves all data unchanged',(select value from draft_snapshot)=pg_temp.draft_surroundings(null));
select pg_temp.check_draft('Deletion RPC grant boundary retained',not has_function_privilege('anon','public.delete_draft_pot(uuid,text)','execute') and has_function_privilege('authenticated','public.delete_draft_pot(uuid,text)','execute'));
select 'PASS draft deletion: '||count(*)||' assertions.' from draft_checks;
rollback;
