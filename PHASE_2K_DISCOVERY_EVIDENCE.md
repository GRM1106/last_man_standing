# Phase 2K — Staging Discovery Evidence

Record of a read-only discovery run of `supabase/discovery/phase_2k_staging_discovery.sql`.
Discovery is read-only and does **not** authorize migrations, Edge Function deployment,
secret configuration, or cron. Those remain blocked until the gate in section 2 is
explicitly `READY` **and** the exact plan is separately approved.

## 1. Run metadata

| Field | Value |
|---|---|
| Date run (UTC) | |
| Operator | |
| Connected project ref (confirm before running) | |
| Confirmed this is **staging**, not production | ☐ yes |
| Local commit at time of run | |
| Output reviewed and secrets redacted before sharing | ☐ yes |

## 2. Gate status

| Gate | Status |
|---|---|
| BACKUP / RESTORE OPERATOR GATE | `NOT READY` |

Update only when every row below is satisfied. Any unchecked row keeps the gate `NOT READY`.

- ☐ Exact target project named
- ☐ Backup mechanism identified (name it, do not assume a plan tier)
- ☐ Backup actually taken
- ☐ Restore **demonstrated** into a scratch database — an untested dump does not count
- ☐ Recovery point / recovery time expectations stated
- ☐ Residual risk explicitly accepted

Restore demonstration notes (what was restored, where, and what verified it):

```
```

## 3. Query 1 — phase presence + object inventory

Paste result:

```
```

Derived phase state (from section 1 sentinels):

| Phase | Sentinel | Present? |
|---|---|---|
| P1/P2 baseline | `fixture_result_overrides`, `get_effective_fixture_result` | |
| Phase 1 | `sync_fpl_data_p2_base` / `process_pot_gameweek_p2_base` | |
| 2A | `lock_pot_membership_if_due(uuid)`, `pots.lifecycle_status` | |
| 2B | `pot_rounds`, `pot_round_players` | |
| 2C | `pot_player_team_cycles` | |
| 2D | `fixture_selection_block_events` | |
| 2E | `round_collective_reinstatements` | |
| 2F | `pot_player_buyback_events` | |
| 2G | `pot_completions` | |
| 2H | `lms_review_cases` | |
| 2I | `lms_automation_runs` | |
| 2J | `lms_provider_runs`, `lms_operations_config`, `lms_provider_state` | |

## 4. Query 2 — applied migration history

Paste result, or the exact error text if `supabase_migrations.schema_migrations` is absent:

```
```

Does migration history agree with the sentinel state in section 3? A sentinel object is strong
evidence that its migration was applied, but not proof on its own — manual drift can create a
sentinel independently of the migration that owns it. **Any disagreement between migration
history and the sentinel/inventory state stops the process and is reported.** It is not
reconciled by assuming either source is authoritative.

If query 2 errored, record the error text verbatim here. A missing relation, an insufficient
permission, and a runner schema-version incompatibility are different findings with different
consequences, and must be distinguished rather than assumed.

```
```

## 5. Query 3 — exact row counts

Paste result:

```
```

Assessment of data at risk (drives how strong the restore path must be):

```
```

## 6. Derived catch-up sequence

Migrations missing on staging, in dependency order, applied **only** where absent.
Never edit an already-applied migration and never skip a dependency.

```
```

## 7. Divergence from expectation

Anything present on staging that the local chain does not explain — extra tables, unexpected
table grants to `anon`/`authenticated`, **any `EXECUTE` on an internal routine held by
`anon`, `authenticated` or `PUBLIC` (section 6b)**, policy `USING`/`WITH CHECK` expressions
that do not match the migration source, disabled triggers, RESTRICTIVE policies, unknown
extensions, or an existing `pg_cron` job:

```
```

## 8. Outcome

- ☐ Discovery complete, no material divergence — proceed to migration-plan review
- ☐ Discovery complete, divergence found — stop and report (see section 7)
- ☐ Discovery blocked — record why

The migration plan may be prepared and reviewed while the gate is `NOT READY`. No migration,
function deployment, secret configuration, or cron change may begin until the gate is
explicitly `READY` and the exact plan is separately approved.
