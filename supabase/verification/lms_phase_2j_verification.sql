\set ON_ERROR_STOP on
begin;
do $$
declare claim jsonb;failed boolean:=false;health jsonb;
begin
  if to_regclass('public.lms_provider_runs') is null or to_regclass('public.lms_operations_config') is null then raise exception 'Phase 2J operations schema missing'; end if;
  if has_function_privilege('authenticated','public.claim_lms_provider_run(text)','execute') then raise exception 'Authenticated users can claim scheduler runs'; end if;
  if has_function_privilege('authenticated','public.complete_lms_provider_run(uuid,text,jsonb,jsonb)','execute') then raise exception 'Authenticated users can invoke internal ingestion'; end if;
  if (select provider_automation_enabled or competition_automation_enabled or scheduler_expected from public.lms_operations_config where singleton) then raise exception 'Deployment switches must default off'; end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin perform public.claim_lms_provider_run('scheduler'); exception when others then failed:=true; end;
  if not failed then raise exception 'Player scheduler invocation was accepted'; end if;
  perform set_config('request.jwt.claim.role','service_role',true);
  claim:=public.claim_lms_provider_run('scheduler');
  if claim->>'reason'<>'disabled' then raise exception 'Disabled scheduler did not safely skip: %',claim; end if;
  update public.lms_operations_config set provider_automation_enabled=true where singleton;
  claim:=public.claim_lms_provider_run('local_simulation');
  if not coalesce((claim->>'acquired')::boolean,false) then raise exception 'Local run could not claim lock: %',claim; end if;
  perform public.fail_lms_provider_run((claim->>'run_id')::uuid,'timeout',true);
  if not exists(select 1 from public.lms_provider_runs where id=(claim->>'run_id')::uuid and status='failed' and retryable) then raise exception 'Failure health not recorded'; end if;
  claim:=public.claim_lms_provider_run('local_simulation');
  perform public.complete_lms_provider_run((claim->>'run_id')::uuid,'2J-LOCAL',
    '[{"id":9901,"code":9901,"name":"Local Alpha","short_name":"LAL"},{"id":9902,"code":9902,"name":"Local Beta","short_name":"LBE"}]'::jsonb,
    '[{"id":99901,"event":1,"kickoff_time":"2026-08-30T14:00:00Z","team_h":9901,"team_a":9902,"team_h_score":null,"team_a_score":null,"started":false,"finished":false,"finished_provisional":false,"provisional_start_time":false}]'::jsonb);
  if not exists(select 1 from public.lms_provider_runs where id=(claim->>'run_id')::uuid and status='succeeded' and teams_count=2 and fixtures_count=1) then raise exception 'End-to-end local provider ingestion did not succeed'; end if;
  if not exists(select 1 from public.football_fixtures where fpl_fixture_id=99901 and season='2J-LOCAL') then raise exception 'Validated provider fact was not ingested'; end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000003001',true);
  health:=public.get_lms_operations_health();
  if health->>'freshness'<>'fresh' or health->>'scheduler_state'<>'not_deployed' then raise exception 'Health model unexpected: %',health; end if;
end $$;
rollback;
select 'Phase 2J scheduler readiness verification passed.';
