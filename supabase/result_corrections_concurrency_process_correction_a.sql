-- Session A: start after session B has captured its version, then process while
-- holding the fixture lock and changing impact state.
begin;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where is_admin order by created_at limit 1),true);
select pg_advisory_xact_lock(public.fixture_result_lock_key(-28305));
select pg_sleep(10);
select public.process_pot_gameweek('00000000-0000-0000-0000-000000002302',5,true);
commit;
