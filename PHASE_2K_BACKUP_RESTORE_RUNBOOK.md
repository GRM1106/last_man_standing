# Phase 2K — Manual Logical Backup and Restore Runbook

Target: staging `evhiixndiuwwodsouyhf` (`last-man-standing-staging`) only.

**This is a prepared runbook, not authorization.** Nothing here has been executed. No remote
connection was made while preparing it. Do not run any step until the exact runbook is
separately approved. The BACKUP / RESTORE OPERATOR GATE remains `NOT READY`.

Workflow: **staging logical dump → local disposable restore → verification → retention.**

Backup disposal is **not** part of this workflow. It is a separate, later, operator-approved
action (see "Backup retention and disposal").

## Tooling actually available

Verified on this machine, not assumed:

| Tool | Status | Source |
|---|---|---|
| `psql`, `pg_dump`, `pg_restore` | **not installed locally** | `command -v` |
| `supabase` CLI | **not installed globally**; used via `npx` | `command -v`, `scripts/test-db-phase1.sh` |
| Supabase CLI version | `2.116.0` — pinned everywhere below | `npx supabase --version` |
| `pg_dump` / `psql` | `17.6`, inside Docker | `docker run --rm public.ecr.aws/supabase/postgres:17.6.1.165 pg_dump --version` |
| Docker daemon | required, must be running | `docker info` |

All Postgres binaries run **inside containers**, matching the existing
`scripts/test-db-phase1.sh`, which drives everything through `npx supabase` and
`docker exec … psql`.

Every CLI invocation is pinned to `npx --yes supabase@2.116.0`. `@latest` is never used: an
unpinned CLI could change flag behaviour between the preparation of this runbook and its
execution, invalidating the verification below.

Every flag used was confirmed from the tool's own `--help` output or from
`supabase db dump --dry-run`. No flag is carried over from memory or documentation.

## Recovery envelope — what this backup can and cannot recover

Discovered by reading the generated `pg_dump` script via `--dry-run`. These define the
recovery envelope and must be accepted explicitly.

1. **This is a logical backup, not point-in-time recovery.** RPO is the dump completion
   instant; anything written after it is unrecoverable from this artifact.
2. **The `auth` and `storage` schemas are platform-managed and excluded from the schema dump.**
   The restore target must therefore be a Supabase stack, not a bare Postgres instance.
3. **`auth` row data appears to be included** — the data-only exclude list names only
   `auth.schema_migrations` — but this is **subject to confirmation from the generated remote
   dry-run in Step 2**. It was verified against a `--local` dry-run, not the remote one.
4. **The staging application's `supabase_migrations.schema_migrations` ledger is excluded from
   both the schema and the data dump.** The recorded 24-row staging ledger is not captured and
   is not restored. This does **not** mean the restored copy has an empty migration table: a
   fresh local Supabase stack may contain its own platform migration records created by its
   startup process. Those local platform records must never be mistaken for the staging
   application ledger. See "Companion recovery artifact" — handled separately, not ignored.
5. **Restore is demonstrated locally, not in place on staging.** It proves the dump is complete
   and applicable; it does not prove an in-place staging restore.
6. **Staging currently holds zero rows** in all 12 public base tables and `auth.users`, so this
   exercises the mechanism rather than realistic data volume or restore duration.
7. **Role dumps use `--no-role-passwords`.** The generated `pg_dumpall --roles-only` plan
   includes `--no-role-passwords`, so role passwords are deliberately **not** captured and
   will **not** be restored. Roles themselves are recovered; their passwords are not. Anything
   depending on a role password must be re-established separately after a restore.
8. **The retained `.sql` dumps are plaintext at rest.** `umask 077`, `700` directory and `600`
   file permissions restrict which accounts can read them, but they do **not** encrypt the
   contents. Anything in the dump is readable by anyone who obtains the file. Protection
   therefore depends on the machine's full-disk encryption and its physical and account
   security, not on this runbook. Accept that explicitly, and reassess it before this
   procedure is ever used against a project holding real data.

## Credential handling and persistence

- **Never** use `--password` or `--db-url`. Both place the secret in `argv`, visible to any
  `ps` on the machine; `--db-url` additionally requires percent-encoding the secret.
- The database password is read **silently** into `SUPABASE_DB_PASSWORD` via `read -rs`,
  exported only for the dump commands, then `unset`. This CLI build references that variable
  (confirmed by inspecting the binary's env-var strings).
- **Environment variables avoid shell history and `argv` exposure, but do not make a credential
  invisible to every same-user process.** A process running as the same user may still be able
  to read the environment of its own or related processes. This is a reduction in exposure, not
  elimination.
- **Interactive `supabase login` creates persistent local authentication state outside this
  repository**, under the CLI's own configuration directory. It survives after this runbook
  finishes and remains until explicitly revoked or logged out. Treat it as a live credential.
- Never print, persist, commit, log, or paste either credential.

## Retention controls

Applied from the moment the dump exists until operator-approved disposal.

| Control | Requirement |
|---|---|
| Directory permissions | `700` |
| Dump file permissions | `600` |
| Location | exact resolved path recorded in the evidence document |
| Inventory | file names, sizes, SHA-256 checksums, UTC creation time recorded |
| Contents | never committed, pasted, or logged — only metadata is recorded |
| Disposal | time and target explicitly approved by the operator beforehand |

## Step 0 — Preconditions and backup destination

```bash
docker info >/dev/null && echo "docker: up"

git rev-parse --abbrev-ref HEAD
git status --porcelain
```

The backup lives under a **durable root**, not a temporary directory. It must survive staging
migration, staging validation, and the agreed rollback window, so a location subject to reboot
purging is unsuitable.

Create the root at `700`, create the unique directory beneath it with `mktemp -d`, then
**record and validate the resolved path before writing anything into it**:

```bash
BACKUP_ROOT="/Users/grantmiller/Documents/LMS-Backups"
mkdir -p "$BACKUP_ROOT" && chmod 700 "$BACKUP_ROOT"
BACKUP_ROOT="$(cd "$BACKUP_ROOT" && pwd -P)"     # resolve to an absolute real path

BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/lms-staging-backup.XXXXXX")"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd -P)"       # resolve symlinks to a real path
chmod 700 "$BACKUP_DIR"

# Accept ONLY a six-character lms-staging-backup.XXXXXX directory sitting DIRECTLY
# beneath the root. The parent is compared exactly, and the pattern is matched against
# the basename only — in a shell `case`, `?` also matches `/`, so testing the full path
# against a single pattern would wrongly accept a nested path such as
# ".../lms-staging-backup.a/b/cd". Matching the basename cannot contain a separator.
[ "$(dirname "$BACKUP_DIR")" = "$BACKUP_ROOT" ] || {
  echo "REFUSING: not directly beneath $BACKUP_ROOT: $BACKUP_DIR"; return 1 2>/dev/null || exit 1; }
case "$(basename "$BACKUP_DIR")" in
  lms-staging-backup.??????) echo "backup dir OK: $BACKUP_DIR" ;;
  *) echo "REFUSING: unexpected backup path: $BACKUP_DIR"; return 1 2>/dev/null || exit 1 ;;
esac
```

Record the resolved `$BACKUP_DIR` value in the evidence document now. Every later step, and
any eventual disposal, validates against this exact recorded path.

Confirm the target project ref from the Supabase dashboard URL. Do not rely on
`supabase/.temp/linked-project.json`; confirm it independently each time.

## Step 1 — Authenticate

Interactive; the token is never passed as an argument. Note this creates persistent local
authentication state outside the repository, as disclosed above.

```bash
npx --yes supabase@2.116.0 login
```

## Step 2 — Print the exact dump scripts without executing them

> ## ⚠ DRY-RUN OUTPUT IS CREDENTIAL-BEARING
>
> In CLI `2.116.0`, `db dump --dry-run` emits a runnable bash script that **embeds an
> `export PGPASSWORD=` assignment**, together with `PGHOST`, `PGUSER`, `PGPORT` and
> `PGDATABASE`. This happens even though no password is supplied or requested on the command
> line. `--dry-run` is therefore **not** a safe-to-share inspection step.
>
> Raw dry-run output must **never** be pasted into chat or a ticket, committed, logged as
> evidence, written to a file, or retained in scrollback. Only redacted structural findings
> are recorded. Treat the embedded `PGPASSWORD` as potentially sensitive; do not assume it is
> ephemeral, and do not test that assumption by inspecting it.

`--dry-run` prints the `pg_dump` script and performs no dump. Running it against the real
project ref both shows the exact script and confirms authenticated access to that project —
no separate access check is needed, and project API keys must not be retrieved.

Run each command through the redaction wrapper below. It captures output into a shell variable
(never a file), redacts every connection export **before** anything reaches the terminal, and
preserves the CLI's real exit status so a failure cannot be laundered into apparent success.

```bash
redact_conn() {
  sed -E 's/^([[:space:]]*export[[:space:]]+PG(PASSWORD|HOST|USER|DATABASE|PORT)=).*/\1"[REDACTED]"/'
}

dry_run() {            # usage: dry_run <extra flags...>
  local raw status
  raw="$(npx --yes supabase@2.116.0 db dump --dry-run \
           --project-ref evhiixndiuwwodsouyhf "$@" 2>&1)"
  status=$?                       # captured BEFORE any pipeline; this is the CLI's own status
  printf '%s\n' "$raw" | redact_conn
  unset raw                       # drop the unredacted copy from the shell
  echo "exit status: $status"
  return "$status"
}

dry_run --role-only
dry_run
dry_run --data-only --use-copy
```

Assigning to `raw` and reading `$?` on the next line is what preserves the true exit status.
Do **not** collapse this into `npx … | sed …`: a pipeline reports the exit status of `sed`,
which is almost always `0`, so a failed CLI invocation would appear to have succeeded. The
unredacted text exists only in a shell variable and is never written to disk.

Read all three before proceeding. Confirm:

- the `--exclude-schema` lists match the recovery envelope above;
- `supabase_migrations` is excluded in both schema and data modes (envelope item 4);
- whether `auth` is excluded in the **data** dump (envelope item 3 — this is the open question).

**Stop and report if any printed script differs from what this runbook describes.**

## Step 3 — Confirm server version compatibility

`pg_dump` must be at least the server version; the container provides 17.6. From the
**confirmed staging SQL Editor**, read only:

```sql
select version();
```

**Stop if the staging server major version is greater than 17.**

## Step 4 — Take the dump

> ## ⚠ STEP 4 MUST RUN UNDER BASH
>
> The password prompt uses `read -rs -p`, which is **Bash** syntax. In `zsh` — the operator's
> default shell — `read -p` does not mean "prompt": it reads from the coprocess. Pasting this
> block into `zsh` does not merely warn, it misbehaves, and the silent prompt will not work as
> intended. Do not adapt the block to zsh syntax; run it under Bash as written.

From the default `zsh` prompt, enter an interactive Bash shell first. This preserves the TTY,
which the silent password prompt requires — `bash -c '…'` and pipelines must not be used here.

```bash
bash                       # enter interactive Bash
echo "${BASH_VERSION:?not running under bash — stop}"   # must print a version
```

> **Shell variables do not survive a new terminal session.** `BACKUP_DIR` and `BACKUP_ROOT`
> were set in Step 0. If that was a different terminal, tab, or shell — and entering `bash`
> above starts a new shell — those variables are **gone**. They are therefore re-established
> from the recorded value below and revalidated from scratch, rather than assumed to still be
> set. Never proceed on an unset or inherited-by-luck `BACKUP_DIR`.

Re-establish and revalidate the recorded path **before** any password is entered or any file is
written:

```bash
BACKUP_ROOT="/Users/grantmiller/Documents/LMS-Backups"
RECORDED_BACKUP_DIR="/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.r1Y5AR"
BACKUP_DIR="/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.r1Y5AR"

# Must already exist; this step never creates it.
[ -d "$BACKUP_DIR" ] || { echo "REFUSING: not a directory: $BACKUP_DIR"; exit 1; }

# Resolve to a real absolute path, then re-run the Step 0 guards.
BACKUP_ROOT="$(cd "$BACKUP_ROOT" && pwd -P)"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd -P)"

[ "$(dirname "$BACKUP_DIR")" = "$BACKUP_ROOT" ] || {
  echo "REFUSING: not directly beneath $BACKUP_ROOT: $BACKUP_DIR"; exit 1; }
case "$(basename "$BACKUP_DIR")" in
  lms-staging-backup.??????) ;;
  *) echo "REFUSING: unexpected basename: $BACKUP_DIR"; exit 1 ;;
esac
[ "$BACKUP_DIR" = "$RECORDED_BACKUP_DIR" ] || {
  echo "REFUSING: does not match recorded path"; exit 1; }

# Fail closed unless the directory is completely empty.
if [ -n "$(ls -A "$BACKUP_DIR")" ]; then
  echo "REFUSING: $BACKUP_DIR is not empty — a previous attempt may exist."
  echo "  Do not overwrite it. Investigate, then start a fresh mktemp -d directory."
  ls -la "$BACKUP_DIR"; exit 1
fi

echo "validated, empty, ready: $BACKUP_DIR"
```

Every guard runs **before** the password prompt, so an operator never types a credential into a
run that was going to be refused anyway.

The password prompt and all three dumps then run inside a **subshell** with `set -e`, so the
first failure stops the sequence and no later dump runs. RPO is the **completion** timestamp
and is calculated only when all three dumps have succeeded.

`BACKUP_DIR` is visible inside the subshell without being exported: a `( … )` subshell inherits
the parent shell's variables, exported or not. Nothing therefore needs to be passed as a
command argument or written to a file, and no credential is placed in either.

```bash
(
  set -e
  umask 077          # every dump file, complete or partial, is created owner-only
                     # from the outset — before any dump command can write

  BACKUP_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; BACKUP_START_EPOCH="$(date +%s)"
  echo "backup start: $BACKUP_START_UTC"

  read -rs -p "staging db password: " SUPABASE_DB_PASSWORD; echo
  trap 'unset SUPABASE_DB_PASSWORD' EXIT
  export SUPABASE_DB_PASSWORD

  npx --yes supabase@2.116.0 db dump --project-ref evhiixndiuwwodsouyhf \
    --role-only -f "$BACKUP_DIR/roles.sql"

  npx --yes supabase@2.116.0 db dump --project-ref evhiixndiuwwodsouyhf \
    -f "$BACKUP_DIR/schema.sql"

  npx --yes supabase@2.116.0 db dump --project-ref evhiixndiuwwodsouyhf \
    --data-only --use-copy -f "$BACKUP_DIR/data.sql"

  # Reached only when all three dumps succeeded: set -e aborts the subshell on the first
  # failure, so a partial run never reaches this point and never produces an RPO.
  BACKUP_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; BACKUP_END_EPOCH="$(date +%s)"
  echo "backup end:      $BACKUP_END_UTC"
  echo "backup duration: $((BACKUP_END_EPOCH - BACKUP_START_EPOCH))s"
  echo "RPO =            $BACKUP_END_UTC"
)
BACKUP_STATUS=$?
```

Capture the status as its own statement. Do **not** wrap the subshell in `if (...)`, `&& …` or
`|| …`: placing it in a condition context suspends `errexit`, and the dumps would continue
after a failure — the exact behaviour this step exists to prevent.

Then branch on the result:

```bash
if [ "$BACKUP_STATUS" -ne 0 ]; then
  echo "BACKUP FAILED (exit $BACKUP_STATUS)."
  echo "  $BACKUP_DIR contains an INCOMPLETE, INVALID attempt. Do not use it."
  echo "  No RPO and no backup duration were calculated."
  echo "  Partial files are deliberately left in place; do not delete them here."
  ls -la "$BACKUP_DIR"
else
  chmod 600 "$BACKUP_DIR"/*.sql   # explicit enforcement; umask 077 already applied at creation
  ls -la "$BACKUP_DIR"
  shasum -a 256 "$BACKUP_DIR"/*.sql
fi
```

Omitting both `--data-only` and `--role-only` produces the schema dump; there is no
`--schema-only` flag on this command.

**On failure:** stop. Do not re-run individual dump commands to "fill in" the missing files —
a directory assembled from separate attempts has no single consistent RPO. Report the failure
and the exact error. The partial files are retained for inspection, not reuse, and are removed
only through the guarded, operator-approved disposal procedure. Start a fresh backup in a new
`mktemp -d` directory.

**Permissions and validity are separate concerns.** `umask 077` makes every dump file — whole
or partial — owner-only from the moment it is created, so a failed attempt is protected just as
well as a successful one. The `chmod 600` in the success branch re-asserts that explicitly
rather than establishing it. Permissions protect **confidentiality**; they say nothing about
whether a backup is usable. **Validity** is established only by successful completion of all
three dumps, the recorded start and end timestamps, and the checksums. An incomplete attempt
therefore remains invalid even though its files are correctly permission-protected, and must
never be treated as a backup on the strength of its permissions.

**On success**, record into the evidence document: resolved path, file names, sizes, SHA-256
checksums, `BACKUP_START_UTC`, `BACKUP_END_UTC`, duration, and RPO.

### Why the password is scoped this way

- The **subshell is the primary isolation**: `SUPABASE_DB_PASSWORD` is read and exported only
  inside it, so the interactive parent shell never holds the variable at all, whatever happens.
- The `EXIT` trap, installed immediately after the read, clears it within that scope on *every*
  exit path — normal completion, a failed dump under `set -e`, or an interrupt.
- `read -rs` is silent, and the value is never echoed, logged, or written to a file.
- The exported value is still inherited by the `npx` child processes, which is how the CLI
  consumes it. As stated in the credential section, that reduces exposure but does not hide it
  from every same-user process.

## Step 5 — Companion recovery artifact: the migration ledger

Because the staging application's `supabase_migrations.schema_migrations` ledger is excluded
from the dump (envelope item 4), it is a **required companion artifact**. The backup is not
complete without it.

The restore target is **not** expected to have an empty migration table. A fresh local Supabase
stack may create its own platform migration records during startup. Whatever appears there is
local platform state, not the staging application ledger, and the two must be assessed
separately and never conflated.

- Retain the previously recorded **24-row staging migration history** from
  `PHASE_2K_DISCOVERY_EVIDENCE.md`, section 4.
- Record the **source commit** of that evidence document and its **SHA-256 checksum**:

```bash
git log -1 --format=%H -- PHASE_2K_DISCOVERY_EVIDENCE.md
shasum -a 256 PHASE_2K_DISCOVERY_EVIDENCE.md
```

- State clearly in the evidence document that this ledger is **companion reconstruction
  evidence only.** It does not recreate database state, and restoring the dump does not
  restore it.
- **Any unexplained disagreement between the companion ledger, the restored schema sentinels,
  and the expected source commit stops the process** and is reported. Do not assume any one
  source is authoritative, and do not reconcile a mismatch by preferring whichever source is
  more convenient.

## Step 6 — Start a clean local disposable stack

The restore target must be a Supabase stack (envelope item 2). This is the same stack the
existing database suite uses; its container is `supabase_db_last_man_standing`.

```bash
RESTORE_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; RESTORE_START_EPOCH="$(date +%s)"
echo "restore window start: $RESTORE_START_UTC"

npx --yes supabase@2.116.0 stop --no-backup || true
npx --yes supabase@2.116.0 start -x studio,imgproxy,inbucket,storage-api,edge-runtime,logflare,vector,supavisor,realtime
docker ps --format '{{.Names}}' | grep supabase_db_last_man_standing
```

`-x` / `--exclude` is a valid `supabase start` flag (confirmed from its `--help`).

## Step 7 — Restore into the local stack, in order

Each file runs separately so a failure identifies which stage broke. `ON_ERROR_STOP=1` matches
the convention already used throughout `scripts/test-db-phase1.sh`.

```bash
C=supabase_db_last_man_standing

docker exec -i "$C" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres < "$BACKUP_DIR/roles.sql"
docker exec -i "$C" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres < "$BACKUP_DIR/schema.sql"
docker exec -i "$C" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres < "$BACKUP_DIR/data.sql"
```

**Stop and report the first exact SQL error if any file fails.** Do not skip a file, do not
edit the dump to make it apply, and do not continue to the next stage.

## Step 8 — Verify the restore reproduces staging

This converts a dump into a *demonstrated* restore path.

The committed discovery file contains three independent sections, each its own read-only
transaction, and its documented execution model is that they are **run separately**. Piping the
whole file through one command would abort at the expected migration-ledger difference and
silently skip the remaining sections. Split it first:

```bash
SECTIONS="$BACKUP_DIR/sections"; mkdir -p "$SECTIONS"
awk -v out="$SECTIONS" '/^begin;$/{n++} n>0{print >> (out "/section" n ".sql")}' \
  supabase/discovery/phase_2k_staging_discovery.sql
ls -1 "$SECTIONS"    # expect section1.sql section2.sql section3.sql
```

Run each separately, recording each outcome independently:

```bash
docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$SECTIONS/section1.sql"
docker exec -i "$C" psql -U postgres -d postgres < "$SECTIONS/section2.sql"   # expected to fail
docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$SECTIONS/section3.sql"
```

Section 2 is run **without** `ON_ERROR_STOP` because its failure is expected and must not
abort the sequence. Record its exact output or error text verbatim.

Expected, from the recorded staging evidence:

- P1/P2 baseline sentinels present; Phase 1 and Phases 2A–2J sentinels **absent**.
- 12 public base tables, RLS enabled on all 12.
- All 12 base tables and `auth.users` contain zero rows.
- `pg_cron` not installed.

Expected divergences that are **not** restore failures:

- Section 2 does **not** reproduce the staging application ledger — it is excluded from the
  dump (envelope item 4). It may return nothing, error, or return the local stack's own
  platform migration records. Any of those is expected. Records it returns are local platform
  state and are **not** the staging application ledger.
- Extension versions and platform-managed roles may differ from staging.

Compare application migration evidence **separately** from local platform migration records.
Application migration state is assessed from the Step 5 companion ledger together with the
restored schema sentinels in section 1 — never from whatever section 2 happens to return on
the local stack.

**Any divergence beyond these two stops the process and is reported.** Do not reconcile a
mismatch by assuming the dump is fine.

```bash
RESTORE_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; RESTORE_END_EPOCH="$(date +%s)"
echo "restore window end: $RESTORE_END_UTC"
echo "RTO (stack start + restore + verification): $((RESTORE_END_EPOCH - RESTORE_START_EPOCH))s"
```

RTO is measured across Steps 6–8 together: local-stack startup **plus** restore **plus**
verification. Record start, end, and the calculated duration.

## Step 9 — Local database teardown only

This tears down the **local stack**. It does **not** touch the backup artifact.

```bash
npx --yes supabase@2.116.0 stop --no-backup
```

The dump files in `$BACKUP_DIR` are deliberately left in place. Do not delete them here.

## Backup retention and disposal

The verified dump must remain available through **all** of:

- staging migration;
- staging validation;
- the agreed rollback window;
- explicit operator approval for disposal.

Disposal is a separate operator-approved action, not part of teardown. When that approval is
given, the deletion must **fail closed** unless the resolved path matches the expected pattern
and the recorded path:

```bash
# Only after explicit operator approval of BOTH the disposal time and the target path.
BACKUP_ROOT="/Users/grantmiller/Documents/LMS-Backups"

# Same three-part guard as Step 0: exact parent, basename-only pattern, recorded-path match.
[ "$(dirname "$BACKUP_DIR")" = "$BACKUP_ROOT" ] || {
  echo "REFUSING: not directly beneath $BACKUP_ROOT: $BACKUP_DIR"; return 1 2>/dev/null || exit 1; }
case "$(basename "$BACKUP_DIR")" in
  lms-staging-backup.??????) ;;
  *) echo "REFUSING: unexpected disposal target: $BACKUP_DIR"; return 1 2>/dev/null || exit 1 ;;
esac
[ "$BACKUP_DIR" = "$RECORDED_BACKUP_DIR" ] || { echo "REFUSING: path does not match recorded value"; return 1 2>/dev/null || exit 1; }

rm -rf -- "$BACKUP_DIR"
```

The root itself is never removed — only the individual `lms-staging-backup.XXXXXX` directory
approved for disposal.

**On deletion guarantees:** removing these files is *best-effort unlinking only*. On APFS and
SSD-backed storage, physical overwrite cannot be guaranteed — copy-on-write, wear levelling,
over-provisioned blocks, and filesystem snapshots may all retain recoverable copies after
`rm`. No command in this runbook provides secure erasure, and none should be described as
doing so. If the dump content ever warrants stronger guarantees, that requires full-volume
encryption or physical media destruction, decided separately.

## Evidence to record

Into `PHASE_2K_DISCOVERY_EVIDENCE.md` section 2, against the gate rows:

| Gate row | Evidence this runbook produces |
|---|---|
| Backup mechanism identified | Supabase CLI `2.116.0` logical dump, three files, `pg_dump` 17.6 in container |
| Backup actually taken | resolved path, file names, sizes, SHA-256 checksums, UTC start/end, duration |
| Restore **demonstrated** | Step 7 applied cleanly; Step 8 sections 1 and 3 matched recorded staging state |
| Recovery point / recovery time | RPO = dump completion timestamp; RTO = measured Steps 6–8 duration |
| Residual risk accepted | operator sign-off naming every recovery-envelope item above |

Also record: the migration-ledger companion artifact, its source commit and document checksum,
and the operator-approved disposal time and target.

## Prohibited throughout

No production contact. No migration application. No Edge Function deployment. No secret
configuration. No cron creation. No push. Restore is only ever into the local disposable
stack. The gate stays `NOT READY` until every row above is satisfied and signed off.
