-- Phase 2E executable verification. Disposable local database only.
begin;
create temporary table e as select id admin_id from public.profiles where is_admin limit 1;
select set_config('request.jwt.claim.sub',(select admin_id::text from e),true);
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
(-81101,'PHASE2E',-81101,-81101,'E Home','EH',now()),(-81102,'PHASE2E',-81102,-81102,'E Away','EA',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values
(-81201,-81201,'PHASE2E',10,now()+interval '1 day',-81101,-81102,false,false,false,'scheduled',false,now(),now()),
(-81202,-81202,'PHASE2E',11,now()+interval '8 days',-81101,-81102,false,false,false,'scheduled',false,now(),now());
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at)
select '00000000-0000-0000-0000-000000008101','2E','PHASE2E',1000,1000,'draft',admin_id,true,'in_progress',now() from e;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values
('00000000-0000-0000-0000-000000008101',10,now()+interval '1 day'),('00000000-0000-0000-0000-000000008101',11,now()+interval '8 days');
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000008101',admin_id,'active','unpaid','used' from e;
insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
select -81301,'00000000-0000-0000-0000-000000008101',admin_id,10,-81201,-81101,'manual','pending',10,-81101,-81102,now()+interval '1 day' from e;
select public.set_test_pick_scenario('00000000-0000-0000-0000-000000008101',-81301,'lost');
do $$ declare r jsonb; begin
 r:=public.process_pot_gameweek('00000000-0000-0000-0000-000000008101',10,true);
 if not (r->>'collective_reinstatement')::boolean or (r->>'destination_gameweek')::integer<>11 then raise exception 'Collective reinstatement summary incorrect: %',r; end if;
 if not exists(select 1 from public.player_picks where id=-81301 and outcome='lost') then raise exception 'Failed pick history rewritten'; end if;
 if not exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000008101' and player_status='active' and buy_back_status='used') then raise exception 'Status/buy-back preservation failed'; end if;
 if not exists(select 1 from public.pot_round_players c join public.pot_rounds r on r.id=c.round_id where r.pot_id='00000000-0000-0000-0000-000000008101' and r.gameweek_number=11 and c.entry_reason='collective_reinstatement') then raise exception 'Destination cohort missing'; end if;
 if (select count(*) from public.round_collective_reinstatements where pot_id='00000000-0000-0000-0000-000000008101')<>1 then raise exception 'Reinstatement event missing/duplicated'; end if;
 if has_table_privilege('authenticated','public.round_collective_reinstatements','insert') or has_function_privilege('authenticated','public.process_pot_gameweek_phase2d_base(uuid,integer,boolean)','execute') then raise exception 'Private reinstatement path exposed'; end if;
end $$;
rollback;
