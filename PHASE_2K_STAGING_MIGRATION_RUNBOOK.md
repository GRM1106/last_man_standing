# Phase 2K staging migration runbook

Status: **DESIGNED — NOT APPROVED FOR EXECUTION**

Target: staging project `evhiixndiuwwodsouyhf` only.

Production project `enzdvsppduyqtpdeseyh` is out of scope. This runbook does not authorize an
Edge Function deployment, secrets, cron, automation flags, UI deployment, a Git push, migration
history repair, or restoration over either remote database.

## 1. Proven basis

- Backup/restore gate: `READY`, empty staging only.
- Local dress rehearsal: PASS from a fresh stack at commit `d0823aa`.
- Required local recovery order: restore, then the `_r2` ACL-normalization artifact, then the
  migrations. The ACL artifact is **local restore machinery only** and must never be run on
  staging.
- Remote staging already is the source ACL baseline. Its remote operation is only the ordered
  migration push described below.

The final approved execution commit must be recorded here before use:

```text
APPROVED_COMMIT=<replace only after this runbook and all migrations are committed and reviewed>
```

Any placeholder, dirty tree, different commit, or unreviewed change stops the run.

## 2. Exact migration payload

The dry run and interactive apply prompt must list exactly these 14 versions, in this order, and
nothing else:

```text
20260823000100_lms_integrity_phase_1.sql
20260823000200_lms_phase_2a_lifecycle.sql
20260823000300_lms_phase_2b_round_foundation.sql
20260823000400_lms_phase_2c_team_cycles.sql
20260823000500_lms_phase_2d_exceptional_fixtures.sql
20260823000600_lms_phase_2e_collective_reinstatement.sql
20260823000700_lms_phase_2f_buyback_lifecycle.sql
20260823000800_lms_phase_2g_gw38_winners.sql
20260824000100_lms_phase_2h_governed_review.sql
20260824000200_lms_phase_2i_automation.sql
20260824000300_lms_phase_2j_scheduler_readiness.sql
20260824000400_lms_phase_2k_legacy_acl_hardening.sql
20260824000500_lms_phase_2k_remove_orphan_rls_auto_enable.sql
20260824000600_lms_phase_2k_ensure_profile_signup_trigger.sql
```

Never use `--include-all`, `--include-roles`, `--include-seed`, `migration repair`, `--db-url`,
`--password`, or a manually assembled SQL stream to make a mismatch disappear. The pinned CLI's
`--skip-vault` flag is mandatory so a database migration cannot update unrelated Vault secrets.

## 3. Stop rules applying to every stage

Stop immediately and record the exact result if any of these occurs:

- the browser URL or CLI result does not identify staging ref `evhiixndiuwwodsouyhf`;
- production ref `enzdvsppduyqtpdeseyh` appears as the selected or linked target;
- the working tree is dirty or `HEAD` differs from `APPROVED_COMMIT`;
- staging is no longer empty;
- the pre-application sentinels or 24-row migration ledger differ from discovery;
- the fresh backup fails, is incomplete, or lacks checksums;
- `migration list` reports disagreement between local and remote history;
- `db push --dry-run` fails or lists anything other than the 14 files above;
- the CLI unexpectedly requests a manually supplied database password;
- any migration reports an error;
- any post-application sentinel, RLS, ACL, trigger, ledger, or row-count assertion fails.

Do not skip, edit, repair, retry in place, mark a failed migration as applied, or automatically
restore. A partial remote application requires a separately approved diagnosis and recovery
decision. The fresh backup is evidence and a recovery option, not permission to overwrite.

## 4. Checkpoint A — immutable repository identity

Run under Bash from the repository root:

```bash
echo "${BASH_VERSION:?not running under bash — stop}"
APPROVED_COMMIT="<paste the reviewed full commit hash>"

[ -z "$(git status --short)" ] || { echo "REFUSING: working tree is not clean"; exit 1; }
[ "$(git rev-parse HEAD)" = "$APPROVED_COMMIT" ] || {
  echo "REFUSING: HEAD does not match the approved commit"; exit 1;
}

test "$(find supabase/migrations -maxdepth 1 -type f -name '202608*.sql' | wc -l | tr -d ' ')" = 14 || {
  echo "REFUSING: expected exactly 14 Phase 1/2 migration files"; exit 1;
}
git diff --check
```

Record `APPROVED_COMMIT` and SHA-256 for all 14 migration files in the execution evidence before
any remote command.

## 5. Checkpoint B — read-only target and state confirmation

This checkpoint requires a separate operator instruction before it is run because it contacts
staging. It performs no database mutation.

1. Confirm the SQL Editor URL contains exactly
   `/dashboard/project/evhiixndiuwwodsouyhf/`.
2. Run the three blocks from
   `supabase/discovery/phase_2k_staging_discovery.sql` **separately**.
3. Require the pre-application state:
   - P1/P2 baseline present;
   - Phase 1 and 2A–2J absent;
   - migration ledger exactly the recorded 24 versions, ending at `20260822002400`;
   - every counted application table and `auth.users` still empty;
   - no unexplained inventory, policy, trigger, extension, or grant drift.
4. Run the authenticated CLI check without printing project metadata:

```bash
raw="$(npx --yes supabase@2.116.0 projects list --output json)" || exit 1
node -e '
const parsed=JSON.parse(process.argv[1]);
const rows=Array.isArray(parsed) ? parsed : (parsed.projects ?? parsed.data ?? []);
if (!Array.isArray(rows)) process.exit(1);
const refs=rows.map(x=>x.id ?? x.ref ?? x.project_ref).filter(Boolean);
if (!refs.includes("evhiixndiuwwodsouyhf")) process.exit(1);
console.log("authenticated staging project present: YES");
' "$raw"
unset raw
```

Do not paste raw project metadata into evidence or chat.

## 6. Checkpoint C — fresh pre-application backup

Create a new `mktemp -d` destination beneath
`/Users/grantmiller/Documents/LMS-Backups`. Never reuse or modify any prior directory. Execute
Steps 0–5 of `PHASE_2K_BACKUP_RESTORE_RUNBOOK.md` against staging using CLI `2.116.0` and its
automatic temporary-login path.

Required result before proceeding:

- `roles.sql`, `schema.sql`, and `data.sql` all exist, are owner-only and non-ambiguous;
- all three commands exited successfully;
- completion UTC, duration, RPO, sizes and SHA-256 values are recorded;
- the 24-row companion ledger and evidence provenance are recorded;
- `SUPABASE_DB_PASSWORD` was absent and no credential value or connection URI was retained.

A fresh backup is mandatory even though the earlier valid backup remains retained.

## 7. Checkpoint D — private migration-runner preflight

This checkpoint contacts staging read-only. Keep its output in a new owner-only directory outside
the repository.

```bash
unset SUPABASE_DB_PASSWORD DATABASE_URL PGHOST PGSERVICE

PREFLIGHT_DIR="$(mktemp -d /private/tmp/p2k-staging-preflight.XXXXXX)"
chmod 700 "$PREFLIGHT_DIR"

npx --yes supabase@2.116.0 migration list \
  --project-ref evhiixndiuwwodsouyhf \
  > "$PREFLIGHT_DIR/migration-list.txt" \
  2> "$PREFLIGHT_DIR/migration-list.err"

npx --yes supabase@2.116.0 db push \
  --dry-run \
  --skip-vault \
  --project-ref evhiixndiuwwodsouyhf \
  > "$PREFLIGHT_DIR/db-push-dry-run.txt" \
  2> "$PREFLIGHT_DIR/db-push-dry-run.err"

chmod 600 "$PREFLIGHT_DIR"/*
```

The operator must review both outputs. The migration list must reconcile the 24 remote applied
versions with the 14 local pending versions. The dry run must name exactly the 14-file payload in
section 2. A complaint that remote historical versions are absent locally is a stop, not an
invitation to use `migration repair` or `--include-all`.

Record only sanitized determinations and hashes of the private outputs. Do not commit raw CLI
output if it contains connection or project metadata.

## 8. Checkpoint E — explicit mutation approval

Everything above is preflight. Before the next command, stop and obtain a new explicit operator
statement approving application of the exact dry-run payload to staging ref
`evhiixndiuwwodsouyhf` at the recorded `APPROVED_COMMIT` and fresh backup RPO.

Without that new statement, do not proceed.

## 9. Single remote mutation

Run interactively under Bash. Do not add `--yes`; the CLI prompt is the last human checkpoint.

```bash
unset SUPABASE_DB_PASSWORD DATABASE_URL PGHOST PGSERVICE

npx --yes supabase@2.116.0 db push \
  --skip-vault \
  --project-ref evhiixndiuwwodsouyhf
```

At the prompt, confirm only if it repeats exactly the 14 files in section 2. Record start UTC,
end UTC, exit status and sanitized per-migration outcome. The first error ends the run.

This command does not deploy functions, configure secrets, create cron jobs, enable automation,
or deploy the UI. Those remain separately prohibited.

## 10. Checkpoint F — post-application read-only verification

Do **not** run anything from `supabase/verification/` remotely; those suites intentionally mutate
fixtures inside transactions and are local-only.

Run these read-only checks instead:

1. `migration list --project-ref evhiixndiuwwodsouyhf` must show the original 24 plus all 14 new
   versions, with no local/remote disagreement.
2. Run Query 1, Query 2 and Query 3 from `phase_2k_staging_discovery.sql` separately:
   - every Phase 1–2J sentinel is present;
   - all 28 public base tables have RLS enabled;
   - no disabled application trigger or unexpected policy/routine appears;
   - the ledger contains exactly 38 rows.
3. Use Query 3 to confirm exact row counts remain zero for `auth.users` and all application tables
   it covers. Independently confirm that all 28 public base tables exist; new tables must not
   acquire rows merely by applying the empty-staging migration chain.
4. Run `supabase/discovery/phase_2k_acl_capture.sql` unchanged, export the complete CSV outside
   the repository with directory `700` and file `600`, and record its SHA-256.
5. Require all of the following catalogue assertions:

```sql
begin;
set transaction read only;

select count(*) as rls_disabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind in('r','p') and not c.relrowsecurity;
-- expect 0

select count(*) as unsafe_client_table_edges
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
cross join lateral aclexplode(coalesce(c.relacl,'{}'::aclitem[])) acl
left join pg_roles role on role.oid=acl.grantee
where n.nspname='public' and c.relkind in('r','p')
  and coalesce(role.rolname,'PUBLIC') in('PUBLIC','anon','authenticated')
  and acl.privilege_type<>'SELECT';
-- expect 0

select count(*) as unsafe_postgres_future_table_edges
from pg_default_acl defaults
cross join lateral aclexplode(defaults.defaclacl) acl
join pg_roles owner_role on owner_role.oid=defaults.defaclrole
join pg_roles grantee_role on grantee_role.oid=acl.grantee
join pg_namespace namespace on namespace.oid=defaults.defaclnamespace
where owner_role.rolname='postgres' and namespace.nspname='public'
  and defaults.defaclobjtype='r'
  and grantee_role.rolname in('anon','authenticated')
  and acl.privilege_type in('MAINTAIN','REFERENCES','TRIGGER','TRUNCATE');
-- expect 0

select to_regprocedure('public.rls_auto_enable()') is null as orphan_removed;
-- expect true

select count(*) as signup_trigger_ok
from pg_trigger
where tgrelid='auth.users'::regclass
  and tgname='create_profile_after_signup'
  and not tgisinternal and tgenabled='O'
  and tgfoid='public.create_profile_for_new_user()'::regprocedure;
-- expect 1

select count(*) as pg_cron_installed from pg_extension where extname='pg_cron';
-- expect 0; scheduler deployment is a separate future decision

commit;
```

Any failed postcondition stops the release and opens a separately approved diagnosis. Do not
deploy downstream components to compensate for a database mismatch.

## 11. Completion boundary

The staging database migration is complete only when:

- the push exited `0`;
- the 38-row ledger and all sentinels agree;
- all tables remain empty and RLS-enabled;
- the ACL/default/trigger/orphan checks pass;
- the fresh backup remains intact; and
- sanitized evidence is committed separately.

Even then, this run authorizes **no** production migration, Edge Function, secret, cron,
automation enablement, UI deployment, or Git push. Each requires its own reviewed plan and
explicit approval.
