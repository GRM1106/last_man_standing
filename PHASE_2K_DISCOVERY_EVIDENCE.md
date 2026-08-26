# Phase 2K — Staging Discovery Evidence

Record of a read-only discovery run of `supabase/discovery/phase_2k_staging_discovery.sql`.
Discovery is read-only and does **not** authorize migrations, Edge Function deployment,
secret configuration, or cron. Those remain blocked until the gate in section 2 is
explicitly `READY` **and** the exact plan is separately approved.

## 1. Run metadata

| Field | Value |
|---|---|
| Date run (UTC) | 2026-08-26 |
| Operator | Codex, through the user's authenticated Chrome session |
| Connected project ref (confirm before running) | `evhiixndiuwwodsouyhf` (`last-man-standing-staging`) |
| Confirmed this is **staging**, not production | ☑ yes |
| Local commit at time of run | `e69179c501829c9c2f075cc5a336bb1d511ad312` |
| Output reviewed and secrets redacted before sharing | ☑ yes — no secrets appeared |

## 2. Gate status

| Gate | Status |
|---|---|
| BACKUP / RESTORE OPERATOR GATE | `NOT READY` |

Update only when every row below is satisfied. Any unchecked row keeps the gate `NOT READY`.

- ☑ Exact target project named: `evhiixndiuwwodsouyhf` (`last-man-standing-staging`)
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
Query executed successfully: 148 rows.

Phase presence:
- P1/P2 baseline sentinels: present
- Phase 1 sentinels and pick_deadline_at: ABSENT
- Phase 2A sentinels and lifecycle_status: ABSENT
- Phase 2B through Phase 2J sentinels: ABSENT

Inventory summary:
- 12 public base tables; RLS enabled on all 12
- 12 SELECT policies, all permissive
- 4 non-internal triggers, all enabled
- 5 extensions: pg_stat_statements, pgcrypto, plpgsql, supabase_vault, uuid-ossp
- pg_cron: not installed
- pg_get_expr executed cleanly for USING and WITH CHECK expressions
- information_schema.routine_privileges executed cleanly

Important ACL findings:
- anon has REFERENCES, TRIGGER and TRUNCATE on multiple public tables.
- authenticated has REFERENCES, TRIGGER and TRUNCATE on multiple public tables,
  plus SELECT on the intended player-visible tables/views.
- No anon routine EXECUTE grant was returned.
- PUBLIC can execute create_profile_for_new_user() and rls_auto_enable().
- Authenticated EXECUTE grants exist for the application's public RPC surface,
  including admin-gated SECURITY DEFINER routines.
```

Derived phase state (from section 1 sentinels):

| Phase | Sentinel | Present? |
|---|---|---|
| P1/P2 baseline | `fixture_result_overrides`, `get_effective_fixture_result` | present |
| Phase 1 | `sync_fpl_data_p2_base` / `process_pot_gameweek_p2_base` | ABSENT |
| 2A | `lock_pot_membership_if_due(uuid)`, `pots.lifecycle_status` | ABSENT |
| 2B | `pot_rounds`, `pot_round_players` | ABSENT |
| 2C | `pot_player_team_cycles` | ABSENT |
| 2D | `fixture_selection_block_events` | ABSENT |
| 2E | `round_collective_reinstatements` | ABSENT |
| 2F | `pot_player_buyback_events` | ABSENT |
| 2G | `pot_completions` | ABSENT |
| 2H | `lms_review_cases` | ABSENT |
| 2I | `lms_automation_runs` | ABSENT |
| 2J | `lms_provider_runs`, `lms_operations_config`, `lms_provider_state` | ABSENT |

Derived sentinel state: staging contains Modules 1–22 plus the P1/P2 result-provenance
and correction baseline. Phase 1 and Phases 2A–2J are absent.

## 4. Query 2 — applied migration history

Paste result, or the exact error text if `supabase_migrations.schema_migrations` is absent:

```
Query executed successfully: 24 rows.

20260821000100 setup
20260821000200 fix_google_names
20260821000300 admin_setup
20260821000400 pot_setup
20260821000500 player_dashboard_setup
20260821000600 pot_gameweek_schedule
20260821000700 fix_multiple_player_pots
20260821000800 fpl_fixture_setup
20260821000900 player_pick_setup
20260821001000 admin_pick_overview
20260821001100 test_result_setup
20260821001200 gameweek_processing
20260821001300 buy_back_setup
20260821001400 pot_management
20260821001500 random_pick_setup
20260821001600 round_progression
20260821001700 tournament_operations
20260821001800 pot_standings
20260821001900 pick_deadlines
20260821002000 player_standings
20260821002100 standings_window
20260821002200 player_team_availability
20260821002300 result_provenance_foundation
20260822002400 result_corrections
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
Migration history and sentinel state agree: the runner records Modules 1–22 plus
P1/P2, and no Phase 1 or Phase 2A–2J migration record is present.
```

## 5. Query 3 — exact row counts

Paste result:

```
fixture_result_overrides  0
football_fixtures         0
football_teams            0
player_picks              0
pot_gameweeks             0
pot_players               0
pots                      0
profiles                  0
```

Assessment of data at risk (drives how strong the restore path must be):

```
All eight core tables are empty. Query 8 below also confirms that the four remaining
public base tables and auth.users are empty. Staging therefore contains schema but no
application rows or user accounts in the complete counted inventory. This makes a
deterministic rebuild plus demonstrated scratch restore proportionate, but it does not
by itself change the backup/restore gate from NOT READY.
```

## 5A. Queries 4–8 — ACL and remaining-data follow-up

All five sections in `supabase/discovery/phase_2k_acl_followup.sql` executed successfully
and separately against the confirmed staging ref.

### Query 4 — current default privileges

For objects created by `postgres` in `public`, current table defaults grant both `anon`
and `authenticated` `Dxtm`: `TRUNCATE`, `REFERENCES`, `TRIGGER`, and `MAINTAIN`.
They do not grant those roles `SELECT` or ordinary DML through that default. Defaults
for objects created by `supabase_admin` are broader, but the catch-up migrations are
planned to run as `postgres`.

Conclusion: the old `revoke insert,update,delete` idiom would reproduce the residual ACL
on every new table. The unapplied migration chain has been amended locally so each affected
table receives `revoke all` before its intentional authenticated `grant select`.

### Query 5 — schema privileges

```
anon:          CREATE=false, USAGE=true
authenticated: CREATE=false, USAGE=true
```

Neither API role can create objects in `public`. The residual table `TRIGGER` privilege is
therefore not directly escalatable by those roles into creating a function or trigger.

### Query 6 — routine execution

- Ordinary application RPCs are effectively executable by `authenticated`, not `anon`.
- `create_profile_for_new_user()` is `SECURITY DEFINER`, returns `trigger`, and has
  reconstructed default `PUBLIC` execution access.
- `rls_auto_enable()` is `SECURITY DEFINER`, returns `event_trigger`, and has reconstructed
  default `PUBLIC` execution access. Its source automatically enables RLS for newly-created
  tables in `public`; it is present staging drift not represented in repository history.
- Trigger and event-trigger return types are not ordinary PostgREST-callable RPCs. Their
  `PUBLIC` access is a hygiene/drift finding rather than evidence of an anonymous RPC path.
- The authenticated SECURITY DEFINER RPC surface still requires function-by-function
  authorization review before migration approval.

### Query 7 — exact legacy table ACL scope

The catalogue-backed final run found ten existing relations carrying residual `MAINTAIN`,
`REFERENCES`, `TRIGGER`, and `TRUNCATE` grants:

```
football_fixtures             anon, authenticated
football_team_form            anon, authenticated
football_teams                anon, authenticated
player_picks                  anon, authenticated
pot_fixture_test_results      anon
pot_gameweek_processes        anon
pot_gameweeks                 anon, authenticated
pot_players                   anon, authenticated
pots                          anon, authenticated
profiles                      anon, authenticated
```

It returned 18 `(relation, grantee)` rows: `anon` on all ten and `authenticated` on
eight. Every returned row has all four privileges. The initial information-schema-backed
query omitted `MAINTAIN` because this project's `information_schema.role_table_grants`
view does not surface it; the final result comes directly from the relation ACLs through
`aclexplode` and is authoritative for the corrective revocation plan.

### Query 8 — remaining exact row counts

```
admin_audit_events             0
pot_fixture_test_results       0
pot_gameweek_processes         0
pot_player_status_history      0
auth.users                     0
```

Together with Query 3, every discovered public base table and `auth.users` is empty.

## 6. Derived catch-up sequence

Migrations missing on staging, in dependency order, applied **only** where absent.
Never edit an already-applied migration and never skip a dependency.

```
1. 20260823000100_lms_integrity_phase_1.sql
2. 20260823000200_lms_phase_2a_lifecycle.sql
3. 20260823000300_lms_phase_2b_round_foundation.sql
4. 20260823000400_lms_phase_2c_team_cycles.sql
5. 20260823000500_lms_phase_2d_exceptional_fixtures.sql
6. 20260823000600_lms_phase_2e_collective_reinstatement.sql
7. 20260823000700_lms_phase_2f_buyback_lifecycle.sql
8. 20260823000800_lms_phase_2g_gw38_winners.sql
9. 20260824000100_lms_phase_2h_governed_review.sql
10. 20260824000200_lms_phase_2i_automation.sql
11. 20260824000300_lms_phase_2j_scheduler_readiness.sql

This is a draft catch-up sequence only. The unapplied migrations for 2B, 2C, 2E, 2F,
2G, 2H, 2I, and 2J have been defensively amended in the local working tree: each of the
13 affected new tables is fully revoked before any intended authenticated SELECT is
restored. The exact legacy corrective revocations, routine-drift treatment, backup/restore
demonstration, and complete plan still require review. Nothing in this list is authorized
to run remotely.
```

## 7. Divergence from expectation

Anything present on staging that the local chain does not explain — extra tables, unexpected
table grants to `anon`/`authenticated`, **any `EXECUTE` on an internal routine held by
`anon`, `authenticated` or `PUBLIC` (section 6b)**, policy `USING`/`WITH CHECK` expressions
that do not match the migration source, disabled triggers, RESTRICTIVE policies, unknown
extensions, or an existing `pg_cron` job:

```
Security and drift findings requiring review before migration approval:
- Current postgres/public default privileges grant REFERENCES/TRIGGER/TRUNCATE/MAINTAIN
  to anon and authenticated on future tables. The local unapplied chain is amended to
  revoke all before restoring intended authenticated SELECT.
- Legacy table grants expose MAINTAIN/REFERENCES/TRIGGER/TRUNCATE across the exact Query 7
  scope. RLS does not govern TRUNCATE, although the API roles cannot CREATE in public.
- Default PUBLIC EXECUTE is effective on trigger-returning create_profile_for_new_user()
  and event-trigger-returning rls_auto_enable(). These are not ordinary PostgREST RPCs.
- rls_auto_enable() is staging drift not represented in repository history; its observed
  source enables RLS automatically for newly-created public tables.
- The authenticated RPC grants must be compared function-by-function with the intended
  application surface; their presence is not automatically a defect because many are
  internally admin-gated SECURITY DEFINER functions.

No disabled trigger, RESTRICTIVE policy, unknown application table, Phase 1–2J
sentinel, pg_cron installation, application data, or auth user was found. Migration
history agrees with sentinels.
```

## 8. Outcome

- ☐ Discovery complete, no material divergence — proceed to migration-plan review
- ☑ Discovery complete, divergence found — stop and report (see section 7)
- ☐ Discovery blocked — record why

The migration plan may be prepared and reviewed while the gate is `NOT READY`. No migration,
function deployment, secret configuration, or cron change may begin until the gate is
explicitly `READY` and the exact plan is separately approved.
