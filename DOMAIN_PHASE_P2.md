# Domain Phase P2 — Controlled Result Corrections

Status: committed on `domain/phase-p2`, deployed and schema/security verified on
isolated staging, and not merged into `main`. **It is not approved or applied to
production.**

Phase P2 adds controlled authoritative fixture corrections on top of the P1
provenance foundation. It does not recalculate historical rounds or change any
existing resolution snapshot.

## Staging verification

The committed migration was deployed to the isolated `last-man-standing-staging`
project (`evhiixndiuwwodsouyhf`, `eu-west-1`) as
`20260822002400_result_corrections.sql`. Its source is commit
`24b183091ec27d9f426c58ab2f1eab787ae7dbe2` and its SHA-256 is
`7b4af55bf5f3e585fdd2f681cc645339694a7a82cef1e6da2d68d2596a38eccf`.
Staging now contains exactly 24 migrations. The deployment introduced no
application rows, and read-only schema and security inspection passed. A
`pg_dump` warning about the self-referencing override-chain foreign key was
expected. The administrator UI was not live-tested against staging.

Staging proves migration deployment, migration history, final schema shape and
security configuration. The disposable local Supabase execution separately
proves functional correction behavior, finality, authorization, rollback,
idempotency and all three concurrency races. Neither evidence source authorizes
production application.

## Result model

`football_fixtures` remains the raw provider record. FPL synchronization may
continue updating its scores, status and provider timestamps. It never updates,
deletes or supersedes `fixture_result_overrides`.

The effective result is the raw row when no override exists. Otherwise it is the
append-only override that has not been superseded by another override. A later
correction points to the prior effective override through `supersedes_id`, so the
full chain remains auditable.

A raw result is processable only when the provider reports `finished=true`,
`finished_provisional=false`, and both scores. A finished administrator override
with both scores is authoritative independently. Effective responses expose raw
finality, synchronization time, selected source and processability.

Finished corrections require two non-negative scores. Postponed, abandoned and
void corrections cannot have scores. Scores must always be supplied as a pair.
The server derives source from status; the browser cannot claim a provider
source. Blank reasons, unsupported transitions and no-op corrections are rejected.

## Administrator controls

The admin-only RPCs are:

- `get_admin_fixture_results(text)` — raw, effective and correction-history view.
- `preview_fixture_result_override(...)` — validates and reports affected pots
  without mutation.
- `create_fixture_result_override(...)` — serializes correction creation,
  appends the override and audit event, and flags affected processed/completed
  pots for review.

Preview returns an opaque effective version covering raw/effective fixture state
and processed/completed-pot impact. Mutation requires that version and, after
locking, rejects stale confirmation with `Result changed; preview again`.

Every callable RPC checks administrator identity. Mutation functions are
`SECURITY DEFINER`, use `search_path=''`, revoke public execution and grant only
`authenticated` execution. The underlying audit/provenance tables remain RLS
enabled, have no client write policy and remain append-only.

## Processing boundary

An unprocessed gameweek resolves from the effective result. Processing writes
the selected teams, effective scores, source, fixture season, status and database
resolution timestamp into the existing immutable pick snapshot in the same
transaction as outcomes and player elimination.

Synchronization, preview, mutation and processing share one lock order: fixture
advisory locks by ascending internal fixture ID, followed by pot/gameweek locks
by ascending pot ID/gameweek. Processing locks before readiness evaluation and
materializes one authoritative result set for its summary, outcomes and snapshots.

An override created after processing does not alter pick outcomes, snapshots,
player status, buy-backs, pot winner or completion state. The affected pot is
only marked `needs_review`, with append-only administrator audit evidence.
Historical recalculation is deferred to P3.

Postponed, abandoned and void overrides are representable and auditable, but P2
does not define survival or round-progression rules for them. They therefore do
not make a production gameweek processable.

## Disposable verification

Run only against a disposable Supabase-compatible database containing the full
P1 disposable test state:

1. Complete the documented P1 disposable sequence.
2. Apply `supabase/result_corrections.sql`.
3. Run `supabase/result_corrections_verification.sql`.

The verifier creates fixed-identifier synthetic data inside one transaction. It
checks preview purity, raw/effective separation, persistence across provider
resynchronization, authorization denial, append-only audit integrity, immutable
snapshot writing, processed-pot review flagging, no-op and invalid-value
rejection, supersession, provisional-result denial, stale-version rejection,
completed-pot preservation, chain constraints and rollback cleanup. It always
rolls back its synthetic rows and then asserts that none remain.

Genuine concurrency checks use two independent `psql` processes in the same fresh
disposable stack. Apply `result_corrections_concurrency_seed.sql`, then run this
exact Bash runner from the repository root. Each background process is one
terminal/session; `sleep 2` starts the other session during the script's
transactional `pg_sleep(10)`. The runner captures and asserts both exit codes:

```bash
set +e

# 1. Correction versus correction: B captures the old version first. A commits
# one root; B waits for A and must fail stale (psql exit 3).
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f supabase/result_corrections_concurrency_override_b.sql &
override_b_pid=$!
sleep 2
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f supabase/result_corrections_concurrency_override_a.sql
override_a_status=$?
wait "$override_b_pid"
override_b_status=$?
test "$override_a_status" -eq 0 && test "$override_b_status" -eq 3 || exit 1

# 2. Processing versus provider synchronization: A holds the fixture lock and
# processes. B waits, then synchronizes after A commits; both must succeed.
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f supabase/result_corrections_concurrency_process_a.sql &
process_a_pid=$!
sleep 2
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f supabase/result_corrections_concurrency_sync_b.sql
sync_b_status=$?
wait "$process_a_pid"
process_a_status=$?
test "$process_a_status" -eq 0 && test "$sync_b_status" -eq 0 || exit 1

# 3. Processing versus correction: correction B captures pre-processing impact.
# Processing A succeeds; B waits and must then fail stale (psql exit 3).
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f supabase/result_corrections_concurrency_process_correction_b.sql &
correction_b_pid=$!
sleep 2
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f supabase/result_corrections_concurrency_process_correction_a.sql
correction_process_a_status=$?
wait "$correction_b_pid"
correction_b_status=$?
test "$correction_process_a_status" -eq 0 && test "$correction_b_status" -eq 3 || exit 1

# Assert the one-root chain, locked snapshots, post-process raw synchronization,
# stale-correction rejection and process summaries produced by all three races.
psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -f supabase/result_corrections_concurrency_verification.sql
verification_status=$?
test "$verification_status" -eq 0 || exit 1
set -e
```

Expected results are: override A succeeds while override B waits and fails with
`Result changed; preview again`; processing and synchronization both succeed,
with synchronization waiting for processing to commit; and processing succeeds
while the competing correction waits and fails with the same stale-version error.
The final verification script must pass. These assets commit synthetic data and
are permitted only in a disposable database that is destroyed immediately afterward.

Never run disposable seed, rollback-verification, concurrency, preflight or
failure-test scripts against staging or production.

## Explicitly deferred

P2 does not implement historical recalculation/replay, snapshot replacement,
postponement survival, everyone-loses windows, new buy-back rules, payment/start
guards, winner rewriting, or prize splitting.
