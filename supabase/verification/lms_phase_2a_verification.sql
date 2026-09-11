-- Phase 2A executable verification. Disposable local database only.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000004001','authenticated','authenticated','phase2a-player@example.test','x',now(),'{"provider":"email","providers":["email"]}','{"first_name":"Unapproved"}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000004002','authenticated','authenticated','phase2a-new@example.test','x',now(),'{"provider":"email","providers":["email"]}','{"first_name":"New"}',now(),now());

create temporary table phase2a_context as select id admin_id from public.profiles where is_admin limit 1;
select set_config('request.jwt.claim.sub',(select admin_id::text from phase2a_context),true);
update public.profiles set approved=false where id in('00000000-0000-0000-0000-000000004001','00000000-0000-0000-0000-000000004002');
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
(-41101,'PHASE2A',-41101,-41101,'2A Home','2AH',now()),(-41102,'PHASE2A',-41102,-41102,'2A Away','2AA',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,home_score,away_score,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values
(-41201,-41201,'PHASE2A',1,now()+interval '1 day',-41101,-41102,null,null,false,false,false,'scheduled',false,now(),now()),
(-41202,-41202,'PHASE2A',2,now()+interval '8 days',-41101,-41102,null,null,false,false,false,'scheduled',false,now(),now());

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status)
select '00000000-0000-0000-0000-000000004101','2A open','PHASE2A',1000,1000,'open',admin_id,false,'open' from phase2a_context;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values
('00000000-0000-0000-0000-000000004101',1,now()+interval '1 day'),('00000000-0000-0000-0000-000000004101',2,now()+interval '8 days');
select public.add_player_to_pot('00000000-0000-0000-0000-000000004101','00000000-0000-0000-0000-000000004001');
select public.add_player_to_pot('00000000-0000-0000-0000-000000004101','00000000-0000-0000-0000-000000004002');
delete from public.pot_players where pot_id='00000000-0000-0000-0000-000000004101' and player_id='00000000-0000-0000-0000-000000004002';

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000004001',true);
select public.confirm_team_pick('00000000-0000-0000-0000-000000004101',-41201,-41101);
do $$ declare dashboard jsonb; begin
  dashboard:=public.get_my_dashboard();
  if dashboard->'pots'='[]'::jsonb or not exists(select 1 from public.player_picks where pot_id='00000000-0000-0000-0000-000000004101' and player_id='00000000-0000-0000-0000-000000004001') then
    raise exception 'Unapproved unpaid player could not access assigned dashboard or pick'; end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000004002',true);
do $$ begin if (public.get_my_dashboard()->'pots')<>'[]'::jsonb then raise exception 'No-pot dashboard is not empty'; end if; end $$;

select set_config('request.jwt.claim.sub',(select admin_id::text from phase2a_context),true);
update public.pot_gameweeks set pick_deadline_at=now()-interval '1 second' where pot_id='00000000-0000-0000-0000-000000004101' and gameweek_number=1;
do $$ begin
  begin perform public.add_player_to_pot('00000000-0000-0000-0000-000000004101','00000000-0000-0000-0000-000000004002'); raise exception 'Post-deadline join accepted';
  exception when raise_exception then if sqlerrm not like 'Membership is permanently locked%' and sqlerrm<>'Membership is locked for this pot' then raise; end if; end;
  perform public.lock_pot_membership_if_due('00000000-0000-0000-0000-000000004101');
  if not exists(select 1 from public.pots where id='00000000-0000-0000-0000-000000004101' and membership_locked_at is not null and lifecycle_status='in_progress') then raise exception 'Lifecycle did not lock'; end if;
end $$;
update public.pot_gameweeks set pick_deadline_at=now()+interval '3 days' where pot_id='00000000-0000-0000-0000-000000004101' and gameweek_number=1;
update public.pots set status='open',lifecycle_status='open' where id='00000000-0000-0000-0000-000000004101';
do $$ begin
  begin perform public.add_player_to_pot('00000000-0000-0000-0000-000000004101','00000000-0000-0000-0000-000000004002'); raise exception 'Stored lock was reopened';
  exception when raise_exception then if sqlerrm not like 'Membership is permanently locked%' and sqlerrm<>'Membership is locked for this pot' then raise; end if; end;
end $$;

do $$ begin
  if has_function_privilege('authenticated','public.lock_pot_membership_if_due(uuid)','execute')
    or has_function_privilege('anon','public.lock_pot_membership_if_due(uuid)','execute') then raise exception 'Private lifecycle helper exposed'; end if;
  if not has_function_privilege('authenticated','public.add_player_to_pot(uuid,uuid)','execute') then raise exception 'Admin RPC unavailable'; end if;
  if not exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000004101' and payment_status='unpaid') then raise exception 'Payment state was erased'; end if;
end $$;
rollback;
