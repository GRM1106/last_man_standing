\set ON_ERROR_STOP on
do $$
declare running_count integer;attempt_count integer;
begin
  select count(*) into running_count from public.lms_provider_runs where status='running';
  select count(*) into attempt_count from public.lms_provider_runs;
  if running_count<>1 then raise exception 'Expected exactly one authoritative provider execution, got %',running_count; end if;
  if attempt_count<>2 then raise exception 'Expected both provider attempts in history, got %',attempt_count; end if;
  if not exists(select 1 from public.lms_provider_runs where status='skipped' and error_class='overlap') then raise exception 'Overlap attempt was not represented safely'; end if;
end $$;
select 'Phase 2J two-session provider overlap verification passed.';
