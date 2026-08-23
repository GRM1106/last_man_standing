begin;
do $$ declare admin_id uuid; begin
 select id into admin_id from public.profiles where is_admin order by created_at limit 1;
 perform set_config('request.jwt.claim.sub',admin_id::text,true);
 insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values (-91101,'PHASE2F',-91101,-91101,'2F Home','2FH',now()),(-91102,'PHASE2F',-91102,-91102,'2F Away','2FA',now());
 insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values
 (-91201,-91201,'PHASE2F',6,now()+interval '1 hour',-91101,-91102,false,false,false,'scheduled',false,now(),now()),(-91202,-91202,'PHASE2F',7,now()+interval '1 day',-91101,-91102,false,false,false,'scheduled',false,now(),now());
 insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at) values('00000000-0000-0000-0000-000000009101','2F','PHASE2F',1000,1000,'draft',admin_id,true,'in_progress',now());
 insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('00000000-0000-0000-0000-000000009101',6,now()-interval '1 day'),('00000000-0000-0000-0000-000000009101',7,now()+interval '1 day');
 insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status) values('00000000-0000-0000-0000-000000009101',admin_id,'eliminated','unpaid','available');
 insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at,selection_eligible)
 values('00000000-0000-0000-0000-000000009101',admin_id,6,-91201,-91101,'manual','lost',6,-91101,-91102,now()-interval '1 day',true);
 insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by) values('00000000-0000-0000-0000-000000009101',6,true,'{}',admin_id);
 perform public.claim_buy_back('00000000-0000-0000-0000-000000009101');
 if not exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000009101' and player_id=admin_id and player_status='active' and buy_back_status='requested' and buy_back_payment_status='pending' and buy_back_used_at is not null) then raise exception 'Timely request did not consume entitlement and restore eligibility'; end if;
 if not exists(select 1 from public.pot_round_players c join public.pot_rounds r on r.id=c.round_id where r.pot_id='00000000-0000-0000-0000-000000009101' and r.gameweek_number=7 and c.player_id=admin_id and c.entry_reason='buy_back') then raise exception 'Buy-back cohort entry missing'; end if;
 begin perform public.claim_buy_back('00000000-0000-0000-0000-000000009101'); raise exception 'Second request accepted'; exception when others then if sqlerrm='Second request accepted' then raise; end if; end;
 update public.profiles set is_admin=false where id=admin_id;
 begin perform public.confirm_buy_back('00000000-0000-0000-0000-000000009101',admin_id); raise exception 'Player confirmed a buy-back'; exception when others then if sqlerrm='Player confirmed a buy-back' then raise; end if; end;
 begin perform public.revoke_buy_back('00000000-0000-0000-0000-000000009101',admin_id,'Player attempted revocation'); raise exception 'Player revoked a buy-back'; exception when others then if sqlerrm='Player revoked a buy-back' then raise; end if; end;
 update public.profiles set is_admin=true where id=admin_id;
 perform public.confirm_buy_back('00000000-0000-0000-0000-000000009101',admin_id); perform public.confirm_buy_back('00000000-0000-0000-0000-000000009101',admin_id);
 if (select count(*) from public.pot_player_buyback_events where pot_id='00000000-0000-0000-0000-000000009101' and event_type='confirmed')<>1 then raise exception 'Confirmation retry was not idempotent'; end if;
 perform public.confirm_team_pick('00000000-0000-0000-0000-000000009101',-91202,-91102);
 if public.current_team_cycle_id('00000000-0000-0000-0000-000000009101',admin_id) is distinct from (select team_cycle_id from public.player_picks where pot_id='00000000-0000-0000-0000-000000009101' and gameweek_number=6) then raise exception 'Buy-back reset the team-use cycle'; end if;
 perform public.revoke_buy_back('00000000-0000-0000-0000-000000009101',admin_id,'Manual payment was not received');
 if not exists(select 1 from public.pots where id='00000000-0000-0000-0000-000000009101' and lifecycle_status='review') then raise exception 'Downstream revocation did not enter review'; end if;
 if not exists(select 1 from public.player_picks where pot_id='00000000-0000-0000-0000-000000009101' and gameweek_number=7) then raise exception 'Downstream revocation rewrote pick history'; end if;
 if has_table_privilege('authenticated','public.pot_player_buyback_events','insert') or has_function_privilege('authenticated','public.prevent_buyback_event_mutation()','execute') then raise exception 'Private buy-back mutation path exposed'; end if;
 perform public.reset_draft_test_pot('00000000-0000-0000-0000-000000009101');
 if exists(select 1 from public.pot_player_buyback_events where pot_id='00000000-0000-0000-0000-000000009101') or exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000009101' and (buy_back_status<>'available' or buy_back_payment_status<>'not_due' or buy_back_used_at is not null)) then raise exception 'Draft test reset left buy-back state'; end if;
end $$;
rollback;
