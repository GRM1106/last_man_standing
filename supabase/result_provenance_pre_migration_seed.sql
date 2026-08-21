-- Phase P1 representative legacy seed
-- Run only in an empty disposable Supabase database after all pre-P1 modules
-- and before result_provenance_foundation.sql. This transaction commits so the
-- migration can transform the rows. Never run this file in production.

begin;

do $$
begin
  if exists(select 1 from public.pots where id in (
    '00000000-0000-0000-0000-00000000a101',
    '00000000-0000-0000-0000-00000000a102'
  )) then
    raise exception 'Phase P1 seed namespace already exists; reset the disposable database before reseeding';
  end if;
  if not exists(select 1 from public.profiles where is_admin) then
    raise exception 'Phase P1 seed requires one test administrator profile';
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='football_teams' and column_name='season') then
    raise exception 'Phase P1 seed must run against the pre-migration schema';
  end if;
end;
$$;

create temporary table p1_seed_context(admin_id uuid not null) on commit drop;
insert into p1_seed_context select id from public.profiles where is_admin order by created_at limit 1;

insert into public.football_teams(id,fpl_team_id,code,name,short_name,emblem_url,updated_at)
values
  (-24101,-24101,-24101,'P1 Seed Team 01','P01',null,'2030-08-01T00:00:00Z'),
  (-24102,-24102,-24102,'P1 Seed Team 02','P02',null,'2030-08-01T00:00:00Z'),
  (-24103,-24103,-24103,'P1 Seed Team 03','P03',null,'2030-08-01T00:00:00Z'),
  (-24104,-24104,-24104,'P1 Seed Team 04','P04',null,'2030-08-01T00:00:00Z'),
  (-24105,-24105,-24105,'P1 Seed Team 05','P05',null,'2030-08-01T00:00:00Z'),
  (-24106,-24106,-24106,'P1 Seed Team 06','P06',null,'2030-08-01T00:00:00Z'),
  (-24107,-24107,-24107,'P1 Seed Team 07','P07',null,'2030-08-01T00:00:00Z'),
  (-24108,-24108,-24108,'P1 Seed Team 08','P08',null,'2030-08-01T00:00:00Z'),
  (-24109,-24109,-24109,'P1 Seed Team 09','P09',null,'2030-08-01T00:00:00Z'),
  (-24110,-24110,-24110,'P1 Seed Team 10','P10',null,'2030-08-01T00:00:00Z');

insert into public.football_fixtures(
  id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,
  home_score,away_score,started,finished,provisional_start_time,updated_at
)
values
  (-25101,-25101,'P1-SEED-2030',1,'2030-08-10T15:00:00Z',-24101,-24102,2,0,true,true,false,'2030-08-10T18:00:00Z'),
  (-25102,-25102,'P1-SEED-2030',2,'2030-08-17T15:00:00Z',-24103,-24104,null,null,false,false,false,'2030-08-17T18:00:00Z'),
  (-25103,-25103,'P1-SEED-2030',3,'2030-08-24T15:00:00Z',-24105,-24106,null,null,false,false,false,'2030-08-20T12:00:00Z'),
  (-25104,-25104,'P1-SEED-2030',1,'2030-08-10T15:00:00Z',-24107,-24108,null,null,false,false,false,'2030-08-10T18:00:00Z'),
  (-25105,-25105,'P1-SEED-2030',2,'2030-08-17T15:00:00Z',-24109,-24110,null,null,false,false,false,'2030-08-17T18:00:00Z');

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,created_at,test_mode)
select '00000000-0000-0000-0000-00000000a101'::uuid,'P1 Seed Production','P1-SEED-2030',0,0,'draft',admin_id,'2030-08-01T00:00:00Z'::timestamptz,false
from p1_seed_context
union all
select '00000000-0000-0000-0000-00000000a102'::uuid,'P1 Seed Test Mode','P1-SEED-2030',0,0,'draft',admin_id,'2030-08-01T00:00:00Z'::timestamptz,true
from p1_seed_context;

insert into public.pot_gameweeks(pot_id,gameweek_number)
values
  ('00000000-0000-0000-0000-00000000a101',1),
  ('00000000-0000-0000-0000-00000000a101',2),
  ('00000000-0000-0000-0000-00000000a101',3),
  ('00000000-0000-0000-0000-00000000a102',1),
  ('00000000-0000-0000-0000-00000000a102',2);

insert into public.pot_players(pot_id,player_id,player_status,payment_status)
select '00000000-0000-0000-0000-00000000a101'::uuid,admin_id,'active','paid' from p1_seed_context
union all
select '00000000-0000-0000-0000-00000000a102'::uuid,admin_id,'active','paid' from p1_seed_context;

insert into public.player_picks(
  id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,confirmed_at,selection_reason
)
select -26101,'00000000-0000-0000-0000-00000000a101'::uuid,admin_id,1,-25101,-24101,'manual','won','2030-08-09T12:00:00Z'::timestamptz,'P1 normal legacy result' from p1_seed_context
union all
select -26102,'00000000-0000-0000-0000-00000000a102'::uuid,admin_id,1,-25104,-24107,'manual','lost','2030-08-09T12:05:00Z'::timestamptz,'P1 test-derived result' from p1_seed_context
union all
select -26103,'00000000-0000-0000-0000-00000000a102'::uuid,admin_id,2,-25105,-24109,'manual','postponed','2030-08-16T12:00:00Z'::timestamptz,'P1 postponed test result' from p1_seed_context
union all
-- This is the nearest valid unresolved-backfill case: pre-P1 constraints allow
-- a resolved outcome to reference an unfinished scoreless fixture, although
-- process_pot_gameweek itself would reject it. No FK or constraint is weakened.
select -26104,'00000000-0000-0000-0000-00000000a101'::uuid,admin_id,2,-25102,-24103,'admin','won','2030-08-16T12:05:00Z'::timestamptz,'P1 schema-valid incomplete legacy result' from p1_seed_context
union all
select -26105,'00000000-0000-0000-0000-00000000a101'::uuid,admin_id,3,-25103,-24105,'manual','pending','2030-08-20T12:00:00Z'::timestamptz,'P1 pending pick' from p1_seed_context;

insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by,processed_at)
select '00000000-0000-0000-0000-00000000a101'::uuid,1,false,'{}'::jsonb,admin_id,'2030-08-10T18:05:00Z'::timestamptz from p1_seed_context
union all
select '00000000-0000-0000-0000-00000000a101'::uuid,2,false,'{}'::jsonb,admin_id,'2030-08-17T18:05:00Z'::timestamptz from p1_seed_context
union all
select '00000000-0000-0000-0000-00000000a102'::uuid,1,true,'{}'::jsonb,admin_id,'2030-08-10T18:10:00Z'::timestamptz from p1_seed_context
union all
select '00000000-0000-0000-0000-00000000a102'::uuid,2,true,'{}'::jsonb,admin_id,'2030-08-17T18:10:00Z'::timestamptz from p1_seed_context;

insert into public.pot_fixture_test_results(pot_id,fixture_id,home_score,away_score,postponed,updated_at)
values
  ('00000000-0000-0000-0000-00000000a102',-25104,0,1,false,'2030-08-10T18:09:00Z'),
  ('00000000-0000-0000-0000-00000000a102',-25105,null,null,true,'2030-08-17T18:09:00Z');

commit;
