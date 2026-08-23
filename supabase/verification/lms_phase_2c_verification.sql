-- Phase 2C executable verification. Disposable local database only.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000006001','authenticated','authenticated','2c-one@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000006002','authenticated','authenticated','2c-two@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
create temporary table phase2c_context as select id admin_id from public.profiles where is_admin limit 1;
select set_config('request.jwt.claim.sub',(select admin_id::text from phase2c_context),true);
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
(-61101,'PHASE2C',-61101,-61101,'C Arsenal','CA',now()),(-61102,'PHASE2C',-61102,-61102,'C Liverpool','CL',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values
(-61201,-61201,'PHASE2C',1,now()+interval '1 day',-61101,-61102,false,false,false,'scheduled',false,now(),now()),
(-61202,-61202,'PHASE2C',2,now()+interval '8 days',-61101,-61102,false,false,false,'scheduled',false,now(),now()),
(-61203,-61203,'PHASE2C',3,now()+interval '15 days',-61101,-61102,false,false,false,'scheduled',false,now(),now());
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status)
select '00000000-0000-0000-0000-000000006101','2C A','PHASE2C',1000,1000,'open',admin_id,'open' from phase2c_context;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values
('00000000-0000-0000-0000-000000006101',1,now()+interval '1 day'),('00000000-0000-0000-0000-000000006101',2,now()+interval '8 days'),('00000000-0000-0000-0000-000000006101',3,now()+interval '15 days');
insert into public.pot_players(pot_id,player_id) values
('00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006001'),
('00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006002');
do $$ begin
 if (select count(*) from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000006101')<>2 then raise exception 'Initial cycles missing'; end if;
 begin insert into public.pot_player_team_cycles(pot_id,player_id,cycle_number) values('00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006001',1); raise exception 'Duplicate cycle accepted'; exception when unique_violation then null; end;
end $$;
insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
values(-61301,'00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006001',1,-61201,-61101,'manual','pending',1,-61101,-61102,now()+interval '1 day'),
(-61302,'00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006002',1,-61201,-61101,'manual','pending',1,-61101,-61102,now()+interval '1 day');
do $$ begin
 begin insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
 values(-61303,'00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006001',2,-61202,-61101,'manual','pending',2,-61101,-61102,now()+interval '8 days'); raise exception 'Same-cycle reuse accepted'; exception when unique_violation then null; end;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000006001',true);
do $$ declare availability jsonb; begin
 availability:=public.get_my_team_availability('00000000-0000-0000-0000-000000006101');
 if coalesce((select (team->>'available')::boolean from jsonb_array_elements(availability) team where (team->>'id')::bigint=-61101),true)
  or not coalesce((select (team->>'available')::boolean from jsonb_array_elements(availability) team where (team->>'id')::bigint=-61102),false) then
  raise exception 'Cycle 1 availability is incorrect: %',availability; end if;
end $$;
select set_config('request.jwt.claim.sub',(select admin_id::text from phase2c_context),true);
update public.pot_player_team_cycles set closed_at=now() where pot_id='00000000-0000-0000-0000-000000006101' and player_id='00000000-0000-0000-0000-000000006001' and cycle_number=1;
insert into public.pot_player_team_cycles(pot_id,player_id,cycle_number) values('00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006001',2);
insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
values(-61304,'00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006001',2,-61202,-61101,'manual','pending',2,-61101,-61102,now()+interval '8 days');
do $$ declare c1 uuid; c2 uuid; begin
 select id into c1 from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000006101' and player_id='00000000-0000-0000-0000-000000006001' and cycle_number=1;
 select id into c2 from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000006101' and player_id='00000000-0000-0000-0000-000000006001' and cycle_number=2;
 if not exists(select 1 from public.player_picks where id=-61301 and team_cycle_id=c1 and round_id is not null)
  or not exists(select 1 from public.player_picks where id=-61304 and team_cycle_id=c2) then raise exception 'Cycle/round linkage failed'; end if;
 begin insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
 values(-61305,'00000000-0000-0000-0000-000000006101','00000000-0000-0000-0000-000000006001',3,-61203,-61101,'manual','pending',3,-61101,-61102,now()+interval '15 days'); raise exception 'Cycle 2 duplicate accepted'; exception when unique_violation then null; end;
end $$;
do $$ begin
 if has_table_privilege('authenticated','public.pot_player_team_cycles','insert') or has_table_privilege('authenticated','public.pot_player_team_cycles','update') then raise exception 'Client cycle mutation grant exists'; end if;
 if has_function_privilege('authenticated','public.current_team_cycle_id(uuid,uuid)','execute') or has_function_privilege('anon','public.link_pick_to_team_cycle()','execute') then raise exception 'Cycle helper exposed'; end if;
end $$;
rollback;
