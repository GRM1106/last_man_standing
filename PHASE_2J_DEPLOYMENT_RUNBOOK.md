# Phase 2J — Staging and Production Deployment Runbook

This is a runbook, not authorization. Phase 2J performed no remote access.

## BACKUP / RESTORE OPERATOR GATE

Stop unless the operator can name the backup mechanism, confirm the exact target project, demonstrate or document a viable restore path, state the recovery-point/recovery-time expectations, and explicitly accept residual risk. An unknown or untested restore path means `NOT READY` regardless of migration test results.

## Staging-first procedure

Target reference, only after separate authorization: `evhiixndiuwwodsouyhf`.

1. Record the local commit, migration checksums, application build, and test evidence. Confirm no production credentials are loaded.
2. Confirm backup/restore capability and take the approved staging backup/snapshot.
3. Read the actual remote migration/schema state. Do not rely on the previously reported Modules 1–22 + P1 + P2 state. Compare tables, functions, overloads, grants, RLS policies, triggers, extensions, and migration history.
4. Produce the exact catch-up list. Expected order, only where missing, is P1/P2/Phase 1 → 2A → 2B → 2C → 2D → 2E → 2F → 2G → 2H → 2I → 2J. Never edit an already-applied migration or skip a dependency.
5. Apply the approved missing migrations in order with the application and both automation flags off. Keep `scheduler_expected=false`. Recheck private RPC grants and admin/player RLS.
6. Configure staging-only Edge Function secrets: season, a unique scheduler secret, timeout/retry values, and platform-provided Supabase credentials. Confirm none are in the client bundle or repository.
7. Deploy the Edge Function but do not create cron. Verify unauthenticated/player calls fail, an admin manual sync succeeds, partial/malformed provider input cannot ingest, and health reveals no raw stack/secret.
8. Run staging smoke cases: authentication, player pick/privacy, missed/random pick, normal results, exceptional fixture/correction, collective reinstatement, buy-back, GW38 winner/terminal state, governed review, Phase 2I manual automation, provider manual sync, stale-data guard, recovery, and overlap serialization.
9. Test both kill switches. With provider automation off, scheduled-source simulation must record a safe skip. With competition automation off, ingestion may succeed while the scan reports disabled.
10. Review evidence and hold a staging go/no-go. Phase 2J does not authorize cron creation. A later staging phase may set `scheduler_expected=true`, enable switches deliberately, create a two-hour cron, observe multiple runs, test disabling, and document platform logs/cost.

Steps 6 and 7 must be carried out through the guarded repository commands, which prove the
target and pass an explicit `--project-ref` before invoking the Supabase CLI. Do not run a
raw `supabase secrets set` or `supabase functions deploy`: both inherit whatever project
this checkout happens to be linked to.

```sh
npm run supabase:check:staging                                    # prove the target
npm run supabase:secrets:set:staging -- --env-file <path outside the repo>
npm run supabase:deploy:staging -- --dry-run                      # confirm, then re-run without --dry-run
```

See [`SUPABASE_TARGET_GUARD.md`](SUPABASE_TARGET_GUARD.md) for the secret input mechanism,
the production block and the link-contradiction rules. The guard is a safety control; it
does not replace the authorization this runbook requires.

Disable/rollback: disable or delete the platform cron first, set both database automation flags false, preserve run history, and leave player/read-only/manual-safe features available. If the Edge Function is faulty, roll it back to the last known version — on a first deployment there is no earlier version, so the rollback is deletion via `npm run supabase:delete:staging`. Database migrations are forward-only; use a reviewed corrective migration, not destructive rollback. Restore only through the approved backup procedure.

## Production procedure

Target reference, only after separate authorization: `enzdvsppduyqtpdeseyh`.

Production is a separate decision, not an automatic repetition of staging.

1. Require signed staging evidence: exact schema delta, migrations applied, full smoke results, concurrency results, Edge runtime logs, scheduler cadence observations, kill-switch proof, backup/restore proof, and unresolved-risk acceptance.
2. Hold an explicit production go/no-go with an owner, maintenance window, communications plan, and rollback/disable owner.
3. Query and compare the actual production schema. Expected historical state is Modules 1–22-era only, but treat that solely as a hypothesis. Generate and review the precise forward migration sequence.
4. Pass the production BACKUP / RESTORE OPERATOR GATE and take the approved backup.
5. Apply only the approved missing migrations in order. Keep provider automation, competition automation, and scheduler expectation off.
6. Deploy the application/function with production-specific secrets. Verify client bundles and logs contain no secret; verify player, admin, and service-role ACLs.
7. Run read-only/application smoke checks, then one admin manual provider sync and one manual automation scan. Confirm health, data counts, freshness, exceptional-fixture safeguards, and no unexpected sporting mutation.
8. Hold a second explicit enablement checkpoint. Only a later authorized phase may create cron, set `scheduler_expected=true`, and enable provider/competition switches. Start at the documented two-hour cadence.
9. Monitor initial runs for overlaps, staleness, partial pot failure, duration, and provider limits. Prove the kill switch again.

Production disable follows the same ordering: stop cron, disable both flags, preserve data/history, diagnose, and use a reviewed forward fix or approved restore.

## Exact prerequisites

Staging requires remote-read authorization, verified actual schema, backup/restore gate, reviewed migration delta, staging-only secrets, deploy authority, smoke-test accounts/data, and a later explicit scheduler-enable authorization.

Production additionally requires completed and accepted staging evidence, separate remote/change authorization, a production backup/restore gate, an approved window and rollback owner, reviewed production schema delta, production-only secrets, and two explicit go/no checkpoints (migration/deploy, then scheduler enablement).

## Recommended next Codex prompt

> Perform Phase 2K — Controlled Staging Deployment & Validation against staging project `evhiixndiuwwodsouyhf` only. Begin with the BACKUP / RESTORE OPERATOR GATE and a read-only live schema/migration comparison. Stop and report if the gate fails or the live state differs materially. After explicit operator approval of the exact migration plan, apply only missing migrations through Phase 2J, deploy the staging Edge Function with staging-only secrets while all automation and scheduler flags remain off, run the complete staging smoke/security/concurrency matrix, test manual sync and both kill switches, and return evidence plus a separate scheduler-enablement go/no recommendation. Do not access production, do not push/merge, and do not create or enable cron without a second explicit authorization.
