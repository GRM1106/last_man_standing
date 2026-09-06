-- Phase 2K team-cycle rollover executable verification. Disposable local database only.
--
-- Drives a player through every team in a 20-team season using the real domain functions
-- (confirm_team_pick, process_pot_gameweek, assign_random_missing_picks) and asserts that
-- the pool resets. pot_player_team_cycles is never written by hand to manufacture
-- exhaustion; every cycle row this script observes was produced by the domain path.
--
-- A second pot with a six-team season exercises two consecutive rollovers (1 -> 2 -> 3),
-- which the 38-gameweek cap makes impossible to reach twice in a 20-team season. Because
-- the universe is computed from the pot's own season, this proves the implementation is
-- not hardcoded to twenty teams or to the first rollover.
--
-- Self-contained: it creates its own administrator rather than assuming a seeded one.

begin;

insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000007000','authenticated','authenticated','cyc-admin@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000007001','authenticated','authenticated','cyc-a@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000007002','authenticated','authenticated','cyc-b@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000007003','authenticated','authenticated','cyc-c@example.test','x',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
update public.profiles set is_admin=true where id='00000000-0000-0000-0000-000000007000';
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007000',true);

-- ---------------------------------------------------------------- 20-team season
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at)
select -62000-g,'P2KCYC',-62000-g,-62000-g,'CYC Team '||g,'C'||g,now() from generate_series(1,20) g;
-- Ten fixtures a gameweek pairing team n with team n+10, so every team plays every week.
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at)
select -63000-(gw*100+slot),-63000-(gw*100+slot),'P2KCYC',gw,now()+(gw||' days')::interval+interval '2 hours',
       -62000-slot,-62000-(slot+10),false,false,false,'scheduled',false,now(),now()
from generate_series(1,37) gw, generate_series(1,10) slot;

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status)
values('00000000-0000-0000-0000-000000007101','CYC pot','P2KCYC',1000,1000,'draft','00000000-0000-0000-0000-000000007000','setup');
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
select '00000000-0000-0000-0000-000000007101',gw,now()+(gw||' days')::interval+interval '1 hour' from generate_series(1,37) gw;
insert into public.pot_players(pot_id,player_id) values
('00000000-0000-0000-0000-000000007101','00000000-0000-0000-0000-000000007001'),
('00000000-0000-0000-0000-000000007101','00000000-0000-0000-0000-000000007002'),
('00000000-0000-0000-0000-000000007101','00000000-0000-0000-0000-000000007003');
select public.set_pot_test_mode('00000000-0000-0000-0000-000000007101',true);

do $$ begin
 if public.pot_eligible_team_count('00000000-0000-0000-0000-000000007101')<>20 then
   raise exception 'Expected a 20-team universe, got %',public.pot_eligible_team_count('00000000-0000-0000-0000-000000007101'); end if;
 if (select count(*) from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101')<>3
   or exists(select 1 from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101' and cycle_number<>1) then
   raise exception 'Every player must start in cycle 1 only'; end if;
end $$;

-- Drive gameweeks 1..20.
--   A takes team g            -> consumes all 20 teams in order
--   C takes team ((g+4)%20)+1 -> also consumes all 20, five slots away from A so the two
--                                never share a fixture, and the pot keeps two active
--                                players so it is never won by survivor count
--   B plays gameweeks 1-4: loses gameweek 3, claims the one-time buy-back while the next
--     round cohort is still open, then loses again in gameweek 4 and stays eliminated on
--     four used teams. Buy-back has to be claimed inside the loop because the destination
--     round's cohort finalizes as soon as that gameweek is processed.
do $$
declare gw integer; a_team integer; c_team integer; b_team integer;
        a_slot integer; c_slot integer; b_slot integer;
        a_pick bigint; b_pick bigint; c_pick bigint;
begin
 for gw in 1..20 loop
   a_team:=gw;
   c_team:=((gw+4)%20)+1;
   a_slot:=case when a_team<=10 then a_team else a_team-10 end;
   c_slot:=case when c_team<=10 then c_team else c_team-10 end;

   perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007001',true);
   perform public.confirm_team_pick('00000000-0000-0000-0000-000000007101',-63000-(gw*100+a_slot),-62000-a_team);
   perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007003',true);
   perform public.confirm_team_pick('00000000-0000-0000-0000-000000007101',-63000-(gw*100+c_slot),-62000-c_team);

   if gw<=4 then
     b_team:=case gw when 1 then 20 when 2 then 19 when 3 then 15 else 17 end;
     b_slot:=case when b_team<=10 then b_team else b_team-10 end;
     perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007002',true);
     perform public.confirm_team_pick('00000000-0000-0000-0000-000000007101',-63000-(gw*100+b_slot),-62000-b_team);
   end if;

   -- Assert the boundary state as it is reached, before the 20th team is consumed.
   if gw=19 then
     if (select count(*) from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
         and player_id='00000000-0000-0000-0000-000000007001')<>1 then
       raise exception 'No rollover may occur before the pool is exhausted (gameweek 19)'; end if;
     if (select count(distinct team_id) from public.player_picks where pot_id='00000000-0000-0000-0000-000000007101'
         and player_id='00000000-0000-0000-0000-000000007001')<>19 then
       raise exception 'Expected 19 used teams at gameweek 19'; end if;
   end if;

   perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007000',true);
   select id into a_pick from public.player_picks where pot_id='00000000-0000-0000-0000-000000007101'
     and player_id='00000000-0000-0000-0000-000000007001' and gameweek_number=gw;
   perform public.set_test_pick_scenario('00000000-0000-0000-0000-000000007101',a_pick,'won');
   select id into c_pick from public.player_picks where pot_id='00000000-0000-0000-0000-000000007101'
     and player_id='00000000-0000-0000-0000-000000007003' and gameweek_number=gw;
   perform public.set_test_pick_scenario('00000000-0000-0000-0000-000000007101',c_pick,'won');
   if gw<=4 then
     select id into b_pick from public.player_picks where pot_id='00000000-0000-0000-0000-000000007101'
       and player_id='00000000-0000-0000-0000-000000007002' and gameweek_number=gw;
     perform public.set_test_pick_scenario('00000000-0000-0000-0000-000000007101',b_pick,case when gw>=3 then 'lost' else 'won' end);
   end if;
   perform public.process_pot_gameweek('00000000-0000-0000-0000-000000007101',gw,true);

   -- K. Buy-back, claimed while the next round is still open, must not disturb cycles.
   if gw=3 then
     if (select player_status from public.pot_players where pot_id='00000000-0000-0000-0000-000000007101'
         and player_id='00000000-0000-0000-0000-000000007002')<>'eliminated' then
       raise exception 'Player B should be eliminated after gameweek 3'; end if;
     perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007002',true);
     perform public.claim_buy_back('00000000-0000-0000-0000-000000007101');
     perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007000',true);
     if (select count(*) from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
         and player_id='00000000-0000-0000-0000-000000007002')<>1 then
       raise exception 'Buy-back must not open a new cycle'; end if;
     if exists(select 1 from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
         and player_id='00000000-0000-0000-0000-000000007002' and closed_at is not null) then
       raise exception 'Buy-back must not close or reopen a cycle'; end if;
     if (select count(distinct team_id) from public.player_picks where pot_id='00000000-0000-0000-0000-000000007101'
         and player_id='00000000-0000-0000-0000-000000007002')<>3 then
       raise exception 'Buy-back must preserve the three teams already used'; end if;
   end if;
 end loop;
end $$;

-- G. 20-team exhaustion proof.
do $$
declare cycle_one record; cycle_two record;
begin
 select * into cycle_one from public.pot_player_team_cycles
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007001' and cycle_number=1;
 select * into cycle_two from public.pot_player_team_cycles
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007001' and cycle_number=2;

 if cycle_one.closed_at is null then raise exception 'Cycle 1 must close once all 20 teams are used'; end if;
 if cycle_two.id is null then raise exception 'Cycle 2 must open when cycle 1 closes'; end if;
 if cycle_two.closed_at is not null then raise exception 'Cycle 2 must be open'; end if;
 if (select count(*) from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
     and player_id='00000000-0000-0000-0000-000000007001')<>2 then
   raise exception 'Exactly one next cycle may be created'; end if;
 if (select count(distinct team_id) from public.player_picks where team_cycle_id=cycle_one.id)<>20 then
   raise exception 'Cycle 1 must retain all 20 historical picks'; end if;
 if exists(select 1 from public.player_picks where team_cycle_id=cycle_two.id) then
   raise exception 'Cycle 2 must start empty'; end if;
 if not public.team_cycle_is_exhausted(cycle_one.id) then raise exception 'Cycle 1 must read as exhausted'; end if;
 if public.team_cycle_is_exhausted(cycle_two.id) then raise exception 'Cycle 2 must not read as exhausted'; end if;
 if public.active_team_cycle_id('00000000-0000-0000-0000-000000007101','00000000-0000-0000-0000-000000007001')<>cycle_two.id then
   raise exception 'Eligibility must resolve against cycle 2'; end if;
end $$;

-- Every team is available again in cycle 2.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007001',true);
do $$ declare availability jsonb; unavailable integer;
begin
 availability:=public.get_my_team_availability('00000000-0000-0000-0000-000000007101');
 select count(*) into unavailable from jsonb_array_elements(availability) team where not (team->>'available')::boolean;
 if jsonb_array_length(availability)<>20 then raise exception 'Expected 20 teams in availability, got %',jsonb_array_length(availability); end if;
 if unavailable<>0 then raise exception 'All 20 teams must be available again in cycle 2, % were not',unavailable; end if;
end $$;

-- K (continued). After the buy-back and a second elimination, history is still intact.
do $$ declare b_cycles integer; b_teams integer; b record;
begin
 select * into b from public.pot_players where pot_id='00000000-0000-0000-0000-000000007101'
   and player_id='00000000-0000-0000-0000-000000007002';
 select count(*) into b_cycles from public.pot_player_team_cycles
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007002';
 select count(distinct team_id) into b_teams from public.player_picks
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007002';
 if b.buy_back_used_at is null then raise exception 'The buy-back should have been recorded'; end if;
 if b.player_status<>'eliminated' then raise exception 'Player B should be eliminated again after gameweek 4'; end if;
 if b_cycles<>1 then raise exception 'Player B must still hold exactly one cycle'; end if;
 if b_teams<>4 then raise exception 'Player B must show four used teams, got %',b_teams; end if;
end $$;

-- H. The next manual pick lands in cycle 2 and reuses a cycle-1 team.
do $$ declare picked record; cycle_two uuid; cycle_one uuid;
begin
 perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007001',true);
 perform public.confirm_team_pick('00000000-0000-0000-0000-000000007101',-63000-(21*100+1),-62001);
 select id into cycle_two from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
   and player_id='00000000-0000-0000-0000-000000007001' and cycle_number=2;
 select id into cycle_one from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
   and player_id='00000000-0000-0000-0000-000000007001' and cycle_number=1;
 select * into picked from public.player_picks where pot_id='00000000-0000-0000-0000-000000007101'
   and player_id='00000000-0000-0000-0000-000000007001' and gameweek_number=21;

 if picked.team_cycle_id<>cycle_two then raise exception 'The pick after reset must belong to cycle 2'; end if;
 if picked.team_id<>-62001 then raise exception 'A cycle-1 team must be selectable again in cycle 2'; end if;
 if (select count(*) from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
     and player_id='00000000-0000-0000-0000-000000007001')<>2 then raise exception 'A third cycle must not appear'; end if;
 if (select count(distinct team_id) from public.player_picks where team_cycle_id=cycle_one)<>20 then
   raise exception 'Cycle 1 history must remain unchanged'; end if;
 if (select count(distinct team_id) from public.player_picks where team_cycle_id=cycle_two)<>1 then
   raise exception 'Cycle 2 usage must start at one team'; end if;

 -- Reuse within the new cycle is still refused.
 begin
   perform public.confirm_team_pick('00000000-0000-0000-0000-000000007101',-63000-(21*100+1),-62001);
   raise exception 'Same-gameweek repeat pick accepted';
 exception when others then
   if sqlerrm not like '%already locked%' then raise exception 'Unexpected repeat-pick error: %',sqlerrm; end if;
 end;
end $$;

-- J. Player B, who never exhausted the pool, is untouched by A's reset.
do $$ declare b_cycles integer; b_teams integer; b_open integer;
begin
 select count(*) into b_cycles from public.pot_player_team_cycles
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007002';
 select count(*) into b_open from public.pot_player_team_cycles
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007002'
   and cycle_number=1 and closed_at is null;
 select count(distinct team_id) into b_teams from public.player_picks
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007002';
 if b_cycles<>1 or b_open<>1 then raise exception 'Player B must remain in a single open cycle 1'; end if;
 if b_teams<>4 then raise exception 'Player B must still show four used teams, got %',b_teams; end if;
end $$;

-- I. Random assignment for a player who also exhausted the pool. Player C consumed all
-- twenty teams alongside A and has no manual pick for gameweek 21, so the missed-pick path
-- must assign a team out of C's fresh cycle rather than reporting no eligible team.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007000',true);
update public.pot_gameweeks set pick_deadline_at=now()-interval '1 hour'
where pot_id='00000000-0000-0000-0000-000000007101' and gameweek_number=21;
do $$ declare assignment jsonb; c_pick record; c_cycle_two uuid;
begin
 assignment:=public.assign_random_missing_picks('00000000-0000-0000-0000-000000007101',21,true);
 if coalesce((assignment->>'assigned')::integer,0)<1 then
   raise exception 'Random assignment must succeed after a pool reset: %',assignment; end if;
 if (assignment->'problems') ? 'No eligible unstarted fixture remains for random assignment.' then
   raise exception 'Exhausting cycle 1 must not starve random assignment: %',assignment; end if;

 select id into c_cycle_two from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
   and player_id='00000000-0000-0000-0000-000000007003' and cycle_number=2;
 select * into c_pick from public.player_picks where pot_id='00000000-0000-0000-0000-000000007101'
   and player_id='00000000-0000-0000-0000-000000007003' and gameweek_number=21;
 if c_pick.id is null then raise exception 'Random assignment produced no pick for the reset player'; end if;
 if c_pick.selection_source<>'random' then raise exception 'Assigned pick must be marked random'; end if;
 if c_pick.team_cycle_id<>c_cycle_two then raise exception 'Randomly assigned pick must belong to cycle 2'; end if;
 if (select count(*) from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
     and player_id='00000000-0000-0000-0000-000000007003')<>2 then
   raise exception 'Random assignment must not create an extra cycle'; end if;
end $$;

-- N. Automation must not progression-fail merely because a pool was exhausted. Both A and
-- C have consumed all twenty teams; the scan should reach an ordinary waiting/processing
-- state and open no progression_failure review case.
do $$ declare outcome jsonb;
begin
 perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007000',true);
 outcome:=public.run_lms_pot_automation('00000000-0000-0000-0000-000000007101');
 if outcome->>'status'='failed' then
   raise exception 'Automation failed after a pool reset: %',outcome; end if;
 if outcome->>'state'='blocked_no_safe_pick' then
   raise exception 'Automation reported no safe pick after a pool reset: %',outcome; end if;
 if exists(select 1 from public.lms_review_cases where pot_id='00000000-0000-0000-0000-000000007101'
   and case_type='progression_failure') then
   raise exception 'Exhaustion opened a progression_failure review case'; end if;
end $$;

-- Repeated boundary calls are idempotent, and a second open cycle is structurally refused.
do $$ declare before_count integer; after_count integer; closed_stamp timestamptz;
begin
 select count(*),max(closed_at) into before_count,closed_stamp from public.pot_player_team_cycles
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007001';
 for i in 1..5 loop
   perform public.ensure_current_team_cycle('00000000-0000-0000-0000-000000007101','00000000-0000-0000-0000-000000007001');
 end loop;
 select count(*) into after_count from public.pot_player_team_cycles
 where pot_id='00000000-0000-0000-0000-000000007101' and player_id='00000000-0000-0000-0000-000000007001';
 if after_count<>before_count then raise exception 'Repeated rollover calls created cycles'; end if;
 if (select max(closed_at) from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007101'
     and player_id='00000000-0000-0000-0000-000000007001') is distinct from closed_stamp then
   raise exception 'Repeated rollover calls moved closed_at'; end if;

 begin
   insert into public.pot_player_team_cycles(pot_id,player_id,cycle_number)
   values('00000000-0000-0000-0000-000000007101','00000000-0000-0000-0000-000000007001',99);
   raise exception 'A second open cycle was accepted';
 exception when unique_violation then null;
 end;
end $$;

-- ---------------------------------------------------------------- six-team season
-- Two consecutive rollovers, which the 38-gameweek cap puts out of reach in a 20-team
-- season. Also proves the universe is read from the pot's season, not hardcoded.
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at)
select -64000-g,'P2KCYC6',-64000-g,-64000-g,'SIX Team '||g,'S'||g,now() from generate_series(1,6) g;
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at)
select -70000-(gw*10+slot),-70000-(gw*10+slot),'P2KCYC6',gw,now()+(gw||' days')::interval+interval '2 hours',
       -64000-slot,-64000-(slot+3),false,false,false,'scheduled',false,now(),now()
from generate_series(1,20) gw, generate_series(1,3) slot;

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,lifecycle_status)
values('00000000-0000-0000-0000-000000007201','SIX pot','P2KCYC6',1000,1000,'draft','00000000-0000-0000-0000-000000007000','setup');
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
select '00000000-0000-0000-0000-000000007201',gw,now()+(gw||' days')::interval+interval '1 hour' from generate_series(1,20) gw;
insert into public.pot_players(pot_id,player_id) values
('00000000-0000-0000-0000-000000007201','00000000-0000-0000-0000-000000007003');
select public.set_pot_test_mode('00000000-0000-0000-0000-000000007201',true);

do $$
declare gw integer; team_index integer; slot integer; c_pick bigint;
begin
 if public.pot_eligible_team_count('00000000-0000-0000-0000-000000007201')<>6 then
   raise exception 'Expected a six-team universe'; end if;
 for gw in 1..12 loop
   team_index:=((gw-1)%6)+1;
   slot:=case when team_index<=3 then team_index else team_index-3 end;
   perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007003',true);
   perform public.confirm_team_pick('00000000-0000-0000-0000-000000007201',-70000-(gw*10+slot),-64000-team_index);
   perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000007000',true);
   select id into c_pick from public.player_picks where pot_id='00000000-0000-0000-0000-000000007201' and gameweek_number=gw;
   perform public.set_test_pick_scenario('00000000-0000-0000-0000-000000007201',c_pick,'won');
   perform public.process_pot_gameweek('00000000-0000-0000-0000-000000007201',gw,true);
 end loop;
end $$;

-- L. Multi-cycle proof: cycle 1 and 2 closed, cycle 3 open, six picks held per closed cycle.
do $$ declare cycles integer; open_cycles integer; top integer;
begin
 select count(*),count(*) filter (where closed_at is null),max(cycle_number)
 into cycles,open_cycles,top
 from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007201';
 if cycles<>3 then raise exception 'Expected three cycles after two exhaustions, got %',cycles; end if;
 if open_cycles<>1 then raise exception 'Exactly one cycle may be open, got %',open_cycles; end if;
 if top<>3 then raise exception 'Expected cycle_number 3, got %',top; end if;
 if not exists(select 1 from public.pot_player_team_cycles where pot_id='00000000-0000-0000-0000-000000007201'
   and cycle_number=3 and closed_at is null) then raise exception 'Cycle 3 must be the open one'; end if;
 if exists(
   select 1 from public.pot_player_team_cycles c where c.pot_id='00000000-0000-0000-0000-000000007201'
   and c.cycle_number in (1,2)
   and (select count(distinct p.team_id) from public.player_picks p where p.team_cycle_id=c.id)<>6
 ) then raise exception 'Each closed cycle must retain its six picks'; end if;
end $$;

-- M. Security: a player may not touch cycles directly, nor call the rollover helpers.
do $$ begin
 if has_function_privilege('authenticated','public.ensure_current_team_cycle(uuid,uuid)','execute')
   or has_function_privilege('anon','public.ensure_current_team_cycle(uuid,uuid)','execute')
   or has_function_privilege('authenticated','public.active_team_cycle_id(uuid,uuid)','execute')
   or has_function_privilege('authenticated','public.team_cycle_is_exhausted(uuid)','execute')
   or has_function_privilege('authenticated','public.pot_eligible_team_count(uuid)','execute')
   or has_function_privilege('authenticated','public.roll_team_cycle_after_pick()','execute') then
   raise exception 'Team-cycle helpers must not be callable by players'; end if;
 if has_table_privilege('authenticated','public.pot_player_team_cycles','insert')
   or has_table_privilege('authenticated','public.pot_player_team_cycles','update')
   or has_table_privilege('authenticated','public.pot_player_team_cycles','delete')
   or has_table_privilege('anon','public.pot_player_team_cycles','select') then
   raise exception 'Players must not be able to write team cycles'; end if;
end $$;

-- Evidence summary for the record.
select case p.player_id
         when '00000000-0000-0000-0000-000000007001' then 'A (20-team pot)'
         when '00000000-0000-0000-0000-000000007002' then 'B (20-team pot)'
         when '00000000-0000-0000-0000-000000007003' then case when c.pot_id='00000000-0000-0000-0000-000000007101'
              then 'C (20-team pot)' else 'C (six-team pot)' end
       end as player,
       c.cycle_number,
       case when c.closed_at is null then 'open' else 'closed' end as state,
       (select count(distinct k.team_id) from public.player_picks k where k.team_cycle_id=c.id) as teams_used
from public.pot_player_team_cycles c
join public.pot_players p on p.pot_id=c.pot_id and p.player_id=c.player_id
order by c.pot_id, player, c.cycle_number;

rollback;
