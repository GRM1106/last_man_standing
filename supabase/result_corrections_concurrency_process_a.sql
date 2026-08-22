-- Session A: lock then process. Session B synchronization must block until commit.
begin;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where is_admin order by created_at limit 1),true);
select pg_advisory_xact_lock(public.fixture_result_lock_key(-28301));
select pg_sleep(10);
select public.process_pot_gameweek('00000000-0000-0000-0000-000000002301',1,true);
commit;
