# Domain correctness Phase P1

## Scope

Phase P1 provides result provenance, audit storage, and cross-season integrity. It is intentionally non-behavioural: current processing still reads raw fixture scores and writes the existing outcomes and player statuses exactly as before.

The migration is [`supabase/result_provenance_foundation.sql`](supabase/result_provenance_foundation.sql). Apply it after all existing modules, ending with `player_team_availability.sql`.

> **Critical synchronization ordering:** Do not run any second-season,
> new-season, or historical FPL synchronization until P1 has completed. The
> pre-P1 global provider IDs allow such a sync to overwrite a prior season.
> Existing deployments apply P1 only as a forward migration after their current
> modules. Clean installations apply every module through P1 before the first FPL
> sync. In particular, never synchronize in the gap after the historical FPL
> setup module (`fpl_fixture_setup.sql`, README step 8) and before the final P1
> migration.

## Current-state findings

- `football_teams.fpl_team_id` and `football_fixtures.fpl_fixture_id` were globally unique.
- `sync_fpl_data` joined teams by provider ID alone and overwrote fixtures on a global provider-ID conflict, including the stored season.
- Picks referenced stable internal fixture/team IDs but had no immutable resolution facts.
- Fixture storage had raw scores and boolean lifecycle flags but no explicit provider status or provisional-finish flag.
- Result overrides, administrator audit history, player-status history, and pot review state did not exist.
- Later SQL modules replace earlier definitions of dashboard, selection, pick confirmation, random assignment, standings, and admin-pick overview. `sync_fpl_data` had only one definition. P1 replaces it and mechanically refreshes the effective `get_pot_selection` definition so its remaining-team list cannot mix seasons.

## Migration behavior

### Cross-season identity

- Adds `football_teams.season` and infers it only from unambiguous existing fixture/pot data.
- Discovers the deployed global unique-constraint names from PostgreSQL catalogs before dropping them.
- Enforces `(season, fpl_team_id)` and `(season, fpl_fixture_id)` uniqueness while retaining internal primary keys and foreign-key references.
- Updates `sync_fpl_data(text,jsonb,jsonb)` without changing its signature or response shape. Team lookup and both conflict targets are season-scoped.
- Adds season/query indexes.
- Aborts the transaction instead of deleting or merging anything if team season inference is ambiguous, duplicate scoped identities exist, or a pick already links a pot to a different fixture season.

### Raw provider state

Fixtures gain `status`, `finished_provisional`, and `provider_synced_at`. Existing status is deterministically backfilled as:

- `finished=true` → `finished`
- otherwise `started=true` → `live`
- otherwise → `scheduled`

Allowed status values are `scheduled`, `live`, `finished`, `postponed`, `abandoned`, and `void`. P1 never infers postponement from elapsed time and processing does not consume these fields yet. A constrained text value is used instead of a PostgreSQL enum so future rollback and status evolution do not inherit enum-removal hazards.

The fixed FPL proxy response now retains the upstream `finished_provisional` boolean so synchronization can store that raw provider fact. Its upstream URLs, caching, status handling, and safe error responses are unchanged.

### Pick-resolution snapshots

Picks gain nullable internal home/away team IDs, scores, source, resolution time, fixture season, and fixture-status snapshots. Resolved legacy picks are backfilled from their referenced fixture; test-run rows use retained test scores where available. Their source is honestly recorded as `legacy_backfill` or `test`, never as newly verified provider truth. Pending picks remain entirely nullable.

Once populated, snapshot fields are immutable. `survived` is accepted as a future outcome, but no P1 function produces it. The administrator-only `get_p1_provenance_backfill_report()` reports resolved, snapshotted, unbackfilled, and unexpectedly snapshotted-pending counts.

### Append-only history and review state

P1 creates:

- `fixture_result_overrides`
- `admin_audit_events`
- `pot_player_status_history`

Each table has RLS enabled, all direct privileges revoked from `public` and `authenticated`, no permissive client policy, useful indexes, and triggers that reject updates and deletes. P1 deliberately supplies no mutation RPC. Administrator/profile identifiers are retained as values where deletion-safe audit identity matters; material fixture/pot/player relationships use non-cascading foreign keys.

Pots gain `review_status` (`none`, `needs_review`, or `reviewed`), a nullable reason, and status-change timestamp. No existing function branches on this state.

## Verification

Database verification requires a disposable Supabase-compatible PostgreSQL
instance containing the Supabase Auth schema, `auth.uid()`, the `anon`,
`authenticated`, and `service_role` roles, an administrator profile, and every
pre-P1 module. Vanilla PostgreSQL is insufficient. Never connect these scripts to
production.

The normal reproducible path is:

1. Apply modules 1–22 on a clean disposable instance.
2. Run `result_provenance_pre_migration_seed.sql`. It commits representative legacy rows so the subsequent migration exercises its real backfill.
3. Run the read-only `result_provenance_preflight.sql` and retain only its sanitized counts.
4. Apply `result_provenance_foundation.sql`. The migration commits persistently, as it would in an existing deployment.
5. Run `result_provenance_foundation_verification.sql`. The verifier checks the committed migration and then rolls back its own temporary verification transaction.

The seed covers a normal resolved result, a test resolved result, a postponed test
result, a pending pick, and the nearest schema-valid incomplete-score legacy row.
A truly orphaned pick cannot be seeded without weakening the existing fixture
foreign key, so the verifier does not disable that integrity control merely to
manufacture one. It confirms snapshot source, scores, teams, season, status,
resolution time, unchanged outcome, stable internal fixture ID, pending-row
nullability, and the reported incomplete-row count.

Run the intentional failure path only on a separate freshly reset disposable
instance: apply modules 1–22, run `result_provenance_failure_seed.sql`, attempt P1
(it must abort on ambiguous season inference), and run the read-only
`result_provenance_failure_verification.sql` to prove the transaction left no P1
schema behind.

`supabase/result_provenance_foundation_verification.sql` also verifies scoped identities, season-isolated synchronization, invalid-value rejection, denied direct writes as both `authenticated` and `anon`, non-admin accessor denial, administrator accessor success, and unchanged existing function signatures.

Vitest supplements this with migration guard checks. It does not replace execution against PostgreSQL. No production Supabase connection is used by Phase P1 development.

### Disposable execution evidence — 2026-08-21

P1 was executed using Supabase CLI 2.115.0 and its isolated local PostgreSQL 17.6
container. The repository was not linked to a remote project. Modules 1–22 were
applied in README order without an FPL sync, followed by the committed legacy
seed, read-only preflight, P1 migration, and rollback-only verifier.

Sanitized preflight results were zero ambiguous multi-season teams, zero
pot/fixture season mismatches, zero duplicate scoped fixture IDs, four resolved
picks, one pending pick, and three resolved rows with incomplete raw provider
scores. Two of those three were legitimately derivable from retained test-result
data.

The migration committed and snapshotted three picks. Its report returned four
resolved picks, three snapshots, one unresolved incomplete-score backfill, zero
pending snapshots, and one unresolved-score row. The normal result used
`legacy_backfill`; the resolved and postponed test results used `test`; outcomes
and internal fixture references remained unchanged. The verifier passed
season-isolated synchronization, stable references, immutable snapshots,
administrator report access, and denied `authenticated` and `anon` writes/access.
Its final rollback left zero verification teams and pots. A migration rerun also
completed without changing the established classifications.

After a fresh local reset, the intentional ambiguity seed caused P1 to abort with
the expected multi-season team diagnostic. The failure verifier confirmed the
transaction left no P1 columns, audit tables, or constraint changes. The local
stack and its disposable database volume were then stopped without backup.

## Future rules recorded, not implemented

- Normal losers may use the existing optional individual buy-back before the next deadline.
- The private decision window applies only when every remaining player loses together; first scheduled pot round reinstates all, later rounds resolve from private optional activations.
- Entry payment must eventually become a start guard, with unpaid members removable before start.
- Historical corrections must flag administrator review and never silently change completed/paid results or winners.
- If multiple players remain after Gameweek 38 result and buy-back rules, the pot is split equally.

P1 does not implement any of those behaviors.

## Rollback guidance and limitations

Take a database backup before applying the migration. If the transaction fails, PostgreSQL rolls it back as a unit.

Before P2 writes any new provenance/audit data, rollback consists of restoring the previous `sync_fpl_data` definition, dropping the P1 triggers/functions/tables, removing the new checks/indexes/columns, restoring the original global unique constraints, and removing `football_teams.season`. Restoring global uniqueness will fail if more than one season has since been synchronized, so those newer rows must be preserved/exported and handled explicitly rather than deleted silently.

After snapshot, override, audit, or review data is populated, dropping columns/tables is destructive and is not represented as perfectly reversible. Prefer a forward repair migration. PostgreSQL constrained text was chosen specifically to avoid irreversible enum-label additions.

## Next phase

Phase P2 should implement authoritative fixture resolution and administrator overrides only: controlled append-only override creation, raw-versus-authoritative selection, audit events, snapshot writing for newly processed picks, and review flagging. It must not yet implement deterministic replay, postponement resolution, everyone-loses windows, or prize splitting.
