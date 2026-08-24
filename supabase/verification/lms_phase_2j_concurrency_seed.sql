\set ON_ERROR_STOP on
delete from public.lms_provider_runs;
update public.lms_operations_config set provider_automation_enabled=true,stuck_after=interval '15 minutes' where singleton;
