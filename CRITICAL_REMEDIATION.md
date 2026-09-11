# Critical findings 1–4 remediation

Scope: these four findings only. The 42 historical migrations through
`20260824001000` are unchanged. Apply the five new migrations in timestamp order.
No migration rewrites existing round mappings, picks, cohorts, results or completions.

## 1. Explicit processing actor

The scheduler uses a service-role client without a user subject. The effective
processing/finalization functions previously inserted `auth.uid()` into mandatory
profile foreign keys, so automated round processing and GW38 completion failed.

`20260907000100_explicit_processing_actors.sql` introduces `lms_audit_actors`.
Existing humans retain their profile UUIDs; new profiles register an actor through a
trigger. `00000000-0000-0000-0000-000000000001` is a named `lms-scheduler` system
actor with no authentication account. Process/completion foreign keys now reference
this registry; both columns remain NOT NULL. Existing null automation attribution
stays historically unknown. Existing provider history gains a nullable actor column
without fabricated backfill; every new provider insert is attributed and its actor
cannot subsequently change.

Write-boundary triggers supply the actor when the existing processing bodies supply
NULL. Human administrative RPCs retain the actual authenticated UUID. For Edge
Function admin requests, the verified JWT user ID is passed to a service-only claim
adapter that checks the profile is an administrator. The durable claim records the
actor; completion locks that claim and resumes its actor in transaction-local context,
even on another pooled connection. The renamed ingestion implementation is no longer
an executable API entry point. Untrusted authenticated users cannot call the adapter
or impersonate a system actor. The service role remains a trusted server credential.

The Edge Function uses `server/scheduler-operations.js`, which is also executed by the
integration suite against the real SQL functions. This does not alter sporting rules,
provider retries, timeout policy or other failure-reporting behavior.

Operational prerequisite: pause/drain scheduler and manual provider refreshes before
migration; an active provider claim causes the migration to refuse installation.
Table locks serialize profile provisioning and provider claims with actor backfill
and trigger installation. Install the migration before deploying the updated Edge
Function. Existing custom reports that join these audit columns directly to profiles
must instead join actors and optionally the actor's profile.

## 2. Deterministic round ordering and existing-data repair plan

`create_pot` used unordered DISTINCT output, while a row trigger assigned COUNT + 1.
The new `20260907000200_deterministic_round_order.sql` explicitly orders both
`create_pot` and `fill_remaining_pot_gameweeks`. A statement-level transition-table
trigger ranks each inserted set by gameweek, under the existing per-pot advisory lock.
This also covers direct multi-row insertion and progression-created gameweeks.

Existing round IDs/sequences are never renumbered. Later insertions must append in
chronological order. Filling an earlier gap, or extending a pot whose existing
sequences are already inconsistent, fails with a reviewed-repair requirement rather
than silently changing historical meaning.

Run `supabase/diagnostics/critical_round_order.sql` as a database operator. It starts a
read-only transaction and reports mismatched/missing mappings, expected sequences,
round IDs, lifecycle, membership lock, pick/process counts and buy-back event counts.
It makes no repairs. A regression seeds an incorrect historical mapping before the
corrective migrations, verifies the rows remain byte-for-byte equivalent as JSON,
and proves the diagnostic detects it.

`20260907000400_historical_schedule_integrity_gates.sql` closes the populated-upgrade
gap. One internal assertion serialises with schedule appends and proves the complete
gameweek-to-round mapping is chronological. Manual processing, per-pot automation,
buy-back claim, confirmation, revocation and the legacy decision adapter all call it
before competition mutation. Unguarded implementations remain internal. An affected
pot fails with a reviewed-repair requirement; the migration does not renumber rounds
or rewrite picks, cohorts, processes, automation evidence, entitlements or buy-backs.

`20260907000500_consistent_mutation_lock_order.sql` closes the concurrency issue
introduced by the gate. Provider completion now locks every pot that its subsequent
automation scan can visit, in deterministic UUID order, before fixture ingestion.
The shared order is schedule, per-pot automation, fixture result, then gameweek
processing. Administrative scans use the same UUID order, and the unguarded provider
implementation remains service-internal. A two-session regression holds a pot's
schedule lock in manual processing while provider completion begins against the same
fixture; both transactions must complete without deadlock.

If the diagnostic reports affected pots:

1. Pause provider/competition automation and administrator processing for those pots;
   retain the diagnostic output and take a restorable database backup.
2. Produce a per-pot old-to-expected sequence mapping retaining each round ID and its
   gameweek. Capture picks, finalized cohorts, process/completion records, team cycles,
   reinstatements and buy-back source/destination/deadline events. Verify actual
   business impact; counts alone do not establish that renumbering is safe.
3. For a pristine pot with no participation or dependent history, prepare an explicitly
   reviewed transaction that repairs only sequences (and missing round rows, if any),
   using temporary nonconflicting positive sequence values to satisfy uniqueness.
   Lock the pot/schedule, compare the captured state before writing, then rerun the
   diagnostic and chronological-creation checks. Do not apply a generic mass update.
4. For any pot with activity, determine whether earlier wrong ordering affected picks,
   eliminations, cycle transitions, deadlines, buy-backs or winners. Renumbering alone
   cannot repair those effects. Prepare a pot-specific governed decision and repair
   script, preserve original evidence/audit rows, and rehearse it on a restored copy.
   Obtain operational approval for that concrete repair before applying it.
5. Reconcile affected player outcomes, verify no concurrent changes occurred, record
   the repair and its operator, and only then resume automation.

No executable repair or mutation of the normal development database is included.

## 3. Disposable database test safety

`scripts/test-db-phase1.sh` now delegates to `scripts/test-db.mjs`. There are no
Supabase stop/reset commands. `scripts/lib/disposable-db.mjs` creates a fresh UUID-named
container and database for every run; it accepts no existing database/container target.
It uses the cached image `public.ecr.aws/supabase/postgres:17.6.1.165`, no network,
no exposed ports, no host binds and temporary database storage.

Before SQL execution the runner verifies its full created container ID, exact name,
run ownership label, image, isolated network/mount configuration, database name and
per-database ownership marker. Before cleanup it verifies container ownership again.
Only that exact container ID and its attached anonymous volumes can be deleted.
The target identity is printed before creation and destruction. Inspection failure,
identity mismatch or an unexpected mount fails closed; there is no cleanup-by-prefix,
volume pruning or fallback targeting the development stack. SIGINT/SIGTERM clean only
the same owned resource. SIGKILL/host failure may leave an isolated orphan, which must
be inspected by an operator; the runner never guesses ownership or sweeps old runs.

Run with Docker available and the pinned image already cached:

```sh
npm test
npm run test:db
npm run test:build-targets
```

The database suite applies all historical migrations and then the corrections, runs
12 existing SQL verification suites, retains the two genuine concurrent-session races,
and executes the new chronological creation, history preservation, scheduler actor and
RLS authorization regressions. PostgreSQL business functions, permissions, RLS and
transactions are real. `scripts/db-test-bootstrap.sql` supplies a minimal Supabase
Auth schema/claim fixture; identity issuance, OAuth, PostgREST and the Edge gateway
are outside this test harness. Deterministic provider responses replace live FPL HTTP.
Guard unit tests cover swapped IDs/names/labels/images/networks, host and named mounts,
missing or wrongly typed bind/mount metadata, incomplete and unexpected mount types,
missing creation identity, wrong database marker and cleanup targeting. Mocked cleanup
proves that failed mount evidence never reaches `docker rm`.

## 4. Private review records

`20260907000300_private_review_records.sql` restricts SELECT on review cases,
resolution events, completion adjudications and adjudicated-winner ledgers to admins
through RLS. Browser mutation grants remain revoked. It also removes member direct
SELECT on pots, because governed-review summaries are copied into `pots.review_reason`.
The player application already uses the explicit `get_my_dashboard` projection,
which continues to return the player's pots without that private field. Administrator
pot queries keep their existing access.

`get_my_pot_review_state` returns membership-gated open/resolved/dismissed counts,
`under_review`, and an empty cases array to members; administrators retain case details.
`get_my_pot_review_outcome` exposes only revision, decision time, total prize and winner
name/is-me/prize-share fields. Unrelated users receive NULL; anonymous execution is
revoked. No reason, evidence, impact snapshot, case identifier or administrator ID is
included in the member projection. Authorization tests use SET ROLE authenticated,
not just a privileged connection with a different subject claim, and assert exact
allowed response keys, admin visibility and preserved dashboard access.

The new outcome RPC replaces direct member ledger access at the API boundary. Wiring
revised outcomes into the existing original-completion presentation is a separate
previously identified UI finding and is deliberately outside this remediation.

## Verification and deployment boundary

The remediation is tested locally in disposable databases. Before hosted rollout,
confirm the expected 42-migration baseline, run the read-only round diagnostic, pause
and drain provider runs, take a backup, apply the five migrations, then deploy the
Edge Function. Verify PostgREST schema refresh, real JWT/service-role requests, admin
and member UI access, scheduled-secret invocation, and actual cron operation in staging.
No hosted migration, cron change or production credential operation is part of this
remediation. Never run the fixture or verification scripts against staging/production.

### Observed local results — 2026-09-07

- `npm test -- --no-cache --configLoader runner`: 22 files, 220 tests passed.
- `npm run test:db`: 42 historical migrations plus all three corrections applied;
  historical preservation and the read-only diagnostic passed; all 12 existing SQL
  suites, both concurrent-session races and all targeted critical regressions passed.
  The runner reported and removed only its own unique container.
- `npm run build -- --configLoader runner`: production build passed in the isolated
  checkout (75 modules). This is a build verification, not a deployment.
- The normal development container remained untouched, using its existing
  development volume. Before/after checks matched: 42 migrations,
  zero profiles, zero pots, zero picks. The diagnostic returned zero affected pots.
  No correction was applied to that database; no application row was changed.
- Hosted data and cron were not accessed. A zero-row local diagnostic makes no claim
  about hosted pots; run the diagnostic there before considering a repair.

### Final acceptance verification — 2026-09-11

- `npm test`: 24 files, 267 tests passed.
- `npm run test:db`: 42 historical migrations plus all five corrections applied;
  all 12 existing SQL suites, both concurrent-session races and all targeted
  regressions passed. The populated fixture retained `GW2→1, GW1→2, GW3→3` while
  processing, automation and every buy-back mutation were refused with no state
  change. The real cleanup guard accepted complete Docker inspection metadata and
  removed only its labelled disposable container; no labelled test container remained.
  The two-session manual-processing/provider-ingestion regression also completed
  without deadlock.
- `npm run test:build-targets` passed both isolated bundle/configuration checks and
  every fail-closed target check. The deployable staging bundle also passed using the
  repository's non-secret validation key.
- A direct production build was correctly refused because this checkout is linked to
  the staging Vercel project. A staging build without a publishable key was correctly
  refused. These are pre-existing environment safety controls, not remediation
  failures.
- Hosted authentication/gateway, hosted data, scheduled-secret invocation and cron
  remain unverified. No hosted or development database was changed.
