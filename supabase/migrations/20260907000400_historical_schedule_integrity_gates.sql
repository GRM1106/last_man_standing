-- Critical #2 follow-up: legacy-invalid round ordering must never drive a mutation.
-- Existing round identities and mappings remain untouched for reviewed repair.
begin;

do $$
begin
  if to_regprocedure('public.process_pot_gameweek(uuid,integer,boolean)') is null
    or to_regprocedure('public.run_lms_pot_automation_internal(uuid,text,uuid)') is null
    or to_regprocedure('public.claim_buy_back(uuid)') is null
    or to_regprocedure('public.confirm_buy_back(uuid,uuid)') is null
    or to_regprocedure('public.revoke_buy_back(uuid,uuid,text)') is null
    or to_regprocedure('public.set_buy_back_decision(uuid,uuid,boolean)') is null then
    raise exception 'Historical schedule integrity gates require the complete critical-remediation baseline';
  end if;
  if to_regprocedure('public.assert_lms_schedule_integrity(uuid)') is not null
    or to_regprocedure('public.process_pot_gameweek_schedule_integrity_base(uuid,integer,boolean)') is not null then
    raise exception 'Historical schedule integrity gates are already installed';
  end if;
end $$;

-- Serialise against schedule appends, then prove a complete one-to-one chronological
-- mapping. The same assertion is shared by every competition mutation entry point.
create function public.assert_lms_schedule_integrity(selected_pot_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),-2);
  if exists(
    select 1
    from (
      select g.gameweek_number,r.id round_id,r.sequence_number,
        row_number() over(order by g.gameweek_number) expected_sequence
      from public.pot_gameweeks g
      left join public.pot_rounds r
        on r.pot_id=g.pot_id and r.gameweek_number=g.gameweek_number
      where g.pot_id=selected_pot_id
    ) mapping
    where mapping.round_id is null
      or mapping.sequence_number is distinct from mapping.expected_sequence
  ) or exists(
    select 1 from public.pot_rounds r
    where r.pot_id=selected_pot_id and not exists(
      select 1 from public.pot_gameweeks g
      where g.pot_id=r.pot_id and g.gameweek_number=r.gameweek_number
    )
  ) then
    raise exception 'LMS schedule integrity requires reviewed repair before competition mutations';
  end if;
end $$;
revoke all on function public.assert_lms_schedule_integrity(uuid) from public,anon,authenticated;

alter function public.process_pot_gameweek(uuid,integer,boolean)
rename to process_pot_gameweek_schedule_integrity_base;
revoke all on function public.process_pot_gameweek_schedule_integrity_base(uuid,integer,boolean)
from public,anon,authenticated;
create function public.process_pot_gameweek(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  perform public.assert_lms_schedule_integrity(selected_pot_id);
  return public.process_pot_gameweek_schedule_integrity_base(selected_pot_id,selected_gameweek,apply_changes);
end $$;
revoke all on function public.process_pot_gameweek(uuid,integer,boolean) from public,anon;
grant execute on function public.process_pot_gameweek(uuid,integer,boolean) to authenticated;

alter function public.run_lms_pot_automation_internal(uuid,text,uuid)
rename to run_lms_pot_automation_schedule_integrity_base;
revoke all on function public.run_lms_pot_automation_schedule_integrity_base(uuid,text,uuid)
from public,anon,authenticated;
create function public.run_lms_pot_automation_internal(selected_pot_id uuid,run_source text,run_actor uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform public.assert_lms_schedule_integrity(selected_pot_id);
  return public.run_lms_pot_automation_schedule_integrity_base(selected_pot_id,run_source,run_actor);
end $$;
revoke all on function public.run_lms_pot_automation_internal(uuid,text,uuid)
from public,anon,authenticated;

alter function public.claim_buy_back(uuid) rename to claim_buy_back_schedule_integrity_base;
revoke all on function public.claim_buy_back_schedule_integrity_base(uuid)
from public,anon,authenticated;
create function public.claim_buy_back(selected_pot_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not exists(
    select 1 from public.pot_players
    where pot_id=selected_pot_id and player_id=(select auth.uid())
  ) then raise exception 'You are not assigned to this pot'; end if;
  perform public.assert_lms_schedule_integrity(selected_pot_id);
  perform public.claim_buy_back_schedule_integrity_base(selected_pot_id);
end $$;
revoke all on function public.claim_buy_back(uuid) from public,anon;
grant execute on function public.claim_buy_back(uuid) to authenticated;

alter function public.confirm_buy_back(uuid,uuid) rename to confirm_buy_back_schedule_integrity_base;
revoke all on function public.confirm_buy_back_schedule_integrity_base(uuid,uuid)
from public,anon,authenticated;
create function public.confirm_buy_back(selected_pot_id uuid,selected_player_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  perform public.assert_lms_schedule_integrity(selected_pot_id);
  perform public.confirm_buy_back_schedule_integrity_base(selected_pot_id,selected_player_id);
end $$;
revoke all on function public.confirm_buy_back(uuid,uuid) from public,anon;
grant execute on function public.confirm_buy_back(uuid,uuid) to authenticated;

alter function public.revoke_buy_back(uuid,uuid,text) rename to revoke_buy_back_schedule_integrity_base;
revoke all on function public.revoke_buy_back_schedule_integrity_base(uuid,uuid,text)
from public,anon,authenticated;
create function public.revoke_buy_back(selected_pot_id uuid,selected_player_id uuid,revoke_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  perform public.assert_lms_schedule_integrity(selected_pot_id);
  return public.revoke_buy_back_schedule_integrity_base(selected_pot_id,selected_player_id,revoke_reason);
end $$;
revoke all on function public.revoke_buy_back(uuid,uuid,text) from public,anon;
grant execute on function public.revoke_buy_back(uuid,uuid,text) to authenticated;

alter function public.set_buy_back_decision(uuid,uuid,boolean)
rename to set_buy_back_decision_schedule_integrity_base;
revoke all on function public.set_buy_back_decision_schedule_integrity_base(uuid,uuid,boolean)
from public,anon,authenticated;
create function public.set_buy_back_decision(selected_pot_id uuid,selected_player_id uuid,approved boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  perform public.assert_lms_schedule_integrity(selected_pot_id);
  perform public.set_buy_back_decision_schedule_integrity_base(selected_pot_id,selected_player_id,approved);
end $$;
revoke all on function public.set_buy_back_decision(uuid,uuid,boolean) from public,anon;
grant execute on function public.set_buy_back_decision(uuid,uuid,boolean) to authenticated;

do $$
begin
  if has_function_privilege('authenticated','public.assert_lms_schedule_integrity(uuid)','execute')
    or has_function_privilege('anon','public.assert_lms_schedule_integrity(uuid)','execute') then
    raise exception 'Schedule integrity assertion must remain internal';
  end if;
  if has_function_privilege('authenticated','public.process_pot_gameweek_schedule_integrity_base(uuid,integer,boolean)','execute')
    or has_function_privilege('authenticated','public.run_lms_pot_automation_schedule_integrity_base(uuid,text,uuid)','execute')
    or has_function_privilege('authenticated','public.claim_buy_back_schedule_integrity_base(uuid)','execute')
    or has_function_privilege('authenticated','public.confirm_buy_back_schedule_integrity_base(uuid,uuid)','execute')
    or has_function_privilege('authenticated','public.revoke_buy_back_schedule_integrity_base(uuid,uuid,text)','execute')
    or has_function_privilege('authenticated','public.set_buy_back_decision_schedule_integrity_base(uuid,uuid,boolean)','execute') then
    raise exception 'An unguarded schedule mutation base remains exposed';
  end if;
  if not exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='assert_lms_schedule_integrity'
      and p.prosecdef and array_to_string(p.proconfig,',') like 'search_path=%'
  ) then
    raise exception 'Schedule integrity assertion must keep SECURITY DEFINER and an empty search_path';
  end if;
end $$;

commit;
