# Production maintenance and write-freeze runbook

This implementation is locally qualified. **Nothing in this document authorises production activation, bootstrap installation, migration, deployment or scheduler work.** Obtain renewed approval for the new candidate and the sequence below. Previous candidate: `c580478fa8f4439364be573f87d2d8853fb3a9c0`.

## Mechanism and boundary

One authoritative row, `lms_maintenance.state`, controls the freeze. Normal users, administrators, anonymous callers and service-role callers share the same boundary. Every public base table has an ALWAYS statement trigger for INSERT, UPDATE, DELETE and TRUNCATE. A DDL event hook covers new/altered public tables during the upgrade. Existing RLS, RPC authorisation, competition rules and audit attribution are retained. Direct table permissions are not widened. Application roles cannot create public tables, call the private control functions or read private state/audit tables.

The trigger checks the original database session/role and JWT context, not `current_user` inside a SECURITY DEFINER function. Only a direct `postgres` operator, or a `cli_login_%` session proved to be a member of `postgres`, with original role `none`/`postgres` and no JWT claims, can bypass. Service role has no exemption, even for provider/audit writes. Confirm `current_user=postgres` and `lms_maintenance.is_operator()=true` on the actual future migration connection; do not infer this from a connection label. Do not change roles or weaken this check to work around a failed preflight.

Auth new-user INSERT has a normal statement guard, using the platform-granted trigger capability without altering ownership of `auth.users`. A rejected signup rolls back the Auth transaction and profile creation together. Existing login, refresh and logout can continue where they do not mutate public state. Password recovery remains managed Auth behaviour; no mail delivery test or hosted Auth change is implied. Any Auth-triggered public write is still guarded. Do not give the Auth service replica-mode privileges.

This freezes **LMS application state**, not all managed Auth session rows. Take a transactionally consistent backup and record expected Auth-session churn separately. Normal operators must refrain from unrelated writes during the window. This is not a defence against the trusted database owner deliberately dropping guards.

## Cutover and switching

Application writes take shared transaction advisory lock `761394820527001`. It lasts until their transaction commits/rolls back. Switching takes its exclusive counterpart before changing state: **the committed enable call is the cutover point**, after already-admitted writes have drained. Later requests encounter ON. Locking reads of the state row prevent a pre-cutover repeatable-read snapshot from seeing stale OFF; such transactions abort rather than write.

The switch waits at most ten seconds for a conflicting lock, then fails without changing state. Inspect/drain identified application activity rather than retrying blindly or killing unknown sessions. Read-only transactions may still hold DDL-conflicting locks; inspect them before migration. Configure appropriate migration lock/statement timeouts and stop on any unexpected wait/failure.

Run only through the approved direct operator connection, in an explicitly committed transaction (the standalone calls below use normal autocommit):

```sql
-- The transaction must commit before treating the switch as active.
select lms_maintenance.set_enabled(true, 'Approved release window: <release identifier>');
select public.get_lms_maintenance(); -- must return {"enabled":true}
-- Reopen only after database, deployment and controlled verification acceptance.
select lms_maintenance.set_enabled(false, 'Release accepted: <release identifier>');
select public.get_lms_maintenance(); -- must return {"enabled":false}
```

Changes are appended to `lms_maintenance.events` with database session user, timestamp and operator reason. Missing state or state-read errors deny application writes. Public status exposes only a boolean; UI HTTP/network/malformed-response failures show a safe unavailable screen. Activation does not depend on source edits or a redeployment once the maintenance-aware UI is installed.

## First installation: explicit bootstrap before the legacy upgrade

Production currently has the effects of migrations 1–22. Waiting until migration 59 to install protection would leave the upgrade unprotected. The exact file `supabase/migrations/20260927000100_maintenance_write_freeze.sql` is therefore also the reviewed **additive, idempotent bootstrap**, executed on the first-22 schema before migration history repair. This is a new production operation requiring explicit approval. Do not mark migration 59 applied early or skip its later replay.

The disposable restored-checkpoint rehearsal tested this order: first-22 checkpoint → exact bootstrap → maintenance ON → baseline ledger → migrations 23–59 → verification → OFF. It preserved the switch and audit entries when migration 59 ran again. Bootstrap changes are confined to the private maintenance schema/functions/audit, public status RPC, public guards/event hook, Auth INSERT guard and removal of application schema CREATE privilege. It does not change competition rows or hosted Auth configuration. Reconcile precisely these known catalogue additions; stop for any other drift.

There are now **59 migrations**, **37 pending** after the 22-entry baseline, from `20260821002300` through `20260927000100`. All previous 58 migration files remain unchanged. Future release approval must name the new committed candidate and current SHA-256 manifest; the earlier 36-file approval is superseded.

The already-deployed old frontend cannot display a component it does not contain. The initial rollout therefore needs an explicit **maintenance-UI deployment step after bootstrap/ON and before legacy migrations**. The new candidate waits for an explicit OFF status before initialising account/dashboard/admin data; while ON it uses the status endpoint and logout only. Deploy that exact maintenance-aware candidate under the established freeze, verify the screen, then proceed. This is not an early reopening: old tabs remain blocked by the database and the new UI remains closed. After database migration, confirm the same exact candidate/deployment or redeploy that candidate if required. Do not silently substitute a frontend-only maintenance page or pretend the old bundle already supports the screen.

## Future production sequence — not executed

1. Verify approved candidate, clean release workspace, explicit production identity, credentials/operator identity, original recovery checksums and qualified restore procedure. Scheduler/cron must still be absent/off. Reconfirm the 59-file manifest; capture current migration metadata.
2. Capture a fresh read-only baseline and compatibility results. Stop for drift. Preserve a protected consistent recovery checkpoint before installing bootstrap; keep the original checkpoint immutable.
3. Under specific bootstrap authority, install the exact migration-59 file on the legacy baseline without changing migration history. Verify every public table guard, the Auth INSERT guard, private ACLs and public status. Enable maintenance with a recorded reason, commit, and verify ON. No competition processing runs as a consequence.
4. Perform the separately approved initial maintenance-UI deployment described above. Verify desktop/mobile maintenance, no partial dashboard, status requests targeting production, and logout. For subsequent releases this UI already exists and no preliminary UI deployment is needed.
5. Prove denial using an approved test identity/token issued before cutover. A valid mutation must reach the maintenance guard and return `LMS_MAINTENANCE`; a missing-RPC/permission/business-rule error is not proof. Prefer a prepared no-op mutation (for example retaining an approved test membership's current payment status), verify zero row/event/fingerprint changes, and never choose a real result/review action as a probe. A rollback-only SQL role simulation supplements, but does not replace, the HTTP check.
6. Confirm activation drained admitted writes and inspect `pg_stat_activity`/locks for remaining application sessions, waits and old transactions. Confirm scheduler remains absent/off. Capture the final frozen baseline and a fresh consistent protected backup; verify its checksum/restore according to the recovery plan. Record the exact restore point. Auth session activity may continue and must be explicitly accounted for.
7. Establish migrations 1–22 in history with the approved CLI repair mechanism, without executing their DDL. Read back exactly those 22 entries, no others, and unchanged application data. Reconcile the explicitly approved bootstrap catalogue additions.
8. Preview exactly 37 pending versions using explicit production targeting and `--skip-vault`; apply in order only after the preview matches. Do not include seeds/roles or reapply baseline DDL. Keep maintenance ON across all files. New public tables receive guards automatically. Migration 59 must preserve ON and the private audit. Stop on any unexplained error/warning; never mark failed SQL applied.
9. Require 59 exact ledger entries. Reconcile frozen application data, expected backfills/approval transformations, Auth relationships, final function definitions, RLS, ACLs, table guards, private controls and event hook. Validate operator access and application denial again. Do not accept missing guards or an unexpected bypass.
10. Confirm/deploy the exact approved application candidate and only required non-scheduler backend components. `/api/fpl` remains the read-only provider proxy; scheduler Edge Function stays undeployed. Do not rotate credentials or change Auth as a side effect.
11. While ON, test maintenance screens, status/logout, permitted reads, required RPC existence/permissions and attempted writes being rejected. Successful normal write journeys cannot be tested through ordinary clients while ON: there is intentionally no administrator exemption. Exercise positive write journeys only in the already-qualified disposable environment until reopening.
12. After accepting these gates, disable maintenance with an audited reason and commit. If a post-reopen check fails, re-enable using the same verified switch and preserve evidence; do not automatically reverse database migrations.
13. Confirm normal login/dashboard/admin operation and approved minimal reversible test writes. New UI reloads on ON→OFF so stale data/controls are discarded. Reconcile every test-created record; do not resolve real reviews or process real competition results for testing.
14. Capture post-release counts/fingerprints and account for only authorised smoke activity and legitimate Auth session churn. Verify release hash, production targets, browser console/network health, Git state and rollback information.
15. Keep scheduler function, cron and automation flags OFF. Maintenance being OFF is not authority to process competitions.
16. Request separate scheduler deployment/configuration/invocation/schedule authority after production smoke acceptance.

## Local verification and rollback

`npm run test:db` includes every public table guard, real player/admin/service RPCs, real Auth-role insertion, nested SECURITY DEFINER, operator DDL/backfill, missing state, OFF→ON→OFF and observed transaction races. `npm test` includes status failure/malformed response, startup gating, dialogues, logout and reopen behaviour. The restored-production rehearsal separately proves bootstrap before the pending chain and clean final-schema equivalence.

For a failed local test or interrupted browser check, return only the verified local environment's maintenance state to OFF. Never use an implicit remote/linked target. In a future production incident, leave ON unless reopening is explicitly accepted. Disabling removes the freeze but does not remove guards or erase audit history. Removing maintenance infrastructure is not the normal rollback and requires its own review.
