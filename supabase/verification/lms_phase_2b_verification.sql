-- Phase 2B executable verification. Disposable local database only.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000005001','authenticated','authenticated','2b-one@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000005002','authenticated','authenticated','2b-two@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
create temporary table phase2b_context as select id admin_id from public.profiles where is_admin limit 1;
select set_config('request.jwt.claim.sub',(select admin_id::text from phase2b_context),true);
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
(-51101,'PHASE2B',-51101,-51101,'B One','B1',now()),(-51102,'PHASE2B',-51102,-51102,'B Two','B2',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,home_score,away_score,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values
(-51201,-51201,'PHASE2B',4,now()+interval '1 day',-51101,-51102,null,null,false,false,false,'scheduled',false,now(),now()),
(-51202,-51202,'PHASE2B',5,now()+interval '8 days',-51101,-51102,null,null,false,false,false,'scheduled',false,now(),now());
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status)
select '00000000-0000-0000-0000-000000005101','2B pot','PHASE2B',1000,1000,'open',admin_id,'open' from phase2b_context;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values
('00000000-0000-0000-0000-000000005101',4,now()+interval '1 day'),('00000000-0000-0000-0000-000000005101',5,now()+interval '8 days');
insert into public.pot_players(pot_id,player_id,player_status,payment_status) values
('00000000-0000-0000-0000-000000005101','00000000-0000-0000-0000-000000005001','active','unpaid'),
('00000000-0000-0000-0000-000000005101','00000000-0000-0000-0000-000000005002','active','paid');

do $$ begin
 if (select count(*) from public.pot_rounds where pot_id='00000000-0000-0000-0000-000000005101')<>2
   or not exists(select 1 from public.pot_rounds where pot_id='00000000-0000-0000-0000-000000005101' and sequence_number=1 and gameweek_number=4) then raise exception 'Round creation/mapping failed'; end if;
 begin insert into public.pot_rounds(pot_id,sequence_number,gameweek_number) values('00000000-0000-0000-0000-000000005101',1,5); raise exception 'Duplicate sequence accepted';
 exception when unique_violation then null; end;
end $$;

insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
 selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
values(-51301,'00000000-0000-0000-0000-000000005101','00000000-0000-0000-0000-000000005001',4,-51201,-51101,'manual','pending',4,-51101,-51102,now()+interval '1 day'),
(-51302,'00000000-0000-0000-0000-000000005101','00000000-0000-0000-0000-000000005002',4,-51201,-51102,'manual','pending',4,-51101,-51102,now()+interval '1 day');
insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by)
select '00000000-0000-0000-0000-000000005101',4,false,'{}',admin_id from phase2b_context;

do $$ declare round4 uuid; begin
 select id into round4 from public.pot_rounds where pot_id='00000000-0000-0000-0000-000000005101' and gameweek_number=4;
 if (select count(*) from public.pot_round_players where round_id=round4)<>2
  or exists(select 1 from public.player_picks where gameweek_number=4 and round_id<>round4)
  or not exists(select 1 from public.pot_gameweek_processes where round_id=round4) then raise exception 'Cohort/pick/process linkage failed'; end if;
 update public.pot_players set payment_status='paid',player_status='eliminated' where pot_id='00000000-0000-0000-0000-000000005101';
 update public.profiles set approved=true where id='00000000-0000-0000-0000-000000005001';
 if (select count(*) from public.pot_round_players where round_id=round4)<>2 then raise exception 'Historical cohort changed'; end if;
 begin update public.pot_round_players set entry_reason='normal' where round_id=round4; raise exception 'Final cohort mutation accepted';
 exception when raise_exception then if sqlerrm<>'A finalized LMS round cohort is immutable' then raise; end if; end;
end $$;

update public.pot_players set player_status=case when player_id='00000000-0000-0000-0000-000000005001' then 'active' else 'eliminated' end
where pot_id='00000000-0000-0000-0000-000000005101';
insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
 selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
values(-51303,'00000000-0000-0000-0000-000000005101','00000000-0000-0000-0000-000000005001',5,-51202,-51102,'manual','pending',5,-51101,-51102,now()+interval '8 days');
do $$ declare round5 uuid; begin
 select id into round5 from public.pot_rounds where pot_id='00000000-0000-0000-0000-000000005101' and gameweek_number=5;
 if (select count(*) from public.pot_round_players where round_id=round5)<>1
  or not exists(select 1 from public.pot_round_players where round_id=round5 and player_id='00000000-0000-0000-0000-000000005001') then
   raise exception 'Later-round survivor cohort is incorrect'; end if;
end $$;
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status)
select '00000000-0000-0000-0000-000000005102','2B second','PHASE2B',1000,1000,'open',admin_id,'open' from phase2b_context;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values
('00000000-0000-0000-0000-000000005102',5,now()+interval '8 days');
do $$ begin if not exists(select 1 from public.pot_rounds where pot_id='00000000-0000-0000-0000-000000005102' and sequence_number=1 and gameweek_number=5)
 then raise exception 'Independent pot round sequence failed'; end if; end $$;

do $$ begin
 if has_function_privilege('authenticated','public.link_pick_to_lms_round()','execute')
  or has_function_privilege('anon','public.link_process_to_lms_round()','execute') then raise exception 'Internal helper exposed'; end if;
 if has_table_privilege('authenticated','public.pot_round_players','insert') or has_table_privilege('authenticated','public.pot_rounds','update') then raise exception 'Client cohort mutation grant exists'; end if;
 if not exists(select 1 from pg_trigger where tgname='pot_round_players_finalized_immutable' and not tgisinternal) then raise exception 'Cohort immutability trigger missing'; end if;
end $$;
rollback;
