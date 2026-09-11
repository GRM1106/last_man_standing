-- Phase 2D executable verification. Disposable local database only.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000007001','authenticated','authenticated','2d@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
create temporary table c as select id admin_id from public.profiles where is_admin limit 1;
select set_config('request.jwt.claim.sub',(select admin_id::text from c),true);
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
(-71101,'PHASE2D',-71101,-71101,'D Home','DH',now()),(-71102,'PHASE2D',-71102,-71102,'D Away','DA',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values
(-71201,-71201,'PHASE2D',4,now()+interval '1 day',-71101,-71102,false,false,false,'scheduled',false,now(),now()),
(-71202,-71202,'PHASE2D',4,now()+interval '2 days',-71101,-71102,false,false,false,'scheduled',false,now(),now());
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status) select
'00000000-0000-0000-0000-000000007101','2D','PHASE2D',1000,1000,'open',admin_id,'open' from c;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('00000000-0000-0000-0000-000000007101',4,now()+interval '1 day');
insert into public.pot_players(pot_id,player_id) values('00000000-0000-0000-0000-000000007101','00000000-0000-0000-0000-000000007001');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007001',true);
select public.confirm_team_pick('00000000-0000-0000-0000-000000007101',-71201,-71101);
select set_config('request.jwt.claim.sub',(select admin_id::text from c),true);
select public.set_fixture_selection_block(-71202,true,'Credible official postponement risk');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007001',true);
do $$ begin begin perform public.confirm_team_pick('00000000-0000-0000-0000-000000007101',-71202,-71102); raise exception 'Blocked selection accepted';
 exception when raise_exception then if sqlerrm<>'That fixture is temporarily unavailable for selection' and sqlerrm<>'Your pick for this gameweek is already locked' then raise; end if; end; end $$;
select set_config('request.jwt.claim.sub',(select admin_id::text from c),true);
update public.football_fixtures set status='postponed',provider_synced_at=now()+interval '1 minute' where id=-71201;
select public.process_pot_gameweek('00000000-0000-0000-0000-000000007101',4,true);
do $$ begin
 if not exists(select 1 from public.player_picks where fixture_id=-71201 and exceptional_resolution_type='auto_win' and exceptional_fixture_status='postponed' and outcome='won' and result_source='postponed' and team_cycle_id is not null and round_id is not null) then raise exception 'Postponed pick did not auto-resolve/process'; end if;
 begin update public.player_picks set exceptional_fixture_status='void' where fixture_id=-71201; raise exception 'Exceptional result mutated'; exception when raise_exception then if sqlerrm<>'Exceptional pick resolution is immutable' then raise; end if; end;
 if has_function_privilege('authenticated','public.fixture_is_selection_blocked(bigint)','execute') then raise exception 'Private block helper exposed'; end if;
end $$;
rollback;
