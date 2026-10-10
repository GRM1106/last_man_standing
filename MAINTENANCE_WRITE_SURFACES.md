# Maintenance write-surface audit

The inventory below covers the actual first-22 checkpoint catalogue and the final 59-migration catalogue. It deliberately includes read helpers and trigger functions so indirect `SECURITY DEFINER` paths are not omitted. SQL bodies and calls are inspected for writes; all public base tables receive statement guards regardless of this classification. Existing authorisation/RLS checks remain in force.

| Write surface | Caller | Direct table/RPC | RLS applies? | SECURITY DEFINER? | Protection |
|---|---|---|---|---|---|
| Public tables (all 9 at checkpoint; 31 after upgrade) | API roles, admin, service callers | INSERT/UPDATE/DELETE/TRUNCATE | Existing RLS; definer/owner may bypass | Any writer | ALWAYS statement trigger on every base table; final suite exercises all 31 with temporary grants to prove guard independently of RLS |
| Newly created public tables | Same | Any DML | Existing migration policies | Any writer | DDL event hook adds guards before table creation/alter transaction commits; clients cannot create tables |
| Auth signup/new OAuth identity creating a user | Managed Auth database role | INSERT auth.users → profile triggers | Managed Auth | Profile trigger is definer | Auth INSERT statement guard; whole Auth transaction fails, no orphan profile/user |
| Existing Auth login/refresh/logout/recovery | Auth service | Managed Auth tables | Managed Auth | Platform controlled | Remain available when they do not write public state; any public side effect is guarded |
| Browser registration/dashboard/admin | anon/player/admin JWT | Direct REST and RPC | Existing model | See inventory | Database enforcement independent of new UI; startup/polling overlay communicates state |
| /api/fpl | Public HTTP GET | Public-provider fetch only | N/A | No | No database credentials or database writes in route |
| lms-scheduler Edge Function | service role, authenticated admin entry | Provider/automation RPCs | Service can bypass RLS | Yes | No service exemption: public writes are guarded; remains undeployed/off in production |
| Maintenance status | anon/authenticated/service | get_lms_maintenance | No data access granted | Yes, read only | Returns only enabled boolean; missing state means ON |
| Switch/audit and migration backfills | Direct postgres / verified CLI member of postgres | Private SQL only | Operator | Yes | Connection identity + original SET ROLE + absence of JWT; switching is not a public RPC |

## Complete function inventory

“Potential write” includes direct DML, dynamic SQL and transitive calls to writers. Pure-read classifications are informational; enforcement never relies on a list of RPC names. Existing functions do not use `nextval`, `setval`, replica-mode changes or network SQL to write outside the guarded application tables.

### First-22 baseline

| Function/signature | Caller grants | Definer | Surface | Maintenance boundary |
|---|---|---|---|---|
| `add_player_to_pot(selected_pot_id uuid, selected_player_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `assign_random_missing_picks(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `claim_buy_back(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `claim_pot_payment(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `complete_pot_with_winner(selected_pot_id uuid, selected_winner_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `confirm_team_pick(selected_pot_id uuid, selected_fixture_id bigint, selected_team_id bigint)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `create_pot(pot_name text, pot_season text, entry_fee_pence integer, buy_back_fee_pence integer, gameweek_numbers integer[], player_ids uuid[])` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `create_profile_for_new_user()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `delete_draft_pot(selected_pot_id uuid, confirmation_name text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `fill_remaining_pot_gameweeks(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `get_admin_pick_overview(selected_pot_id uuid, selected_gameweek integer)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_gameweek_deadline(selected_pot_id uuid, selected_gameweek integer)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_my_dashboard()` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_my_pot_history(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_my_team_availability(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_pot_selection(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_pot_standings(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `is_current_user_admin()` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `process_pot_gameweek(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `remove_player_from_pot(selected_pot_id uuid, selected_player_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reset_draft_test_pot(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reset_test_gameweek(selected_pot_id uuid, selected_gameweek integer)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `rls_auto_enable()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_buy_back_decision(selected_pot_id uuid, selected_player_id uuid, approved boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_player_approval(player_id uuid, new_approved boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_pot_player_payment(selected_pot_id uuid, selected_player_id uuid, new_payment_status text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_pot_status(selected_pot_id uuid, new_status text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_pot_test_mode(selected_pot_id uuid, enabled boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_test_pick_scenario(selected_pot_id uuid, selected_pick_id bigint, scenario text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `sync_fpl_data(selected_season text, fpl_teams jsonb, fpl_fixtures jsonb)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |

### Final application chain

| Function/signature | Caller grants | Definer | Surface | Maintenance boundary |
|---|---|---|---|---|
| `active_team_cycle_id(selected_pot_id uuid, selected_player_id uuid)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `add_player_to_pot(selected_pot_id uuid, selected_player_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `add_player_to_pot_before_requests(selected_pot_id uuid, selected_player_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `assert_lms_schedule_integrity(selected_pot_id uuid)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `assign_random_missing_picks(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `attribute_lms_processing()` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `capture_exceptional_status_reversal()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `capture_pick_fixture_eligibility()` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `capture_pot_review_flag()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `claim_buy_back(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `claim_buy_back_schedule_integrity_base(selected_pot_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `claim_lms_provider_run(run_source text)` | service_role | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `claim_lms_provider_run_for_admin(run_source text, administrator_id uuid)` | service_role | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `claim_pot_payment(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `complete_lms_provider_run(run_id uuid, selected_season text, fpl_teams jsonb, fpl_fixtures jsonb)` | service_role | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `complete_lms_provider_run_before_actors(run_id uuid, selected_season text, fpl_teams jsonb, fpl_fixtures jsonb)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `complete_lms_provider_run_lock_order_base(run_id uuid, selected_season text, fpl_teams jsonb, fpl_fixtures jsonb)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `complete_pot_with_winner(selected_pot_id uuid, selected_winner_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `confirm_buy_back(selected_pot_id uuid, selected_player_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `confirm_buy_back_schedule_integrity_base(selected_pot_id uuid, selected_player_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `confirm_team_pick(selected_pot_id uuid, selected_fixture_id bigint, selected_team_id bigint)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `create_fixture_result_override(selected_fixture_id bigint, selected_home_score integer, selected_away_score integer, selected_status text, selected_reason text, expected_effective_version text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `create_initial_team_cycle()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `create_lms_round_for_gameweek()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `create_pot(pot_name text, pot_season text, entry_fee_pence integer, buy_back_fee_pence integer, gameweek_numbers integer[], player_ids uuid[])` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `create_profile_for_new_user()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `current_lms_audit_actor()` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `current_pot_gameweek(selected_pot_id uuid)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `current_team_cycle_id(selected_pot_id uuid, selected_player_id uuid)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `decide_pot_membership(selected_pot_id uuid, selected_player_id uuid, expected_version integer, accept_request boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `delete_draft_pot(selected_pot_id uuid, confirmation_name text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `ensure_current_team_cycle(selected_pot_id uuid, selected_player_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `fail_lms_provider_run(run_id uuid, failure_class text, is_retryable boolean)` | service_role | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `fill_remaining_pot_gameweeks(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `finalize_gw38_pot(selected_pot_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `fixture_effective_version(selected_fixture_id bigint)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `fixture_is_selection_blocked(selected_fixture_id bigint)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `fixture_override_impact(selected_fixture_id bigint)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `fixture_result_lock_key(selected_fixture_id bigint)` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_admin_fixture_results(selected_season text)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_admin_pick_overview(selected_pot_id uuid, selected_gameweek integer)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_admin_player_memberships(selected_player_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_available_pots()` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_effective_fixture_result(selected_fixture_id bigint)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_gameweek_deadline(selected_pot_id uuid, selected_gameweek integer)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_lms_automation_status(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_lms_maintenance()` | anon,authenticated,service_role | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_lms_operations_health()` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_my_dashboard()` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_my_pot_history(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_my_pot_review_outcome(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_my_pot_review_state(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_my_team_availability(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_p1_provenance_backfill_report()` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_player_provider_notice()` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_pot_completion(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_pot_join_requests(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_pot_rounds(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_pot_selection(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `get_pot_standings(selected_pot_id uuid)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `is_current_user_admin()` | authenticated,service_role | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `link_pick_to_lms_round()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `link_pick_to_team_cycle()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `link_process_to_lms_round()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `lms_player_display_name(first_name text, last_name text, display_name text, email text)` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `lms_pot_accepts_members(selected_pot_id uuid)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `lms_revised_winner_projection(selected_pot_id uuid, selected_player_ids uuid[])` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `lock_pot_membership_if_due(selected_pot_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `open_lms_review_case(selected_pot_id uuid, selected_case_type text, selected_summary text, selected_round_id uuid, selected_fixture_id bigint, selected_pick_id bigint, selected_player_id uuid, selected_evidence jsonb, selected_source text)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `pot_eligible_team_count(selected_pot_id uuid)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `preserve_provider_actor()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `prevent_automation_run_mutation()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `prevent_buyback_event_mutation()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `prevent_completion_mutation()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `prevent_exceptional_resolution_change()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `prevent_membership_event_change()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `prevent_pick_resolution_snapshot_change()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `prevent_review_history_mutation()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `preview_fixture_result_override(selected_fixture_id bigint, selected_home_score integer, selected_away_score integer, selected_status text, selected_reason text)` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `preview_lms_review_resolution(selected_case_id uuid, selected_action text, selected_player_ids uuid[])` | authenticated | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `process_pot_gameweek(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `process_pot_gameweek_p2_base(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `process_pot_gameweek_phase2d_base(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `process_pot_gameweek_phase2f_base(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `process_pot_gameweek_phase2j_base(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `process_pot_gameweek_schedule_integrity_base(selected_pot_id uuid, selected_gameweek integer, apply_changes boolean)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `refresh_open_pot_gameweek_deadlines(selected_season text)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `register_profile_audit_actor()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reject_audit_row_mutation()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `reject_finalized_cohort_mutation()` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |
| `remove_player_from_pot(selected_pot_id uuid, selected_player_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `request_pot_membership(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reset_draft_test_pot(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reset_draft_test_pot_phase2e_base(selected_pot_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reset_draft_test_pot_phase2f_base(selected_pot_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reset_draft_test_pot_phase2h_base(selected_pot_id uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reset_test_gameweek(selected_pot_id uuid, selected_gameweek integer)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `reset_test_gameweek_phase2d_base(selected_pot_id uuid, selected_gameweek integer)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `resolve_fixture_exceptional_picks()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `resolve_lms_review_case(selected_case_id uuid, selected_action text, resolution_reason text, expected_version_token text, selected_player_ids uuid[])` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `revoke_buy_back(selected_pot_id uuid, selected_player_id uuid, revoke_reason text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `revoke_buy_back_schedule_integrity_base(selected_pot_id uuid, selected_player_id uuid, revoke_reason text)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `roll_team_cycle_after_pick()` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `run_lms_pot_automation(selected_pot_id uuid)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `run_lms_pot_automation_internal(selected_pot_id uuid, run_source text, run_actor uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `run_lms_pot_automation_schedule_integrity_base(selected_pot_id uuid, run_source text, run_actor uuid)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `scan_lms_automation()` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `scan_lms_automation_internal(run_source text)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_buy_back_decision(selected_pot_id uuid, selected_player_id uuid, approved boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_buy_back_decision_schedule_integrity_base(selected_pot_id uuid, selected_player_id uuid, approved boolean)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_fixture_selection_block(selected_fixture_id bigint, blocked boolean, reason text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_initial_pot_gameweek_deadline()` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `set_pot_discoverable(selected_pot_id uuid, discoverable boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_pot_lifecycle(selected_pot_id uuid, new_lifecycle text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_pot_player_payment(selected_pot_id uuid, selected_player_id uuid, new_payment_status text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_pot_status(selected_pot_id uuid, new_status text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_pot_test_mode(selected_pot_id uuid, enabled boolean)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `set_test_pick_scenario(selected_pot_id uuid, selected_pick_id bigint, scenario text)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `sync_fpl_data(selected_season text, fpl_teams jsonb, fpl_fixtures jsonb)` | authenticated | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `sync_fpl_data_p2_base(selected_season text, fpl_teams jsonb, fpl_fixtures jsonb)` | owner/internal trigger | Yes | Potential write / writer call | Public-table guards at the actual write; no definer exemption |
| `team_cycle_is_exhausted(selected_cycle_id uuid)` | owner/internal trigger | Yes | Read / internal helper | Read allowed; any downstream public write still guarded |
| `validate_fixture_result_override(selected_home_score integer, selected_away_score integer, selected_status text, selected_reason text)` | owner/internal trigger | No | Read / internal helper | Read allowed; any downstream public write still guarded |

## Service-role and operator boundary

`service_role` is an application identity and is blocked, including provider run/audit writes. The migration bypass requires session user `postgres`, or a `cli_login_%` login which is a member of `postgres`, original role `none`/`postgres`, and no JWT claim settings. `current_user` alone is never trusted: it becomes the owner inside a definer function. A bearer token cannot acquire the direct database connection identity or call the private switch. Tests include a nested definer writer and actual Auth-role connection.

## Scope and Auth limitations

Auth session/token/recovery activity may continue; this freezes LMS application state, not every managed Auth-table row. New users are rejected transactionally (including service-admin creation through Auth). Existing-user recovery email handling remains the platform behaviour and is not disabled or redesigned. Full backup capture must use one consistent snapshot, and post-cutover comparisons must distinguish legitimate Auth-session churn from application-state changes. No real-user email or production Auth setting was touched.
