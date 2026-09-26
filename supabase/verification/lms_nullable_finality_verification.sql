-- Run only in the runner-owned disposable database, after ALL migrations.
-- Every synthetic row and the NULL-boundary fault injection roll back together.
\set ON_ERROR_STOP on
begin;

create temporary table finality_context as
select id admin_id,gen_random_uuid() first_player,gen_random_uuid() second_player
from public.profiles where is_admin order by id limit 1;
do $$ begin
  if (select count(*) from finality_context)<>1 then raise exception 'Finality tests require a seeded administrator'; end if;
end $$;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated',u||'@finality.example.test','x',now(),
 '{"provider":"email","providers":["email"]}','{}',now(),now()
from finality_context cross join lateral unnest(array[first_player,second_player]) u;
select set_config('request.jwt.claim.sub',(select admin_id::text from finality_context),true);
select set_config('request.jwt.claim.role','authenticated',true);
update public.lms_provider_state set last_ingested_at=now() where singleton;

insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at)
select -991000-n,'NULLABLE-FINALITY',-991000-n,991000+n,'Finality team '||n,'NF'||n,now()
from generate_series(1,4) n;
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,status,provider_synced_at)
values(-991099,-991099,'NULLABLE-FINALITY',11,now()+interval '3 days',-991001,-991002,'scheduled',now());

-- Persisted provider finality columns are NOT NULL. Inject an unknown value at the
-- effective-result boundary to exercise the actual processor's defensive NULL path,
-- without weakening table constraints or adding a production test hook. All other
-- fields, processing functions, wrappers, triggers and permissions stay real.
create temporary table finality_original_function as
select pg_get_functiondef('public.get_effective_fixture_result(bigint)'::regprocedure) definition;
do $$ declare definition text; marker text:='case when current_override.id is not null then current_override.new_status=''finished'''; begin
 select f.definition into definition from finality_original_function f;
 if (length(definition)-length(replace(definition,marker,'')))/length(marker)<>1 then
   raise exception 'Unexpected effective-result boundary for NULL fault injection';
 end if;
 definition:=replace(definition,marker,
  'case when fixture.id=nullif(current_setting(''lms.test_null_fixture'',true),'''')::bigint then null::boolean when current_override.id is not null then current_override.new_status=''finished''');
 execute definition;
end $$;

-- FPL final fixtures have both flags true; provisional-only fixtures have
-- finished=false and finished_provisional=true. Competition assertions are unchanged.

-- Competition-state equality excludes only automation attempt logs, whose waiting
-- entries are intentional. It includes pick snapshots, membership/buy-back state,
-- cohorts, team cycles, round processes, collective reinstatement and winner history.
create function pg_temp.finality_snapshot(pot uuid) returns jsonb language sql as $$
select jsonb_build_object(
 'pot',(select to_jsonb(p) from public.pots p where id=pot),
 'picks',(select jsonb_agg(to_jsonb(p) order by p.id) from public.player_picks p where pot_id=pot),
 'players',(select jsonb_agg(to_jsonb(p) order by p.player_id) from public.pot_players p where pot_id=pot),
 'rounds',(select jsonb_agg(to_jsonb(r) order by r.sequence_number) from public.pot_rounds r where pot_id=pot),
 'cohorts',(select jsonb_agg(to_jsonb(c) order by c.round_id,c.player_id) from public.pot_round_players c where pot_id=pot),
 'cycles',(select jsonb_agg(to_jsonb(c) order by c.id) from public.pot_player_team_cycles c where pot_id=pot),
 'processes',(select jsonb_agg(to_jsonb(p) order by p.gameweek_number) from public.pot_gameweek_processes p where pot_id=pot),
 'reinstatements',(select jsonb_agg(to_jsonb(r) order by r.id) from public.round_collective_reinstatements r where pot_id=pot),
 'buybacks',(select jsonb_agg(to_jsonb(b) order by b.id) from public.pot_player_buyback_events b where pot_id=pot),
 'completion',(select to_jsonb(c) from public.pot_completions c where pot_id=pot),
 'winners',(select jsonb_agg(to_jsonb(w) order by w.player_id) from public.pot_winners w where pot_id=pot)
);
$$;

create function pg_temp.verify_finality(case_number integer,case_name text,fixture_state text,gw integer,mixed boolean)
returns void language plpgsql as $$
declare pot uuid:=gen_random_uuid(); fixture bigint:=-992000-case_number*10;
declare admin_id uuid; players uuid[]; player uuid; i integer; result jsonb; before_state jsonb;
declare rejected boolean; should_wait boolean; expected_outcome text; override_preview jsonb;
begin
 select c.admin_id,array[c.first_player,c.second_player] into admin_id,players from finality_context c;
 perform set_config('lms.test_null_fixture','',true);
 insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at)
 values(pot,case_name,'NULLABLE-FINALITY',1000,1000,'active',admin_id,false,'in_progress',now()-interval '2 hours');
 insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values(pot,gw,now()-interval '1 hour');
 if gw<38 then
   insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values(pot,gw+1,now()+interval '3 days');
 end if;
 for i in 1..(case when mixed then 2 else 1 end) loop
   player:=players[i];
   insert into public.pot_players(pot_id,player_id,player_status,payment_status)
   values(pot,player,'active','paid');
   insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,status,provider_synced_at)
   values(fixture-i,fixture-i,'NULLABLE-FINALITY',gw,now()-interval '1 hour',
    case when i=1 then -991001 else -991003 end,case when i=1 then -991002 else -991004 end,'scheduled',now()-interval '3 hours');
   insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,confirmed_at,
    selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
   values(pot,player,gw,fixture-i,case when i=1 then -991001 else -991003 end,'manual',now()-interval '2 hours',
    gw,case when i=1 then -991001 else -991003 end,case when i=1 then -991002 else -991004 end,now()-interval '1 hour');
 end loop;
 if mixed then
   update public.football_fixtures set status='finished',started=true,finished=true,finished_provisional=true,
    home_score=2,away_score=0,provider_synced_at=now() where id=fixture-2;
 end if;
 if fixture_state like 'auto_%' then
   -- The real existing trigger establishes the valid decision; the fix creates none.
   update public.football_fixtures set status=substr(fixture_state,6),provider_synced_at=now() where id=fixture-1;
   if not exists(select 1 from public.player_picks where pot_id=pot and fixture_id=fixture-1
     and exceptional_resolution_type='auto_win' and exceptional_resolved_at is not null) then
     raise exception '%: setup did not establish a real automatic win',case_name;
   end if;
 elsif fixture_state like 'override_%' then
   override_preview:=public.preview_fixture_result_override(fixture-1,null,null,substr(fixture_state,10),'Finality regression: exceptional override without a pick decision');
   perform public.create_fixture_result_override(fixture-1,null,null,substr(fixture_state,10),
    'Finality regression: exceptional override without a pick decision',override_preview->>'effective_version');
   if exists(select 1 from public.player_picks where pot_id=pot and exceptional_resolution_type is not null) then
     raise exception '%: setup unexpectedly supplied an automatic win',case_name;
   end if;
 else
   update public.football_fixtures set
    status=case fixture_state when 'scheduled' then 'scheduled' when 'live' then 'live' else 'finished' end,
    started=fixture_state<>'scheduled',finished=fixture_state not in('scheduled','live','provisional'),
    finished_provisional=fixture_state not in('scheduled','live'),
    home_score=case when fixture_state in('scheduled','incomplete') then null when fixture_state in('loss','unknown') then 0 when fixture_state='draw' then 1 else 2 end,
    away_score=case when fixture_state in('scheduled','incomplete') then null when fixture_state in('loss','unknown') then 2 when fixture_state='draw' then 1 else 0 end,
    provider_synced_at=now() where id=fixture-1;
 end if;
 if fixture_state='unknown' then
   perform set_config('lms.test_null_fixture',(fixture-1)::text,true);
   if (select processable from public.get_effective_fixture_result(fixture-1)) is not null then
     raise exception '%: NULL fault injection failed',case_name;
   end if;
 end if;
 should_wait:=fixture_state not in('final','loss','draw','auto_postponed','auto_abandoned','auto_void');
 before_state:=pg_temp.finality_snapshot(pot);
 result:=public.process_pot_gameweek(pot,gw,false);
 if should_wait then
   if (result->>'ready')::boolean is distinct from false or (result->>'losers')::integer<>0 then
     raise exception '%: unknown/non-final evidence was considered ready or a loss: %',case_name,result;
   end if;
   rejected:=false;
   begin
     perform public.process_pot_gameweek(pot,gw,true);
   exception when raise_exception then
     if sqlerrm not like '%pick result(s) are not available yet.%' then raise; end if;
     rejected:=true;
   end;
   if not rejected then raise exception '%: non-final application succeeded',case_name; end if;
   if pg_temp.finality_snapshot(pot) is distinct from before_state then
     raise exception '%: blocked application mutated competition history',case_name;
   end if;
   result:=public.run_lms_pot_automation(pot);
   if result->>'status' is distinct from 'skipped' or result->>'state' is distinct from 'waiting_for_results' then
     raise exception '%: automation did not wait: %',case_name,result;
   end if;
   if pg_temp.finality_snapshot(pot) is distinct from before_state
     or public.current_pot_gameweek(pot) is distinct from gw
     or exists(select 1 from public.pot_completions where pot_id=pot)
     or exists(select 1 from public.pot_winners where pot_id=pot) then
     raise exception '%: waiting resolved/eliminated a pick, progressed or declared winners',case_name;
   end if;
   -- The same pick subsequently receives final evidence; retry through the public
   -- entry point must work, including the exceptional override supersession path.
   perform set_config('lms.test_null_fixture','',true);
   if fixture_state like 'override_%' then
     override_preview:=public.preview_fixture_result_override(fixture-1,2,0,'finished','Finality regression: genuinely final evidence now available');
     perform public.create_fixture_result_override(fixture-1,2,0,'finished',
      'Finality regression: genuinely final evidence now available',override_preview->>'effective_version');
   else
     update public.football_fixtures set status='finished',started=true,finished=true,finished_provisional=true,
      home_score=2,away_score=0,provider_synced_at=now() where id=fixture-1;
   end if;
 end if;
 result:=public.process_pot_gameweek(pot,gw,false);
 if (result->>'ready')::boolean is distinct from true then raise exception '%: final evidence not ready: %',case_name,result; end if;
 result:=public.process_pot_gameweek(pot,gw,true);
 if (result->>'processed')::boolean is distinct from true then raise exception '%: final processing failed: %',case_name,result; end if;
 expected_outcome:=case when fixture_state in('loss','draw') then 'lost' else 'won' end;
 if not exists(select 1 from public.player_picks where pot_id=pot and fixture_id=fixture-1
   and outcome=expected_outcome and resolved_at is not null)
   or exists(select 1 from public.player_picks where pot_id=pot and (outcome='pending' or resolved_at is null))
   or (select count(*) from public.pot_gameweek_processes where pot_id=pot)<>1 then
   raise exception '%: final pick/process state is incorrect',case_name;
 end if;
 if not exists(select 1 from public.pot_gameweek_processes where pot_id=pot and processed_by=admin_id) then
   raise exception '%: administrator attribution changed',case_name;
 end if;
 if fixture_state like 'auto_%' and not exists(select 1 from public.player_picks where pot_id=pot
   and fixture_id=fixture-1 and exceptional_resolution_type='auto_win' and result_source=substr(fixture_state,6)) then
   raise exception '%: existing exceptional provenance changed',case_name;
 end if;
 if gw=38 then
   if not exists(select 1 from public.pot_completions where pot_id=pot and completed_by=admin_id)
     or (select count(*) from public.pot_winners where pot_id=pot)<>(case when mixed then 2 else 1 end)
     or exists(select 1 from public.pot_players where pot_id=pot and player_status<>'winner') then
     raise exception '%: GW38 did not include all genuinely final winners',case_name;
   end if;
 else
   if public.current_pot_gameweek(pot) is distinct from gw+1 then raise exception '%: final round did not progress',case_name; end if;
   if not exists(select 1 from public.pot_players where pot_id=pot and player_id=players[1]
     and player_status=case when expected_outcome='lost' then 'eliminated' else 'active' end) then
     raise exception '%: final membership outcome is incorrect',case_name;
   end if;
 end if;
 before_state:=pg_temp.finality_snapshot(pot);
 if gw=38 then
   result:=public.process_pot_gameweek(pot,gw,true);
   if (result->>'already_finalized')::boolean is distinct from true then raise exception '%: completion retry failed',case_name; end if;
 else
   rejected:=false;
   begin perform public.process_pot_gameweek(pot,gw,true);
   exception when raise_exception then
     if sqlerrm not like '%already been processed%' then raise; end if;
     rejected:=true;
   end;
   if not rejected then raise exception '%: repeated processing was accepted',case_name; end if;
 end if;
 if pg_temp.finality_snapshot(pot) is distinct from before_state then raise exception '%: retry changed immutable history',case_name; end if;
 raise notice 'PASS nullable finality: %',case_name;
end $$;

select pg_temp.verify_finality(1,'ordinary final win','final',10,false);
select pg_temp.verify_finality(2,'ordinary final loss with survivor','loss',10,true);
select pg_temp.verify_finality(3,'ordinary final draw with survivor','draw',10,true);
select pg_temp.verify_finality(4,'scheduled waits','scheduled',10,false);
select pg_temp.verify_finality(5,'live waits','live',10,false);
select pg_temp.verify_finality(6,'provisional waits','provisional',10,false);
select pg_temp.verify_finality(7,'NULL readiness waits, never becomes a loss','unknown',10,false);
select pg_temp.verify_finality(8,'incomplete scores wait','incomplete',10,false);
select pg_temp.verify_finality(9,'established postponed auto-win','auto_postponed',10,false);
select pg_temp.verify_finality(10,'established abandoned auto-win','auto_abandoned',10,false);
select pg_temp.verify_finality(11,'established void auto-win','auto_void',10,false);
select pg_temp.verify_finality(12,'postponed override without decision waits','override_postponed',10,false);
select pg_temp.verify_finality(13,'abandoned override without decision waits','override_abandoned',10,false);
select pg_temp.verify_finality(14,'void override without decision waits','override_void',10,false);
select pg_temp.verify_finality(15,'winning and provisional mixed cohort waits','provisional',10,true);
select pg_temp.verify_finality(16,'GW38 provisional player alone waits','provisional',38,false);
select pg_temp.verify_finality(17,'GW38 winning and provisional cohort waits','provisional',38,true);
select pg_temp.verify_finality(18,'GW38 winning and NULL readiness cohort waits','unknown',38,true);

-- Restore explicitly as well as rolling back; no injection escapes this test asset.
do $$ begin execute (select definition from finality_original_function); end $$;
rollback;
