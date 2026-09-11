-- Phase 2G executable verification. Disposable local database only.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000010001','authenticated','authenticated','2g1@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000010002','authenticated','authenticated','2g2@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000010003','authenticated','authenticated','2g3@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000010004','authenticated','authenticated','2g4@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
update public.profiles set first_name='Player '||right(id::text,1),approved=true where id::text like '00000000-0000-0000-0000-00000001000%';
create temporary table g as select id admin_id from public.profiles where is_admin limit 1;
select set_config('request.jwt.claim.sub',(select admin_id::text from g),true);
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values(-101101,'PHASE2G',-101101,-101101,'G Home','GH',now()),(-101102,'PHASE2G',-101102,-101102,'G Away','GA',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values(-101201,-101201,'PHASE2G',38,now()+interval '1 day',-101101,-101102,false,false,false,'scheduled',false,now(),now());

-- Mixed unused entitlements: only two available entrants win; odd penny is deterministic.
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at) select '00000000-0000-0000-0000-000000010101','2G mixed','PHASE2G',1000,1,'draft',admin_id,true,'in_progress',now() from g;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('00000000-0000-0000-0000-000000010101',38,now()+interval '1 day');
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status,joined_at) select '00000000-0000-0000-0000-000000010101',id,'active','paid','available',now()+row_number() over(order by id)*interval '1 second' from public.profiles where id::text like '00000000-0000-0000-0000-00000001000%';
update public.pot_players set buy_back_status='confirmed',buy_back_claimed_at=now(),buy_back_used_at=now(),buy_back_payment_status='received',buy_back_confirmed_at=now() where pot_id='00000000-0000-0000-0000-000000010101' and player_id='00000000-0000-0000-0000-000000010003';
update public.pot_players set buy_back_status='requested',buy_back_claimed_at=now(),buy_back_used_at=now(),buy_back_payment_status='pending' where pot_id='00000000-0000-0000-0000-000000010101' and player_id='00000000-0000-0000-0000-000000010004';
insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
select '00000000-0000-0000-0000-000000010101',player_id,38,-101201,-101101,'manual','pending',38,-101101,-101102,now()+interval '1 day' from public.pot_players where pot_id='00000000-0000-0000-0000-000000010101';
insert into public.pot_fixture_test_results(pot_id,fixture_id,home_score,away_score) values('00000000-0000-0000-0000-000000010101',-101201,0,1);
do $$ declare r jsonb; begin
 r:=public.process_pot_gameweek('00000000-0000-0000-0000-000000010101',38,true);
 if not (r->>'completed')::boolean or (r->>'winner_count')::integer<>2 or (r->>'resolution_rule')<>'gw38_buyback_eligible_split' then raise exception 'Mixed fallback incorrect: %',r; end if;
 if (select sum(prize_share_pence) from public.pot_winners where pot_id='00000000-0000-0000-0000-000000010101')<>4001 then raise exception 'Prize shares do not conserve the paid/received pot'; end if;
 if (select array_agg(prize_share_pence order by share_order) from public.pot_winners where pot_id='00000000-0000-0000-0000-000000010101')<>array[2001,2000] then raise exception 'Deterministic remainder split incorrect'; end if;
 r:=public.process_pot_gameweek('00000000-0000-0000-0000-000000010101',38,true);
 if not (r->>'already_finalized')::boolean or (select count(*) from public.pot_winners where pot_id='00000000-0000-0000-0000-000000010101')<>2 then raise exception 'Finalization retry not idempotent'; end if;
 if exists(select 1 from public.round_collective_reinstatements where pot_id='00000000-0000-0000-0000-000000010101') or exists(select 1 from public.pot_rounds where pot_id='00000000-0000-0000-0000-000000010101' and gameweek_number>38) then raise exception 'GW38 replay/GW39 created'; end if;
 if exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000010101' and player_id in('00000000-0000-0000-0000-000000010001','00000000-0000-0000-0000-000000010002') and buy_back_status<>'available') then raise exception 'GW38 fallback consumed an entitlement'; end if;
 if has_table_privilege('authenticated','public.pot_winners','insert') or has_table_privilege('authenticated','public.pot_completions','update') or has_function_privilege('authenticated','public.finalize_gw38_pot(uuid)','execute') then raise exception 'Winner mutation path exposed'; end if;
 perform public.reset_draft_test_pot('00000000-0000-0000-0000-000000010101');
 if exists(select 1 from public.pot_completions where pot_id='00000000-0000-0000-0000-000000010101') then raise exception 'Test reset retained completion'; end if;
end $$;

create or replace function pg_temp.verify_gw38_case(case_pot uuid,case_name text,available_flags boolean[],win_flags boolean[],expected_rule text,expected_winners integer) returns void language plpgsql as $$
declare admin_id uuid; player_ids uuid[]:=array['00000000-0000-0000-0000-000000010001','00000000-0000-0000-0000-000000010002','00000000-0000-0000-0000-000000010003','00000000-0000-0000-0000-000000010004']::uuid[]; i integer; result jsonb;
begin
 select id into admin_id from public.profiles where is_admin limit 1;
 insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at) values(case_pot,case_name,'PHASE2G',1000,1000,'draft',admin_id,true,'in_progress',now());
 insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values(case_pot,38,now()+interval '1 day');
 for i in 1..4 loop
  insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status,buy_back_claimed_at,buy_back_used_at,buy_back_payment_status,buy_back_confirmed_at,joined_at)
  values(case_pot,player_ids[i],'active','paid',case when available_flags[i] then 'available' else 'confirmed' end,
   case when available_flags[i] then null else now() end,case when available_flags[i] then null else now() end,
   case when available_flags[i] then 'not_due' else 'received' end,case when available_flags[i] then null else now() end,now()+i*interval '1 second');
  insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
  values(case_pot,player_ids[i],38,-101201,case when win_flags[i] then -101101 else -101102 end,'manual','pending',38,-101101,-101102,now()+interval '1 day');
 end loop;
 insert into public.pot_fixture_test_results(pot_id,fixture_id,home_score,away_score) values(case_pot,-101201,1,0);
 result:=public.process_pot_gameweek(case_pot,38,true);
 if (result->>'resolution_rule')<>expected_rule or (result->>'winner_count')::integer<>expected_winners then raise exception '% failed: %',case_name,result; end if;
 if (select sum(prize_share_pence) from public.pot_winners where pot_id=case_pot)<>(select total_prize_pence from public.pot_completions where pot_id=case_pot) then raise exception '% failed prize conservation',case_name; end if;
end $$;
select pg_temp.verify_gw38_case('00000000-0000-0000-0000-000000010102','normal sole',array[true,true,true,true],array[true,false,false,false],'gw38_survivors',1);
select pg_temp.verify_gw38_case('00000000-0000-0000-0000-000000010103','normal multiple',array[true,true,true,true],array[true,true,false,false],'gw38_survivors',2);
select pg_temp.verify_gw38_case('00000000-0000-0000-0000-000000010104','all lose none unused',array[false,false,false,false],array[false,false,false,false],'gw38_all_lost_split',4);
select pg_temp.verify_gw38_case('00000000-0000-0000-0000-000000010105','all lose all unused',array[true,true,true,true],array[false,false,false,false],'gw38_all_lost_split',4);
select pg_temp.verify_gw38_case('00000000-0000-0000-0000-000000010106','all lose one unused',array[true,false,false,false],array[false,false,false,false],'gw38_buyback_eligible_split',1);

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,review_status,review_reason) select '00000000-0000-0000-0000-000000010107','review blocked','PHASE2G',1000,1000,'draft',admin_id,true,'review','needs_review','Unresolved result' from g;
do $$ declare r jsonb; begin r:=public.process_pot_gameweek('00000000-0000-0000-0000-000000010107',38,true); if not (r->>'review_required')::boolean or exists(select 1 from public.pot_completions where pot_id='00000000-0000-0000-0000-000000010107') then raise exception 'Review did not block completion: %',r; end if; end $$;
rollback;
