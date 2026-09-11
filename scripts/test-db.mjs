import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DisposableDatabase } from './lib/disposable-db.mjs';
import { verifyCriticalFindings, seedHistoricalData, verifyHistoricalData } from './verify-critical-db.mjs';

const root = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');
const db = new DisposableDatabase();
let stopping = false;
function stop(signal) {
  if (stopping) return;
  stopping = true;
  try { db.cleanup(); } catch (error) { console.error(error.message); }
  process.exit(signal === 'SIGINT' ? 130 : 143);
}
process.once('SIGINT', () => stop('SIGINT'));
process.once('SIGTERM', () => stop('SIGTERM'));
try {
  await db.start();
  db.sql(read('scripts/db-test-bootstrap.sql'));
  const migrations = readdirSync(fileURLToPath(new URL('supabase/migrations/', root))).filter(f => f.endsWith('.sql')).sort();
  const baseline = migrations.filter(f => f < '20260907000100');
  const corrections = migrations.filter(f => f >= '20260907000100');
  for (const name of baseline) {
    db.sql(read(`supabase/migrations/${name}`));
    console.log(`APPLIED baseline ${name}`);
  }
  console.log(`Baseline applied: ${baseline.length} historical migrations.`);
  seedHistoricalData(db);
  for (const name of corrections) {
    db.sql(read(`supabase/migrations/${name}`));
    console.log(`APPLIED corrective ${name}`);
  }
  verifyHistoricalData(db);
  // Existing rollback-based business-rule suites remain executable on the final schema.
  for (const name of [
    'lms_integrity_phase_1_verification.sql', 'lms_phase_2a_verification.sql',
    'lms_phase_2b_verification.sql', 'lms_phase_2c_verification.sql',
    'lms_phase_2d_verification.sql', 'lms_phase_2e_verification.sql',
    'lms_phase_2f_verification.sql', 'lms_phase_2g_verification.sql',
    'lms_phase_2h_verification.sql', 'lms_phase_2i_verification.sql',
    'lms_phase_2j_verification.sql', 'lms_phase_2k_automation_persistence_verification.sql',
  ]) {
    db.sql(read(`supabase/verification/${name}`));
    console.log(`PASS existing ${name}`);
  }
  db.sql(read('supabase/verification/lms_phase_2i_concurrency_seed.sql'));
  const automationRace = "begin; set local role authenticated; set local \"request.jwt.claim.sub\"='00000000-0000-0000-0000-000000003001'; set local \"request.jwt.claim.role\"='authenticated'; select public.run_lms_pot_automation('00000000-0000-0000-0000-000000012201'); commit;";
  const automationResults = await Promise.allSettled([db.sqlAsync(automationRace), db.sqlAsync(automationRace)]);
  for (const result of automationResults) if (result.status === 'rejected') throw result.reason;
  db.sql(read('supabase/verification/lms_phase_2i_concurrency_verify.sql'));
  db.sql(read('supabase/verification/lms_phase_2j_concurrency_seed.sql'));
  const providerRace = "begin; set local role service_role; set local \"request.jwt.claim.role\"='service_role'; select public.claim_lms_provider_run('local_simulation'); commit;";
  const providerResults = await Promise.allSettled([db.sqlAsync(providerRace), db.sqlAsync(providerRace)]);
  for (const result of providerResults) if (result.status === 'rejected') throw result.reason;
  db.sql(read('supabase/verification/lms_phase_2j_concurrency_verify.sql'));
  console.log('PASS existing two-session automation and provider races.');
  // Close disposable-only race fixtures before exercising the complete pipeline.
  db.sql("update public.lms_provider_runs set status='failed',completed_at=now() where status='running'; update public.pots set status='complete',lifecycle_status='complete' where season='PHASE2I-RACE';");
  await verifyCriticalFindings(db);
  console.log('PASS isolated database integration verification.');
} catch (error) {
  console.error(error.stderr?.toString() || error.stack || error);
  process.exitCode = 1;
} finally {
  try { db.cleanup(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
