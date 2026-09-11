-- LMS Integrity Phase 1 executable verification.
-- DISPOSABLE SUPABASE-COMPATIBLE DATABASE ONLY. Never run remotely.
-- Requires modules 1-22, P1, P2, the Phase 1 migration, and one admin profile.

begin;

create temporary table phase1_context(admin_id uuid not null) on commit drop;
insert into phase1_context select id from public.profiles where is_admin order by created_at limit 1;
do $$ begin
  if not exists(select 1 from phase1_context) then
    raise exception 'Phase 1 verification requires one disposable administrator profile';
  end if;
end; $$;
select set_config('request.jwt.claim.sub',(select admin_id::text from phase1_context),true);

insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
  (-31101,'PHASE1-VERIFY',-31101,-31101,'Phase 1 A','P1A',now()),
  (-31102,'PHASE1-VERIFY',-31102,-31102,'Phase 1 B','P1B',now()),
  (-31103,'PHASE1-VERIFY',-31103,-31103,'Phase 1 C','P1C',now()),
  (-31104,'PHASE1-VERIFY',-31104,-31104,'Phase 1 D','P1D',now());

insert into public.football_fixtures(
  id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,
  home_score,away_score,started,finished,provisional_start_time,status,
  finished_provisional,provider_synced_at,updated_at
) values
  (-31201,-31201,'PHASE1-VERIFY',1,now()+interval '1 day',-31101,-31102,null,null,false,false,false,'scheduled',false,now(),now()),
  (-31202,-31202,'PHASE1-VERIFY',2,now()+interval '8 days',-31103,-31104,null,null,false,false,false,'scheduled',false,now(),now()),
  (-31203,-31203,'PHASE1-VERIFY',3,now()-interval '1 day',-31101,-31102,2,0,true,true,false,'finished',false,now(),now()),
  (-31204,-31204,'PHASE1-VERIFY',3,now()+interval '1 day',-31103,-31104,null,null,false,false,false,'scheduled',false,now(),now()),
  (-31205,-31205,'PHASE1-VERIFY',4,now()-interval '1 hour',-31101,-31102,null,null,false,false,false,'scheduled',false,now(),now()),
  (-31206,-31206,'PHASE1-VERIFY',5,now()+interval '2 days',-31101,-31102,null,null,false,false,false,'scheduled',false,now(),now()),
  (-31207,-31207,'PHASE1-VERIFY',2,now()+interval '8 days',-31101,-31102,null,null,false,false,false,'scheduled',false,now(),now());

-- Process -> reset -> loss, then reset -> win. Reset must delete immutable picks.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode)
select '00000000-0000-0000-0000-000000003101','Phase 1 reset','PHASE1-VERIFY',0,0,'draft',admin_id,true from phase1_context;
insert into public.pot_gameweeks(pot_id,gameweek_number) values
  ('00000000-0000-0000-0000-000000003101',1),
  ('00000000-0000-0000-0000-000000003101',2);
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000003101',admin_id,'active','paid','available' from phase1_context;

insert into public.player_picks(
  id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
  selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at
) select -31301,'00000000-0000-0000-0000-000000003101',admin_id,1,-31201,-31101,'manual','pending',1,-31101,-31102,
  (select kickoff_at from public.football_fixtures where id=-31201) from phase1_context;
select public.set_test_pick_scenario('00000000-0000-0000-0000-000000003101',-31301,'won');
select public.process_pot_gameweek('00000000-0000-0000-0000-000000003101',1,true);
do $$ begin
  if not exists(select 1 from public.player_picks where id=-31301 and outcome='won' and resolved_at is not null and result_source='test') then
    raise exception 'Initial test win did not resolve';
  end if;
  begin
    perform public.complete_pot_with_winner('00000000-0000-0000-0000-000000003101',(select admin_id from phase1_context));
    raise exception 'Test pot winner completion was accepted';
  exception when raise_exception then
    if sqlerrm<>'A pot in test mode cannot be completed' then raise; end if;
  end;
end; $$;

select public.reset_test_gameweek('00000000-0000-0000-0000-000000003101',1);
do $$ begin
  if exists(select 1 from public.player_picks where id=-31301)
    or exists(select 1 from public.pot_gameweek_processes where pot_id='00000000-0000-0000-0000-000000003101' and gameweek_number=1) then
    raise exception 'Test gameweek reset retained immutable gameplay state';
  end if;
end; $$;

insert into public.player_picks(
  id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
  selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at
) select -31302,'00000000-0000-0000-0000-000000003101',admin_id,1,-31201,-31101,'manual','pending',1,-31101,-31102,
  (select kickoff_at from public.football_fixtures where id=-31201) from phase1_context;
select public.set_test_pick_scenario('00000000-0000-0000-0000-000000003101',-31302,'lost');
select public.process_pot_gameweek('00000000-0000-0000-0000-000000003101',1,true);
do $$ begin
  if not exists(select 1 from public.player_picks where id=-31302 and outcome='lost' and resolved_at is not null)
    or not exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000003101' and player_status='active' and buy_back_status='available' and buy_back_used_at is null) then
    raise exception 'Win-reset-loss did not preserve the loss and collectively reinstate the sole cohort';
  end if;
end; $$;

select public.reset_test_gameweek('00000000-0000-0000-0000-000000003101',1);
insert into public.player_picks(
  id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
  selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at
) select -31303,'00000000-0000-0000-0000-000000003101',admin_id,1,-31201,-31101,'manual','pending',1,-31101,-31102,
  (select kickoff_at from public.football_fixtures where id=-31201) from phase1_context;
select public.set_test_pick_scenario('00000000-0000-0000-0000-000000003101',-31303,'won');
select public.process_pot_gameweek('00000000-0000-0000-0000-000000003101',1,true);
do $$ begin
  if not exists(select 1 from public.player_picks where id=-31303 and outcome='won' and resolved_at is not null)
    or not exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000003101' and player_status='active') then
    raise exception 'Loss-reset-win did not apply the second result';
  end if;
  begin
    perform public.set_pot_test_mode('00000000-0000-0000-0000-000000003101',false);
    raise exception 'Dirty test mode was disabled';
  exception when raise_exception then
    if sqlerrm<>'Reset all test progress before disabling test mode' then raise; end if;
  end;
end; $$;
select public.reset_draft_test_pot('00000000-0000-0000-0000-000000003101');
select public.set_pot_test_mode('00000000-0000-0000-0000-000000003101',false);
do $$ begin
  if exists(select 1 from public.player_picks where pot_id='00000000-0000-0000-0000-000000003101')
    or exists(select 1 from public.pot_gameweek_processes where pot_id='00000000-0000-0000-0000-000000003101')
    or exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000003101'
      and (player_status<>'active' or buy_back_status<>'available')) then raise exception 'Full test reset left contamination'; end if;
end; $$;

-- Current round enforcement through the public RPC.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode)
select '00000000-0000-0000-0000-000000003102','Phase 1 round','PHASE1-VERIFY',0,0,'active',admin_id,false from phase1_context;
insert into public.pot_gameweeks(pot_id,gameweek_number) values
  ('00000000-0000-0000-0000-000000003102',1),('00000000-0000-0000-0000-000000003102',2);
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000003102',admin_id,'active','paid','available' from phase1_context;
do $$ begin
  begin
    perform public.confirm_team_pick('00000000-0000-0000-0000-000000003102',-31202,-31103);
    raise exception 'Future gameweek pick was accepted';
  exception when raise_exception then
    if sqlerrm<>'Selections are only accepted for the current gameweek' then raise; end if;
  end;
  perform public.confirm_team_pick('00000000-0000-0000-0000-000000003102',-31201,-31101);
  if not exists(select 1 from public.player_picks where pot_id='00000000-0000-0000-0000-000000003102' and gameweek_number=1) then
    raise exception 'Current gameweek pick was rejected';
  end if;
  begin
    perform public.confirm_team_pick('00000000-0000-0000-0000-000000003102',-31201,-31102);
    raise exception 'Duplicate round pick was accepted';
  exception when raise_exception then
    if sqlerrm<>'Your pick for this gameweek is already locked' then raise; end if;
  end;
end; $$;
insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by)
select '00000000-0000-0000-0000-000000003102',1,false,'{}',admin_id from phase1_context;
do $$ begin
  begin
    perform public.confirm_team_pick('00000000-0000-0000-0000-000000003102',-31201,-31102);
    raise exception 'Past gameweek pick was accepted';
  exception when raise_exception then
    if sqlerrm<>'Selections are only accepted for the current gameweek' then raise; end if;
  end;
  begin
    perform public.confirm_team_pick('00000000-0000-0000-0000-000000003102',-31207,-31101);
    raise exception 'Previously used team was accepted in a later round';
  exception when raise_exception then
    if sqlerrm<>'You have already used that team in this pot' then raise; end if;
  end;
  perform public.confirm_team_pick('00000000-0000-0000-0000-000000003102',-31202,-31103);
end; $$;

-- A separate pot derives its own current round.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode)
select '00000000-0000-0000-0000-000000003106','Phase 1 other pot','PHASE1-VERIFY',0,0,'active',admin_id,false from phase1_context;
insert into public.pot_gameweeks(pot_id,gameweek_number) values('00000000-0000-0000-0000-000000003106',1);
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000003106',admin_id,'active','paid','available' from phase1_context;
select public.confirm_team_pick('00000000-0000-0000-0000-000000003106',-31201,-31102);

-- Random selection excludes the completed fixture and uses only the upcoming one.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode)
select '00000000-0000-0000-0000-000000003103','Phase 1 random','PHASE1-VERIFY',0,0,'active',admin_id,false from phase1_context;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
values('00000000-0000-0000-0000-000000003103',2,now()-interval '8 days'),
      ('00000000-0000-0000-0000-000000003103',3,now()-interval '1 day');
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000003103',admin_id,'active','paid','available' from phase1_context;
insert into public.player_picks(
  pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
  selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at,
  resolved_home_team_id,resolved_away_team_id,resolved_home_score,resolved_away_score,result_source,resolved_at,
  resolved_fixture_season,resolved_fixture_status
) select '00000000-0000-0000-0000-000000003103',admin_id,2,-31202,-31103,'manual','won',2,-31103,-31104,
  kickoff_at,-31103,-31104,1,0,'test',now(),'PHASE1-VERIFY','finished'
  from phase1_context cross join public.football_fixtures where id=-31202;
insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by)
select '00000000-0000-0000-0000-000000003103',2,false,'{}',admin_id from phase1_context;
select public.assign_random_missing_picks('00000000-0000-0000-0000-000000003103',3,true);
do $$ begin
  if not exists(select 1 from public.player_picks where pot_id='00000000-0000-0000-0000-000000003103' and fixture_id=-31204 and team_id=-31104)
    or exists(select 1 from public.player_picks where pot_id='00000000-0000-0000-0000-000000003103' and fixture_id=-31203) then
    raise exception 'Random assignment selected an already-played fixture or a used team';
  end if;
end; $$;

-- No eligible future fixture produces a blocking preview, not an invented outcome.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode)
select '00000000-0000-0000-0000-000000003107','Phase 1 no candidate','PHASE1-VERIFY',0,0,'active',admin_id,false from phase1_context;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
values('00000000-0000-0000-0000-000000003107',4,now()-interval '1 hour');
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000003107',admin_id,'active','paid','available' from phase1_context;
do $$ declare preview jsonb; begin
  preview:=public.assign_random_missing_picks('00000000-0000-0000-0000-000000003107',4,false);
  if (preview->>'ready')::boolean or not (preview->'problems') ? 'No eligible unstarted fixture remains for random assignment.' then
    raise exception 'No-candidate random assignment did not block cleanly: %',preview;
  end if;
  begin
    perform public.confirm_team_pick('00000000-0000-0000-0000-000000003107',-31205,-31101);
    raise exception 'Late direct pick was accepted';
  exception when raise_exception then
    if sqlerrm<>'The gameweek pick deadline has passed' then raise; end if;
  end;
end; $$;

-- A closed stored deadline cannot move forward after provider rescheduling.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode)
select '00000000-0000-0000-0000-000000003104','Phase 1 deadline','PHASE1-VERIFY',0,0,'active',admin_id,false from phase1_context;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
values('00000000-0000-0000-0000-000000003104',4,now()-interval '1 hour');
create temporary table original_deadline(value timestamptz not null) on commit drop;
insert into original_deadline select pick_deadline_at from public.pot_gameweeks
where pot_id='00000000-0000-0000-0000-000000003104' and gameweek_number=4;
select public.sync_fpl_data('PHASE1-VERIFY',
  '[{"id":-31101,"code":-31101,"name":"Phase 1 A","short_name":"P1A"},{"id":-31102,"code":-31102,"name":"Phase 1 B","short_name":"P1B"}]'::jsonb,
  jsonb_build_array(jsonb_build_object('id',-31205,'event',4,'kickoff_time',to_char(now()+interval '3 days','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'team_h',-31101,'team_a',-31102,'team_h_score',null,'team_a_score',null,'started',false,'finished',false,
    'finished_provisional',false,'provisional_start_time',false)));
do $$ begin
  if (select pick_deadline_at from public.pot_gameweeks where pot_id='00000000-0000-0000-0000-000000003104' and gameweek_number=4)
    is distinct from (select value from original_deadline) then raise exception 'A closed deadline reopened after rescheduling'; end if;
end; $$;

-- Referenced fixture mutation is snapshotted, flagged, and blocks processing.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode)
select '00000000-0000-0000-0000-000000003105','Phase 1 mutation','PHASE1-VERIFY',0,0,'active',admin_id,false from phase1_context;
insert into public.pot_gameweeks(pot_id,gameweek_number) values('00000000-0000-0000-0000-000000003105',5);
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000003105',admin_id,'active','paid','available' from phase1_context;
insert into public.player_picks(
  id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
  selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at
) select -31305,'00000000-0000-0000-0000-000000003105',admin_id,5,-31206,-31101,'manual','pending',5,-31101,-31102,kickoff_at
  from phase1_context cross join public.football_fixtures where id=-31206;
select public.sync_fpl_data('PHASE1-VERIFY',
  '[{"id":-31101,"code":-31101,"name":"Phase 1 A","short_name":"P1A"},{"id":-31102,"code":-31102,"name":"Phase 1 B","short_name":"P1B"}]'::jsonb,
  jsonb_build_array(jsonb_build_object('id',-31206,'event',6,'kickoff_time',to_char(now()+interval '2 days','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'team_h',-31101,'team_a',-31102,'team_h_score',null,'team_a_score',null,'started',false,'finished',false,
    'finished_provisional',false,'provisional_start_time',false)));
do $$ declare preview jsonb; begin
  if not exists(select 1 from public.player_picks where id=-31305 and fixture_context_changed
    and selected_fixture_gameweek=5) then raise exception 'Fixture mutation did not preserve and flag selection context'; end if;
  if not exists(select 1 from public.pots where id='00000000-0000-0000-0000-000000003105' and review_status='needs_review') then
    raise exception 'Fixture mutation did not flag its pot';
  end if;
  preview:=public.process_pot_gameweek('00000000-0000-0000-0000-000000003105',5,false);
  if (preview->>'ready')::boolean or not (preview->'problems') ? 'Referenced fixture context changed; administrator review is required before processing' then
    raise exception 'Fixture mutation did not block processing clearly: %',preview;
  end if;
end; $$;

-- Catalog/security expectations.
do $$ begin
  if not exists(select 1 from pg_class where oid='public.player_picks'::regclass and relrowsecurity)
    or not exists(select 1 from pg_class where oid='public.pot_gameweeks'::regclass and relrowsecurity) then
    raise exception 'Expected RLS is not enabled';
  end if;
  if has_function_privilege('anon','public.current_pot_gameweek(uuid)','EXECUTE')
    or has_function_privilege('authenticated','public.current_pot_gameweek(uuid)','EXECUTE')
    or has_function_privilege('anon','public.refresh_open_pot_gameweek_deadlines(text)','EXECUTE')
    or has_function_privilege('authenticated','public.refresh_open_pot_gameweek_deadlines(text)','EXECUTE')
    or has_function_privilege('anon','public.set_initial_pot_gameweek_deadline()','EXECUTE')
    or has_function_privilege('authenticated','public.set_initial_pot_gameweek_deadline()','EXECUTE') then
    raise exception 'An internal Phase 1 helper is executable by a client role';
  end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.player_picks'::regclass
    and tgname='player_picks_resolution_snapshot_immutable' and not tgisinternal) then
    raise exception 'Provenance immutability trigger is missing';
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.player_picks'::regclass
    and contype='u' and pg_get_constraintdef(oid) like '%pot_id, player_id, gameweek_number%') then
    raise exception 'Concurrent duplicate-round protection is missing';
  end if;
end; $$;

rollback;
