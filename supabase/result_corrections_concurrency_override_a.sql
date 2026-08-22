-- Session A: start after session B has captured its version. Holds the fixture
-- lock while session B reaches the mutation and waits.
begin;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where is_admin order by created_at limit 1),true);
select public.create_fixture_result_override(-28304,1,0,'finished','Session A correction',public.fixture_effective_version(-28304));
select pg_sleep(10);
commit;
