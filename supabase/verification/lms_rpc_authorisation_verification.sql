-- Rollback-only application RPC/role regression. Runs after the complete chain.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
('00000000-0000-0000-0000-000000026701','security-admin@example.test','{"first_name":"Security","last_name":"Admin"}'),
('00000000-0000-0000-0000-000000026702','security-member@example.test','{"first_name":"Security","last_name":"Member","is_admin":true}'),
('00000000-0000-0000-0000-000000026703','security-other@example.test','{"first_name":"Security","last_name":"Other"}'),
('00000000-0000-0000-0000-000000026704','security-new@example.test','{"first_name":"Security","last_name":"New","is_admin":true}');
update public.profiles set is_admin=true where id='00000000-0000-0000-0000-000000026701';
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name) values
(-926701,'RPC-SECURITY',-926701,926701,'Security Home','SH'),
(-926702,'RPC-SECURITY',-926702,926702,'Security Away','SA');
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,status,provider_synced_at) values
(-926701,-926701,'RPC-SECURITY',1,now()+interval '2 days',-926701,-926702,'scheduled',now()),
(-926702,-926702,'RPC-SECURITY',2,now()+interval '9 days',-926701,-926702,'scheduled',now());
insert into public.pots(id,name,season,status,lifecycle_status,test_mode,created_by,entry_fee_pence,buy_back_fee_pence) values
('00000000-0000-0000-0000-000000026711','Security member pot','RPC-SECURITY','open','open',false,'00000000-0000-0000-0000-000000026701',1000,500),
('00000000-0000-0000-0000-000000026712','Security unrelated draft','RPC-SECURITY','draft','setup',true,'00000000-0000-0000-0000-000000026701',1000,500);
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
select p,gw,now()+interval '2 days'+(gw-1)*interval '7 days'
from unnest(array['00000000-0000-0000-0000-000000026711'::uuid,'00000000-0000-0000-0000-000000026712'::uuid]) p cross join generate_series(1,2) gw;
insert into public.pot_players(pot_id,player_id) values
('00000000-0000-0000-0000-000000026711','00000000-0000-0000-0000-000000026702'),
('00000000-0000-0000-0000-000000026711','00000000-0000-0000-0000-000000026703'),
('00000000-0000-0000-0000-000000026712','00000000-0000-0000-0000-000000026703');
-- Real pick RPCs populate the snapshots/triggers; no business-rule bypass needed.
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026703',true);
select public.confirm_team_pick('00000000-0000-0000-0000-000000026711',-926701,-926702);
select public.confirm_team_pick('00000000-0000-0000-0000-000000026712',-926701,-926701);
reset role;
create temporary table rpc_security_results(label text primary key);
grant select,insert on rpc_security_results to anon,authenticated;
create function pg_temp.check_security(label text,ok boolean) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Security assertion failed: %',label; end if;
  insert into rpc_security_results values(label);
end $$;
create function pg_temp.expect_denied(label text,statement text,expected_message text default null)
returns void language plpgsql as $$
declare denied boolean:=false;
begin
  begin execute statement;
  exception
    when insufficient_privilege then denied:=expected_message is null;
    when raise_exception then denied:=expected_message is not null and sqlerrm=expected_message;
  end;
  perform pg_temp.check_security(label,denied);
end $$;

-- Check effective privileges, including PUBLIC/inherited grants, across the whole
-- application surface. Extensions are excluded by catalogue dependency, not name.
select pg_temp.check_security('No anonymous application function execution',not exists(
  select 1 from pg_proc p where p.pronamespace='public'::regnamespace
  and not exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.deptype='e')
  and has_function_privilege('anon',p.oid,'execute')));

-- Authenticated execution is restricted to the reviewed entry points. An admin
-- uses the same database role as a player; each privileged entry point must also
-- check is_current_user_admin() before accessing protected state.
select pg_temp.check_security('Authenticated function surface matches reviewed entry points',
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
   where p.pronamespace='public'::regnamespace and has_function_privilege('authenticated',p.oid,'execute')
   and not exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.deptype='e'))
  = (select array_agg(signature order by signature) from unnest(array[
    'add_player_to_pot(uuid,uuid)',
    'set_pot_discoverable(uuid,boolean)',
    'get_available_pots()',
    'request_pot_membership(uuid)',
    'decide_pot_membership(uuid,uuid,integer,boolean)',
    'get_pot_join_requests(uuid)',
    'get_admin_player_memberships(uuid)',
    'assign_random_missing_picks(uuid,integer,boolean)',
    'claim_buy_back(uuid)',
    'claim_pot_payment(uuid)',
    'complete_pot_with_winner(uuid,uuid)',
    'confirm_buy_back(uuid,uuid)',
    'confirm_team_pick(uuid,bigint,bigint)',
    'create_fixture_result_override(bigint,integer,integer,text,text,text)',
    'create_pot(text,text,integer,integer,integer[],uuid[])',
    'delete_draft_pot(uuid,text)',
    'fill_remaining_pot_gameweeks(uuid)',
    'get_admin_fixture_results(text)',
    'get_admin_pick_overview(uuid,integer)',
    'get_gameweek_deadline(uuid,integer)',
    'get_lms_automation_status(uuid)',
    'get_lms_operations_health()',
    'get_my_dashboard()',
    'get_my_pot_history(uuid)',
    'get_my_pot_review_outcome(uuid)',
    'get_my_pot_review_state(uuid)',
    'get_my_team_availability(uuid)',
    'get_p1_provenance_backfill_report()',
    'get_player_provider_notice()',
    'get_pot_completion(uuid)',
    'get_pot_rounds(uuid)',
    'get_pot_selection(uuid)',
    'get_pot_standings(uuid)',
    'is_current_user_admin()',
    'preview_fixture_result_override(bigint,integer,integer,text,text)',
    'preview_lms_review_resolution(uuid,text,uuid[])',
    'process_pot_gameweek(uuid,integer,boolean)',
    'remove_player_from_pot(uuid,uuid)',
    'reset_draft_test_pot(uuid)',
    'reset_test_gameweek(uuid,integer)',
    'resolve_lms_review_case(uuid,text,text,text,uuid[])',
    'revoke_buy_back(uuid,uuid,text)',
    'run_lms_pot_automation(uuid)',
    'scan_lms_automation()',
    'set_buy_back_decision(uuid,uuid,boolean)',
    'set_fixture_selection_block(bigint,boolean,text)',
    'set_pot_lifecycle(uuid,text)',
    'set_pot_player_payment(uuid,uuid,text)',
    'set_pot_status(uuid,text)',
    'set_pot_test_mode(uuid,boolean)',
    'set_test_pick_scenario(uuid,bigint,text)',
    'sync_fpl_data(text,jsonb,jsonb)'
  ]) signature));
select pg_temp.check_security('No anonymous application table or view reads',not exists(
  select 1 from pg_class c where c.relnamespace='public'::regnamespace and c.relkind in ('r','v','m')
  and not exists(select 1 from pg_depend d where d.classid='pg_class'::regclass and d.objid=c.oid and d.deptype='e')
  and has_table_privilege('anon',c.oid,'select')));

-- Exercise every non-trigger application function under the real anonymous role.
-- NULL arguments cannot bypass an EXECUTE denial; populated IDs are tested below.
set local role anon;
select set_config('request.jwt.claim.role','anon',true);
select set_config('request.jwt.claim.sub','',true);
do $$ declare f record; args text; begin
  for f in select p.* from pg_proc p where p.pronamespace='public'::regnamespace
    and p.prokind='f' and p.prorettype<>'trigger'::regtype
    and not exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.deptype='e')
  loop
    select string_agg('null::'||format_type(t,null),',' order by ord) into args
    from unnest(f.proargtypes) with ordinality a(t,ord);
    perform pg_temp.expect_denied('anon RPC '||f.oid::regprocedure::text,
      format('select public.%I(%s)',f.proname,coalesce(args,'')));
  end loop;
end $$;
select pg_temp.expect_denied('anon known fixture impact','select public.fixture_override_impact(-926701)');
select pg_temp.expect_denied('anon unknown fixture impact','select public.fixture_override_impact(999999999)');
select pg_temp.expect_denied('anon known fixture version','select public.fixture_effective_version(-926701)');
select pg_temp.expect_denied('anon unknown fixture version','select public.fixture_effective_version(999999999)');
select pg_temp.expect_denied('anon supplied pot','select public.get_pot_standings(''00000000-0000-0000-0000-000000026711'')');
select pg_temp.expect_denied('anon supplied player','select public.set_pot_player_payment(''00000000-0000-0000-0000-000000026711'',''00000000-0000-0000-0000-000000026703'',''paid'')');
-- Even a populated subject cannot replace the required database role grant.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026701',true);
select pg_temp.expect_denied('anon cannot use admin subject','select public.fixture_override_impact(-926701)');
select pg_temp.expect_denied('anon cannot use dashboard subject','select public.get_my_dashboard()');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026704',true);
select pg_temp.check_security('New account has dashboard without approval',public.get_my_dashboard()->'pots'='[]'::jsonb);
select pg_temp.check_security('Signup metadata cannot grant admin',not public.is_current_user_admin());
select pg_temp.check_security('Signup default remains approved',(select approved from public.profiles where id=auth.uid()));
select pg_temp.check_security('Signup creates no membership',not exists(select 1 from public.pot_players));
select pg_temp.expect_denied('New nonmember impact','select public.fixture_override_impact(-926701)');
select pg_temp.expect_denied('New nonmember version','select public.fixture_effective_version(-926701)');
select pg_temp.expect_denied('New nonmember pot','select public.get_pot_standings(''00000000-0000-0000-0000-000000026711'')','You are not assigned to this pot');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026702',true);
select pg_temp.check_security('Member dashboard contains only own pot',jsonb_array_length(public.get_my_dashboard()->'pots')=1
  and public.get_my_dashboard()->'pots'->0->>'id'='00000000-0000-0000-0000-000000026711');
select pg_temp.check_security('Member fixtures available',jsonb_array_length(public.get_pot_selection('00000000-0000-0000-0000-000000026711')->'fixtures')=1);
select pg_temp.check_security('Member teams available',jsonb_array_length(public.get_my_team_availability('00000000-0000-0000-0000-000000026711'))=2);
select pg_temp.check_security('Member payment presentation',public.get_pot_selection('00000000-0000-0000-0000-000000026711')->>'payment_status'='unpaid');
select pg_temp.check_security('Member buy-back presentation',public.get_my_dashboard()->'pots'->0 ? 'buy_back_payment_status');
select public.claim_pot_payment('00000000-0000-0000-0000-000000026711');
select pg_temp.check_security('Own payment claim works',(select payment_status='claimed' from public.pot_players where pot_id='00000000-0000-0000-0000-000000026711'));
select public.confirm_team_pick('00000000-0000-0000-0000-000000026711',-926701,-926701);
select pg_temp.check_security('Own pick and history work',jsonb_array_length(public.get_my_pot_history('00000000-0000-0000-0000-000000026711'))=1);
select pg_temp.check_security('Standings mask emails/payments/buy-back and unrevealed picks',not exists(
  select 1 from jsonb_array_elements(public.get_pot_standings('00000000-0000-0000-0000-000000026711')->'players') p
  where p->'email'<>'null'::jsonb or p->'payment_status'<>'null'::jsonb or p->'buy_back_status'<>'null'::jsonb or p->'picks'<>'[]'::jsonb));
select pg_temp.check_security('Other profiles hidden',not exists(select 1 from public.profiles where id<>auth.uid()));
select pg_temp.check_security('Other memberships hidden',not exists(select 1 from public.pot_players where player_id<>auth.uid()));
select pg_temp.check_security('Other picks hidden',not exists(select 1 from public.player_picks where player_id<>auth.uid()));
select pg_temp.check_security('Unrelated pots hidden',not exists(select 1 from public.pots where id='00000000-0000-0000-0000-000000026712'));
select pg_temp.check_security('Unrelated round data hidden',not exists(select 1 from public.pot_rounds where pot_id='00000000-0000-0000-0000-000000026712'));
select pg_temp.expect_denied('Member cannot inspect internal impact','select public.fixture_override_impact(-926701)');
select pg_temp.expect_denied('Member cannot inspect internal version','select public.fixture_effective_version(-926701)');
select pg_temp.expect_denied('Member cannot inspect raw effective result','select public.get_effective_fixture_result(-926701)');
select pg_temp.expect_denied('Member cannot change own role','update public.profiles set is_admin=true where id=auth.uid()');
select pg_temp.expect_denied('Member cannot mutate picks directly','update public.player_picks set team_id=-926702 where player_id=auth.uid()');
do $$ declare name text; begin
  foreach name in array array['get_pot_standings','get_pot_selection','get_my_pot_history','get_my_team_availability','claim_pot_payment','claim_buy_back'] loop
    perform pg_temp.expect_denied('Cross-pot '||name,format('select public.%I(''00000000-0000-0000-0000-000000026712'')',name),'You are not assigned to this pot');
  end loop;
end $$;
select pg_temp.expect_denied('Cross-pot deadline','select public.get_gameweek_deadline(''00000000-0000-0000-0000-000000026712'',1)','You are not assigned to this pot');
select pg_temp.expect_denied('Cross-pot pick','select public.confirm_team_pick(''00000000-0000-0000-0000-000000026712'',-926701,-926701)','You are not assigned to this pot');
select pg_temp.check_security('Cross-pot completion hidden',public.get_pot_completion('00000000-0000-0000-0000-000000026712') is null);
select pg_temp.check_security('Cross-pot rounds hidden',public.get_pot_rounds('00000000-0000-0000-0000-000000026712') is null);
select pg_temp.check_security('Cross-pot review hidden',public.get_my_pot_review_state('00000000-0000-0000-0000-000000026712') is null);
select pg_temp.check_security('Cross-pot adjudication hidden',public.get_my_pot_review_outcome('00000000-0000-0000-0000-000000026712') is null);
select pg_temp.check_security('Admin operations health hidden',public.get_lms_operations_health() is null);
select pg_temp.check_security('Admin automation status hidden',public.get_lms_automation_status('00000000-0000-0000-0000-000000026712') is null);
select pg_temp.expect_denied('Cross-user payment rejected','select public.set_pot_player_payment(''00000000-0000-0000-0000-000000026711'',''00000000-0000-0000-0000-000000026703'',''paid'')','Administrator access required');
select pg_temp.expect_denied('Cross-user buy-back rejected','select public.confirm_buy_back(''00000000-0000-0000-0000-000000026711'',''00000000-0000-0000-0000-000000026703'')','Administrator access required');
select pg_temp.expect_denied('Retired winner unrelated test pot','select public.complete_pot_with_winner(''00000000-0000-0000-0000-000000026712'',null)','Administrator access required');
select pg_temp.expect_denied('Retired winner unknown pot','select public.complete_pot_with_winner(''00000000-0000-0000-0000-000000026799'',null)','Administrator access required');
select pg_temp.expect_denied('Member admin result listing','select public.get_admin_fixture_results(''RPC-SECURITY'')','Administrator access required');
select pg_temp.expect_denied('Member correction preview','select public.preview_fixture_result_override(-926701,2,0,''finished'',''Security test'')','Administrator access required');
select pg_temp.expect_denied('Member correction creation','select public.create_fixture_result_override(-926701,2,0,''finished'',''Security test'',''guessed-version'')','Administrator access required');

-- Every administrator-only entry point must reject a normal player before
-- validating supplied IDs or reading private state.
do $$ declare f record; args text; begin
  for f in select p.* from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=any(array[
    'add_player_to_pot',
    'assign_random_missing_picks',
    'complete_pot_with_winner',
    'confirm_buy_back',
    'create_fixture_result_override',
    'create_pot',
    'delete_draft_pot',
    'fill_remaining_pot_gameweeks',
    'get_admin_fixture_results',
    'get_admin_pick_overview',
    'get_p1_provenance_backfill_report',
    'preview_fixture_result_override',
    'preview_lms_review_resolution',
    'process_pot_gameweek',
    'remove_player_from_pot',
    'reset_draft_test_pot',
    'reset_test_gameweek',
    'resolve_lms_review_case',
    'revoke_buy_back',
    'run_lms_pot_automation',
    'scan_lms_automation',
    'set_buy_back_decision',
    'set_fixture_selection_block',
    'set_pot_lifecycle',
    'set_pot_player_payment',
    'set_pot_status',
    'set_pot_test_mode',
    'set_test_pick_scenario',
    'sync_fpl_data'
  ]) loop
    select string_agg('null::'||format_type(t,null),',' order by ord) into args
    from unnest(f.proargtypes) with ordinality a(t,ord);
    perform pg_temp.expect_denied('Player denied admin RPC '||f.oid::regprocedure::text,
      format('select public.%I(%s)',f.proname,coalesce(args,'')),'Administrator access required');
  end loop;
end $$;

-- Real authenticated administrator, never service-role masquerading as a player.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026701',true);
select pg_temp.check_security('Admin identified',public.is_current_user_admin());
select pg_temp.check_security('Admin sees both pots',(select count(*)=2 from public.pots where season='RPC-SECURITY'));
select pg_temp.check_security('Admin sees players/payments',exists(
  select 1 from jsonb_array_elements(public.get_pot_standings('00000000-0000-0000-0000-000000026711')->'players') p
  where p->>'email'='security-member@example.test' and p->>'payment_status'='claimed'));
select pg_temp.check_security('Admin sees fixture results',jsonb_array_length(public.get_admin_fixture_results('RPC-SECURITY'))=2);
select pg_temp.expect_denied('Admin still cannot directly invoke helper','select public.fixture_override_impact(-926701)');
select pg_temp.expect_denied('Admin manual winner remains disabled','select public.complete_pot_with_winner(''00000000-0000-0000-0000-000000026711'',null)','Winner completion is determined by processing GW38');
select public.set_pot_player_payment('00000000-0000-0000-0000-000000026711','00000000-0000-0000-0000-000000026702','paid');
select pg_temp.check_security('Admin payment confirmation retained',(select payment_status='paid' from public.pot_players where pot_id='00000000-0000-0000-0000-000000026711' and player_id='00000000-0000-0000-0000-000000026702'));
do $$ declare preview jsonb; applied jsonb; begin
  preview:=public.preview_fixture_result_override(-926701,2,0,'finished','Security regression correction');
  perform pg_temp.check_security('Admin preview calls private helpers',jsonb_array_length(preview->'affected_pots')=2 and length(preview->>'effective_version')=32);
  applied:=public.create_fixture_result_override(-926701,2,0,'finished','Security regression correction',preview->>'effective_version');
  perform pg_temp.check_security('Admin correction creation retained',applied->>'override_id' is not null);
end $$;
reset role;
select pg_temp.check_security('Correction keeps trusted administrator attribution',exists(
  select 1 from public.fixture_result_overrides where fixture_id=-926701 and administrator_id='00000000-0000-0000-0000-000000026701'));
select pg_temp.check_security('Correction keeps audit attribution',exists(
  select 1 from public.admin_audit_events where action='fixture_result_overridden' and target_identifier='-926701' and administrator_id='00000000-0000-0000-0000-000000026701'));
select pg_temp.check_security('Cross-user payment unchanged',(select payment_status='unpaid' from public.pot_players where pot_id='00000000-0000-0000-0000-000000026711' and player_id='00000000-0000-0000-0000-000000026703'));
-- Synthetic read-model rows isolate name privacy from winner calculation (which
-- the existing GW38 suites exercise). Everything, including profiles, rolls back.
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
values('00000000-0000-0000-0000-000000026711',38,now()+interval '300 days');
insert into public.pot_completions(pot_id,round_id,gameweek_number,resolution_rule,entry_contribution_pence,buyback_contribution_pence,total_prize_pence,winner_count,completed_by)
select pot_id,id,38,'gw38_survivors',1000,0,1000,1,'00000000-0000-0000-0000-000000026701'
from public.pot_rounds where pot_id='00000000-0000-0000-0000-000000026711' and gameweek_number=38;
insert into public.pot_winners(pot_id,player_id,round_id,winner_reason,prize_share_pence,share_order)
select pot_id,'00000000-0000-0000-0000-000000026703',round_id,'gw38_survivor',1000,1
from public.pot_completions where pot_id='00000000-0000-0000-0000-000000026711';
insert into public.lms_review_cases(id,pot_id,case_type,summary,opened_source)
values('00000000-0000-0000-0000-000000026721','00000000-0000-0000-0000-000000026711','completed_pot_correction','Synthetic member privacy fixture','system');
insert into public.pot_completion_adjudications(id,pot_id,case_id,original_total_prize_pence,revision_number,reason,created_by)
values('00000000-0000-0000-0000-000000026722','00000000-0000-0000-0000-000000026711','00000000-0000-0000-0000-000000026721',1000,1,'Synthetic member privacy fixture','00000000-0000-0000-0000-000000026701');
insert into public.pot_adjudicated_winners(adjudication_id,player_id,prize_share_pence,share_order)
values('00000000-0000-0000-0000-000000026722','00000000-0000-0000-0000-000000026703',1000,1);

do $$ declare c record; result jsonb; begin
  for c in select * from (values
    ('signup email fallback',null::text,null::text,'security-other@example.test','Player'),
    ('case and whitespace email fallback','  ',null,'  SECURITY-OTHER@EXAMPLE.TEST  ','Player'),
    ('missing names',null,null,null,'Player'),
    ('real nickname',null,null,'Captain','Captain'),
    ('real name','Casey','Player','security-other@example.test','Casey Player')
  ) cases(label,first_name,last_name,display_name,expected_name) loop
    update public.profiles set first_name=c.first_name,last_name=c.last_name,display_name=c.display_name
    where id='00000000-0000-0000-0000-000000026703';
    perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026702',true);
    execute 'set local role authenticated';
    perform pg_temp.check_security(c.label||': real member role',current_user='authenticated' and not public.is_current_user_admin());
    select p into result from jsonb_array_elements(public.get_pot_standings('00000000-0000-0000-0000-000000026711')->'players') p
    where p->>'id'='00000000-0000-0000-0000-000000026703';
    perform pg_temp.check_security(c.label||': standings',result->>'name'=c.expected_name and result->'email'='null'::jsonb);
    result:=public.get_pot_completion('00000000-0000-0000-0000-000000026711')->'winners'->0;
    perform pg_temp.check_security(c.label||': original winner',result->>'name'=c.expected_name and result->>'prize_share_pence'='1000');
    result:=public.get_my_pot_review_outcome('00000000-0000-0000-0000-000000026711')->'winners'->0;
    perform pg_temp.check_security(c.label||': adjudicated winner',result->>'name'=c.expected_name and result->>'prize_share_pence'='1000');
    execute 'reset role';
  end loop;
end $$;
set local role authenticated;
select pg_temp.expect_denied('Name helper is internal','select public.lms_player_display_name(null,null,null,null)');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026701',true);
select pg_temp.check_security('Admin retains contact email',exists(select 1 from jsonb_array_elements(public.get_pot_standings('00000000-0000-0000-0000-000000026711')->'players') p where p->>'email'='security-other@example.test'));
reset role;

select 'PASS RPC security: '||count(*)||' assertions (including '||count(*) filter(where label like 'anon RPC %')||' anonymous function calls).' from rpc_security_results;
rollback;
