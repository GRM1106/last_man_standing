begin;
insert into auth.users(id,email) values
('00000000-0000-0000-0000-000000028001','membership-admin@example.test'),
('00000000-0000-0000-0000-000000028002','membership-player@example.test'),
('00000000-0000-0000-0000-000000028003','membership-other@example.test');
update public.profiles set is_admin=true where id='00000000-0000-0000-0000-000000028001';
insert into public.pots(id,name,season,status,lifecycle_status,created_by,entry_fee_pence,buy_back_fee_pence) values
('00000000-0000-0000-0000-000000028011','Available','MEMBERSHIP','open','open','00000000-0000-0000-0000-000000028001',1000,500),
('00000000-0000-0000-0000-000000028012','Private','MEMBERSHIP','draft','setup','00000000-0000-0000-0000-000000028001',1000,500),
('00000000-0000-0000-0000-000000028013','Second','MEMBERSHIP','open','open','00000000-0000-0000-0000-000000028001',1000,500);
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) select id,1,now()+interval '1 day' from public.pots where season='MEMBERSHIP';
create temporary table membership_checks(label text primary key);
grant select,insert on membership_checks to authenticated,anon;
create function pg_temp.check_membership(label text,ok boolean) returns void language plpgsql as $$ begin
 if ok is distinct from true then raise exception 'Membership assertion failed: %',label;end if;
 insert into membership_checks values(label);end $$;
create function pg_temp.membership_denied(label text,statement text) returns void language plpgsql as $$
declare denied boolean:=false;begin
 begin execute statement;exception when insufficient_privilege or raise_exception then denied:=true;end;
 perform pg_temp.check_membership(label,denied);end $$;
select pg_temp.check_membership('existing pots stay private',not exists(select 1 from public.pots where is_discoverable));
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028001',true);
select public.set_pot_discoverable('00000000-0000-0000-0000-000000028011',true);
select public.set_pot_discoverable('00000000-0000-0000-0000-000000028013',true);
select pg_temp.membership_denied('cannot publish draft', $$select public.set_pot_discoverable('00000000-0000-0000-0000-000000028012',true)$$);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028002',true);
select pg_temp.check_membership('discovery has only eligible public pots',jsonb_array_length(public.get_available_pots())=2);
select pg_temp.check_membership('no administrator data exposed',not exists(select 1 from jsonb_array_elements(public.get_available_pots()) p where p ?| array['created_by','review_reason','members','email']));
select pg_temp.check_membership('first request pending',public.request_pot_membership('00000000-0000-0000-0000-000000028011')->>'state'='pending');
select pg_temp.check_membership('duplicate request keeps version',public.request_pot_membership('00000000-0000-0000-0000-000000028011')->>'version'='1');
select pg_temp.membership_denied('private request denied',$$select public.request_pot_membership('00000000-0000-0000-0000-000000028012')$$);
select pg_temp.membership_denied('self approval denied',$$select public.decide_pot_membership('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002',1,true)$$);
select pg_temp.membership_denied('direct membership denied',$$insert into public.pot_players(pot_id,player_id) values('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002')$$);
select pg_temp.membership_denied('request manipulation denied',$$update public.pot_join_requests set status='accepted'$$);
select pg_temp.membership_denied('admin requests private',$$select public.get_pot_join_requests('00000000-0000-0000-0000-000000028011')$$);
select pg_temp.membership_denied('admin player details private',$$select public.get_admin_player_memberships('00000000-0000-0000-0000-000000028003')$$);
select pg_temp.membership_denied('player cannot publish',$$select public.set_pot_discoverable('00000000-0000-0000-0000-000000028011',true)$$);
select pg_temp.check_membership('own request visible',(select count(*) from public.pot_join_requests)=1);
select pg_temp.check_membership('audit hidden from player',(select count(*) from public.pot_membership_events)=0);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028003',true);
select pg_temp.check_membership('other requests hidden',(select count(*) from public.pot_join_requests)=0);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028001',true);
select pg_temp.check_membership('decline changes state',public.decide_pot_membership('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002',1,false)->>'state'='declined');
select pg_temp.check_membership('decline retry idempotent',public.decide_pot_membership('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002',1,false)->>'version'='2');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028002',true);
select pg_temp.check_membership('player sees declined',exists(select 1 from jsonb_array_elements(public.get_available_pots()) p where p->>'state'='declined'));
select pg_temp.check_membership('declined player may request again',public.request_pot_membership('00000000-0000-0000-0000-000000028011')->>'version'='3');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028001',true);
select pg_temp.membership_denied('stale decision denied',$$select public.decide_pot_membership('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002',1,true)$$);
select pg_temp.check_membership('accept creates membership',public.decide_pot_membership('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002',3,true)->>'state'='accepted');
select pg_temp.check_membership('accept retry idempotent',public.decide_pot_membership('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002',3,true)->>'version'='4');
select public.add_player_to_pot('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002');
select pg_temp.check_membership('assignment retry has one membership',(select count(*) from public.pot_players where pot_id='00000000-0000-0000-0000-000000028011')=1);
select public.add_player_to_pot('00000000-0000-0000-0000-000000028013','00000000-0000-0000-0000-000000028002');
select public.set_pot_player_payment('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002','paid');
select public.set_pot_player_payment('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028002','paid');
select pg_temp.check_membership('payment retry and multi-pot isolation',(select payment_status from public.pot_players where pot_id='00000000-0000-0000-0000-000000028011')='paid' and (select payment_status from public.pot_players where pot_id='00000000-0000-0000-0000-000000028013')='unpaid');
select pg_temp.check_membership('admin sees two memberships',jsonb_array_length(public.get_admin_player_memberships('00000000-0000-0000-0000-000000028002')->'memberships')=2);
select pg_temp.check_membership('one accepted audit event',(select count(*) from public.pot_membership_events where action='accepted')=1);
select pg_temp.check_membership('decision actor is admin',(select decided_by from public.pot_join_requests where pot_id='00000000-0000-0000-0000-000000028011')='00000000-0000-0000-0000-000000028001');
select pg_temp.membership_denied('audit append only',$$update public.pot_membership_events set action='declined'$$);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028002',true);
select pg_temp.check_membership('existing member request idempotent',public.request_pot_membership('00000000-0000-0000-0000-000000028011')->>'state'='member');
select pg_temp.check_membership('memberships removed from discovery',public.get_available_pots()='[]'::jsonb);
select pg_temp.membership_denied('cannot self mark entry paid',$$select public.set_pot_player_payment('00000000-0000-0000-0000-000000028013','00000000-0000-0000-0000-000000028002','paid')$$);
select pg_temp.membership_denied('cannot self confirm buy-back',$$select public.confirm_buy_back('00000000-0000-0000-0000-000000028013','00000000-0000-0000-0000-000000028002')$$);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028003',true);
select public.request_pot_membership('00000000-0000-0000-0000-000000028013');
reset role;
-- Model a legacy/direct membership already present when a request is accepted.
insert into public.pot_players(pot_id,player_id) values('00000000-0000-0000-0000-000000028013','00000000-0000-0000-0000-000000028003');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028001',true);
select pg_temp.check_membership('accept existing membership',public.decide_pot_membership('00000000-0000-0000-0000-000000028013','00000000-0000-0000-0000-000000028003',1,true)->>'state'='accepted');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028003',true);
select public.request_pot_membership('00000000-0000-0000-0000-000000028011');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028001',true);
select public.set_pot_discoverable('00000000-0000-0000-0000-000000028011',false);
select pg_temp.membership_denied('unavailable pending acceptance denied',$$select public.decide_pot_membership('00000000-0000-0000-0000-000000028011','00000000-0000-0000-0000-000000028003',1,true)$$);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000028003',true);
select pg_temp.check_membership('pending unavailable state explicit',exists(select 1 from jsonb_array_elements(public.get_available_pots()) p where p->>'state'='unavailable' and p->>'request_status'='pending'));
set local role anon;
select pg_temp.membership_denied('anonymous discovery denied',$$select public.get_available_pots()$$);
select pg_temp.membership_denied('anonymous request denied',$$select public.request_pot_membership('00000000-0000-0000-0000-000000028011')$$);
select pg_temp.membership_denied('anonymous table denied',$$select * from public.pot_join_requests$$);
reset role;
select 'PASS pot membership: '||count(*)||' assertions.' from membership_checks;
rollback;
