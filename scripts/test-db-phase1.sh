#!/usr/bin/env bash
set -euo pipefail

container_name="supabase_db_last_man_standing"
modules=(
  supabase/setup.sql
  supabase/fix_google_names.sql
  supabase/admin_setup.sql
  supabase/pot_setup.sql
  supabase/player_dashboard_setup.sql
  supabase/pot_gameweek_schedule.sql
  supabase/fix_multiple_player_pots.sql
  supabase/fpl_fixture_setup.sql
  supabase/player_pick_setup.sql
  supabase/admin_pick_overview.sql
  supabase/test_result_setup.sql
  supabase/gameweek_processing.sql
  supabase/buy_back_setup.sql
  supabase/pot_management.sql
  supabase/random_pick_setup.sql
  supabase/round_progression.sql
  supabase/tournament_operations.sql
  supabase/pot_standings.sql
  supabase/pick_deadlines.sql
  supabase/player_standings.sql
  supabase/standings_window.sql
  supabase/player_team_availability.sql
  supabase/result_provenance_foundation.sql
  supabase/result_corrections.sql
  supabase/migrations/20260823000100_lms_integrity_phase_1.sql
  supabase/migrations/20260823000200_lms_phase_2a_lifecycle.sql
  supabase/migrations/20260823000300_lms_phase_2b_round_foundation.sql
  supabase/migrations/20260823000400_lms_phase_2c_team_cycles.sql
  supabase/migrations/20260823000500_lms_phase_2d_exceptional_fixtures.sql
  supabase/migrations/20260823000600_lms_phase_2e_collective_reinstatement.sql
  supabase/migrations/20260823000700_lms_phase_2f_buyback_lifecycle.sql
  supabase/migrations/20260823000800_lms_phase_2g_gw38_winners.sql
  supabase/migrations/20260824000100_lms_phase_2h_governed_review.sql
  supabase/migrations/20260824000200_lms_phase_2i_automation.sql
)

cleanup() {
  npx supabase stop --no-backup >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
npx supabase start -x studio,imgproxy,inbucket,storage-api,edge-runtime,logflare,vector,supavisor,realtime >/dev/null

for module in "${modules[@]:0:22}"; do
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres < "$module"
done

docker exec "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres -c \
  "insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000003001','authenticated','authenticated','phase1-admin@example.test','local-test-only',now(),'{\"provider\":\"email\",\"providers\":[\"email\"]}','{\"first_name\":\"Phase\",\"last_name\":\"Admin\",\"full_name\":\"Phase Admin\"}',now(),now()); update public.profiles set approved=true,is_admin=true where id='00000000-0000-0000-0000-000000003001';"

for module in "${modules[@]:22}"; do
  docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres < "$module"
done

docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_integrity_phase_1_verification.sql

docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2a_verification.sql

docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2b_verification.sql

docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2c_verification.sql
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2d_verification.sql
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2e_verification.sql
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2f_verification.sql
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2g_verification.sql
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2h_verification.sql
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2i_verification.sql
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2i_concurrency_seed.sql
race_sql="select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000003001',false);select public.run_lms_pot_automation('00000000-0000-0000-0000-000000012201');"
docker exec "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres -c "$race_sql" >/dev/null & race_one=$!
docker exec "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres -c "$race_sql" >/dev/null & race_two=$!
wait "$race_one"; wait "$race_two"
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
  < supabase/verification/lms_phase_2i_concurrency_verify.sql

echo "LMS Integrity Phase 1 and Phases 2A-2I database verification plus two-session race passed."
