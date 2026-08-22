-- Session B: start first. It captures the old version, pauses so session A can
-- commit its correction, then must fail stale rather than fork the chain.
begin;
select public.fixture_effective_version(-28304) as expected_effective_version \gset
select pg_sleep(10);
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where is_admin order by created_at limit 1),true);
select public.create_fixture_result_override(-28304,2,0,'finished','Session B stale correction',:'expected_effective_version');
commit;
