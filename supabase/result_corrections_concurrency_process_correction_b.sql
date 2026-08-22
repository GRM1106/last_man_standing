-- Session B: start first. It captures pre-processing impact, pauses so session
-- A can process, then must fail stale after waiting for the shared locks.
begin;
select public.fixture_effective_version(-28305) as expected_effective_version \gset
select pg_sleep(10);
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where is_admin order by created_at limit 1),true);
select public.create_fixture_result_override(-28305,0,2,'finished','Concurrent correction',:'expected_effective_version');
commit;
