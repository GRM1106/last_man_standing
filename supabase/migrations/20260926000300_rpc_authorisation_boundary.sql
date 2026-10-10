-- Supabase explicitly grants anon/authenticated execution by default. Revoking
-- PUBLIC alone does not remove those grants. No application RPC is public:
-- signup uses Auth; its profile trigger runs as the function owner.
begin;

-- Explicit signatures keep this correction limited to the audited application
-- surface, without changing extension functions or platform-wide defaults.
revoke execute on function
  public.claim_pot_payment(uuid),
  public.create_fixture_result_override(bigint,integer,integer,text,text,text),
  public.create_profile_for_new_user(),
  public.delete_draft_pot(uuid,text),
  public.fill_remaining_pot_gameweeks(uuid),
  public.fixture_effective_version(bigint),
  public.fixture_override_impact(bigint),
  public.fixture_result_lock_key(bigint),
  public.get_admin_fixture_results(text),
  public.get_admin_pick_overview(uuid,integer),
  public.get_my_pot_history(uuid),
  public.get_my_team_availability(uuid),
  public.get_p1_provenance_backfill_report(),
  public.get_pot_selection(uuid),
  public.get_pot_standings(uuid),
  public.prevent_pick_resolution_snapshot_change(),
  public.preview_fixture_result_override(bigint,integer,integer,text,text),
  public.reject_audit_row_mutation(),
  public.remove_player_from_pot(uuid,uuid),
  public.set_pot_player_payment(uuid,uuid,text),
  public.set_pot_status(uuid,text),
  public.set_test_pick_scenario(uuid,bigint,text),
  public.validate_fixture_result_override(integer,integer,text,text)
from public, anon;

-- These are implementation helpers, called by owner-executed RPCs/triggers.
-- Administrators use the checked preview/create RPCs, never these directly.
revoke execute on function
  public.fixture_override_impact(bigint),
  public.fixture_effective_version(bigint),
  public.fixture_result_lock_key(bigint),
  public.validate_fixture_result_override(integer,integer,text,text),
  public.create_profile_for_new_user(),
  public.reject_audit_row_mutation(),
  public.prevent_pick_resolution_snapshot_change()
from authenticated;

-- The retired manual-winner endpoint must authorise before inspecting a pot.
-- Keep its existing administrator-facing errors and disabled behaviour.
create or replace function public.complete_pot_with_winner(selected_pot_id uuid, selected_winner_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not (select public.is_current_user_admin()) then
    raise exception 'Administrator access required';
  end if;
  if exists(select 1 from public.pots where id=selected_pot_id and test_mode) then
    raise exception 'A pot in test mode cannot be completed';
  end if;
  raise exception 'Winner completion is determined by processing GW38';
end;
$$;

commit;
