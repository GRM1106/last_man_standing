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
| BACKUP / RESTORE OPERATOR GATE | **`READY`** — scope-limited to empty staging; ACL recovery demonstrated in 2X and the final two limitations accepted in 2Y |

Update only when every row below is satisfied. Any unchecked row keeps the gate `NOT READY`.

> ## ✅ `READY` — EMPTY STAGING ONLY
>
> The gate was moved to `READY` on 2026-08-27 and is **withdrawn** as of 2026-08-28. The
> 148-vs-206 discrepancy has been **resolved and its cause is understood**: the entire 58-row
> gap is in the ACL sections. Schema and data restored correctly; **privileges did not**.
>
> Section 2X supersedes the ACL outcome: the generated recovery was applied only to the confirmed
> disposable local restore, committed atomically, and independently verified at 0 missing and 0
> extra effective-security facts. The restore-demonstrated row is now satisfied.
>
> On 2026-08-28 the operator explicitly accepted recovery-envelope item 1 (logical backup, not
> PITR) and item 7 (role passwords are not captured and will be re-established separately if
> recovery requires them), both for empty staging only. See 2Y. All six gate rows are now satisfied.
> This is not production readiness and does not authorize the migration plan or any deployment.

- ☑ Exact target project named: `evhiixndiuwwodsouyhf` (`last-man-standing-staging`)
- ☑ Backup mechanism identified: pinned Supabase CLI `2.116.0` logical dump
  (`roles.sql`, `schema.sql`, `data.sql`) plus the companion migration ledger
- ☑ Backup actually taken: completed 2026-08-27T21:29:07Z; see section 2O
- ☑ Restore **demonstrated** into a scratch database — schema, data and effective ACL state now
  reproduce staging. The ACL recovery removed 322 target-only excess grants and independent parity
  reported 0 missing / 0 extra / 0 residual effective-security facts; see section 2X.
- ☑ Recovery point / recovery time expectations stated: RPO `2026-08-27T21:29:07Z`;
  measured **restore+verify** window 962s — **not** the runbook's Steps 6–8 RTO, and not a
  recovery capability; see section 2U for what that figure does and does not mean
- ☑ Residual risk explicitly accepted: the six risks in 2V plus recovery-envelope items 1 and 7
  were explicitly accepted for empty staging only; see section 2Y

Restore demonstration notes (what was restored, where, and what verified it):

```
WHAT:   The complete backup at lms-staging-backup.Fug9iB — roles.sql, schema.sql and the
        intact data.sql (22 auth + 12 public + 7 storage COPY sections). Nothing split,
        edited, narrowed or reassembled. Checksums re-verified immediately before the run.

WHERE:  A freshly recreated disposable local Supabase stack, container
        supabase_db_last_man_standing, image postgres:17.6.1.165, server_version 17.6,
        matching staging. Confirmed clean first: 0 public base tables and role configuration
        matching the verified fresh-stack baseline. NOT an in-place staging restore.

HOW:    Each file separately with ON_ERROR_STOP=1 — roles.sql as supabase_admin,
        schema.sql as postgres, data.sql as supabase_admin. All exit 0 at 2026-08-27T22:35:04Z.

VERIFIED BY: The committed read-only discovery SQL, split into its three sections and run
        separately against the restored database (section 1 and 3 with ON_ERROR_STOP=1,
        section 2 without, by design). Every compared measure matched the recorded staging
        evidence: P1/P2 sentinels present; Phase 1 and 2A-2J absent; 12 public base tables,
        RLS on all 12; 12 permissive SELECT policies; 4 enabled triggers; 5 extensions;
        pg_cron absent; all 8 core tables 0 rows. 41 public functions restored, all 12
        tables still owned by postgres. Migration ledger absent locally — the expected
        divergence, reconciled against the Step 5 companion artifact, not the restore.

LIMITS: Zero-row dataset, so the fixture_result_overrides circular foreign key was never
        exercised by data. Full detail in sections 2T and 2U.
```

### 2A. Backup artifact — recorded destination (Step 0 executed)

`PHASE_2K_BACKUP_RESTORE_RUNBOOK.md` Step 0 was executed on 2026-08-27. **Step 0 only**; no
authentication, dry-run, dump, restore, or deletion was performed, and Supabase was not
contacted.

| Field | Value |
|---|---|
| Durable root | `/Users/grantmiller/Documents/LMS-Backups` (`drwx------`, `700`) |
| **Recorded backup directory** | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.r1Y5AR` |
| Directory permissions | `drwx------` (`700`) |
| Contents at creation | empty (0 files) |
| Branch at execution | `feature/lms-phase-2k-staging-discovery` |
| Runbook commit executed from | `090a20036bcb8a3f706e4d3296b81437940d554c` |
| Guards passed | `dirname` equals root; `basename` matches `lms-staging-backup.??????` |

This is the value of `RECORDED_BACKUP_DIR` referenced by the runbook. Every later step, and any
eventual operator-approved disposal, validates against this exact path. It contains no dump
files: Step 4 has not been run.

### 2B. Target project confirmation (independent of the repository)

The operator supplied this Supabase dashboard URL:

```
https://supabase.com/dashboard/project/evhiixndiuwwodsouyhf/sql/f155d9c8-6b27-4b49-8c34-df36c34c66bf
```

Confirmed from it:

| Field | Value |
|---|---|
| Project reference | `evhiixndiuwwodsouyhf` |
| Project name | `last-man-standing-staging` |
| Environment | staging |
| Is production `enzdvsppduyqtpdeseyh`? | **No** — the refs differ in full |

The `/dashboard/project/<ref>/` path segment carries the ref directly, so the URL itself
establishes `evhiixndiuwwodsouyhf` and rules out the production ref `enzdvsppduyqtpdeseyh`.
This is independent of `supabase/.temp/linked-project.json`, which the runbook forbids relying
on; the two agree, but the URL is what is recorded here.

Provenance note: the project **name** and the staging designation come from dashboard
screenshots reviewed by the operator, recorded here as operator attestation. The **reference**
is verified directly from the supplied URL string. Both are recorded; the distinction is kept
because only the ref determines which database a command reaches.

The target-project row of the gate checklist above is satisfied by this entry.

### 2C. Step 1 (authenticate) — COMPLETED

| Field | Value |
|---|---|
| Status | **Step 1 complete** |
| Login method | operator-confirmed interactive browser login, run manually in an interactive terminal |
| Command run by operator | `npx --yes supabase@2.116.0 login` |
| CLI version | `2.116.0` |
| Verified (UTC) | 2026-08-27T09:14:20Z |
| Verification method | `npx --yes supabase@2.116.0 projects list` — read-only Management API call |
| Result | authenticated; the API returned project metadata, which requires a valid token |

**Persistent local CLI authentication now exists on this machine, outside the repository**, in
the Supabase CLI's own configuration location. It survives beyond this procedure and remains
until explicitly revoked or logged out. Treat it as a live credential.

**No credential value was read, printed, inspected, or recorded.** Verification relied only on
whether an authenticated read-only call succeeded, never on the token itself. `projects api-keys`
was deliberately not used, as it returns secrets.

Corroboration obtained from the same read-only call (non-secret metadata):

| Ref | Name | Region | Status |
|---|---|---|---|
| `evhiixndiuwwodsouyhf` | `last-man-standing-staging` | eu-west-1 | ACTIVE_HEALTHY |
| `enzdvsppduyqtpdeseyh` | `GRM1106's LMS` (production) | eu-west-3 | ACTIVE_HEALTHY |

This **machine-verifies** the project name recorded in section 2B, which until now rested on
operator attestation from dashboard screenshots. The staging ref and name now agree from two
independent sources, and the production project is confirmed distinct in ref, name and region.

The call also reported both projects as `linked: false`, and the CLI emitted
`Cannot find project ref. Have you run supabase link?`. This is consistent with the runbook's
rule of never relying on `supabase/.temp/linked-project.json` and always passing
`--project-ref` explicitly. That stale local file should not be treated as link state.

Incidental observation, **not** a completion of Step 3: the API reports staging Postgres
`17.6.1.155` (engine `17`). The container `pg_dump` is 17.6, so the version-compatibility
condition appears satisfiable. Step 3's own check — `select version();` read from the confirmed
staging SQL Editor — has not been performed and remains outstanding.

Historical note: an earlier attempt to run `supabase login` from the agent's non-TTY shell on
2026-08-27T08:59Z failed with `LegacyLoginMissingTokenError` (the automatic flow requires a
TTY). The offered workarounds `--token` and `SUPABASE_ACCESS_TOKEN` were both declined rather
than pass a token through that session. Superseded by the operator's manual login above.

### 2D. Step 2 (dry-run plan inspection) — COMPLETED

| Field | Value |
|---|---|
| Executed (UTC) | 2026-08-27T09:20:46Z → 2026-08-27T09:22:15Z |
| Target | `evhiixndiuwwodsouyhf` (`last-man-standing-staging`) — production ref absent from all output |
| CLI version | `2.116.0` |
| Mode | `--dry-run` on all three; no dump taken, no password supplied or requested, no API keys retrieved |
| Exit status — `--role-only` | `0` |
| Exit status — schema (no mode flag) | `0` |
| Exit status — `--data-only --use-copy` | `0` |

Generated plans (structural summary; connection details deliberately not recorded):

| Mode | Tool | Key flags |
|---|---|---|
| roles | `pg_dumpall` | `--roles-only --role postgres --quote-all-identifier --no-role-passwords --no-comments` |
| schema | `pg_dump` | `--schema-only --quote-all-identifier --role postgres --exclude-schema …` |
| data | `pg_dump` | `--data-only --quote-all-identifier --role postgres --exclude-schema … --schema "*"` |

**Schema-mode `--exclude-schema` (29 entries):** `information_schema`, `pg_*`, `_analytics`,
`_realtime`, `_supavisor`, `auth`, `etl`, `extensions`, `pgbouncer`, `realtime`, `storage`,
`supabase_functions`, `supabase_migrations`, `cron`, `dbdev`, `graphql`, `graphql_public`,
`net`, `pgmq`, `pgsodium`, `pgsodium_masks`, `pgtle`, `repack`, `tiger`, `tiger_data`,
`timescaledb_*`, `_timescaledb_*`, `topology`, `vault`.

**Data-mode `--exclude-schema` (22 entries):** `information_schema`, `pg_*`, `graphql`,
`graphql_public`, `pgsodium`, `pgsodium_masks`, `pgtle`, `repack`, `tiger`, `tiger_data`,
`timescaledb_*`, `_timescaledb_*`, `topology`, `vault`, `etl`, `extensions`, `pgbouncer`,
`realtime`, `supabase_migrations`, `_analytics`, `_realtime`, `_supavisor`.

**Data-mode table exclusions:** `auth.schema_migrations`, `storage.migrations`,
`supabase_functions.migrations`. **Data-mode schema selector:** `--schema "*"`.

Decisive determinations:

| Question | Schema mode | Data mode |
|---|---|---|
| `supabase_migrations` excluded? | **YES** | **YES** |
| `auth` excluded? | **YES** | **NO** |
| `storage` excluded? | **YES** | **NO** |

**The data dump INCLUDES `auth` data.** `auth` is absent from the data-mode schema exclusions
and `--schema "*"` is selected; only the `auth.schema_migrations` table is excluded. This
**resolves the open question in recovery-envelope item 3** — previously verified only against a
`--local` dry-run, now confirmed against the real staging project.

Comparison against recovery-envelope items 1–4 — **all confirmed, no discrepancy**:

| Item | Claim | Result |
|---|---|---|
| 1 | Logical backup, not PITR | Confirmed — `pg_dump`/`pg_dumpall` logical dumps only |
| 2 | `auth`/`storage` excluded from schema dump; target must be a Supabase stack | Confirmed |
| 3 | `auth` row data included, subject to remote confirmation | **Confirmed — no longer provisional** |
| 4 | `supabase_migrations` excluded from both modes | Confirmed |

Two observations **not** covered by the committed runbook. Neither contradicts it; the runbook
was left unedited pending review.

1. The roles plan uses `--no-role-passwords`, so role passwords are not captured. A restore
   from this backup will not recreate them. This is a sensible default but is an unstated
   limit on what "roles" recovery means.
2. The generated dry-run scripts embed connection exports including a `PGPASSWORD` assignment.
   The value was **not** printed, inspected or recorded. Step 2 output is therefore
   credential-bearing. See the containment note below; the runbook has since been amended.

### 2E. Containment note — Step 2 raw output

| Field | Value |
|---|---|
| Issue | Raw `db dump --dry-run` output in CLI `2.116.0` embeds connection exports including `PGPASSWORD` |
| Recorded (UTC) | 2026-08-27T10:33Z |
| Exposure to repository | **None** — no raw output was copied into the repository or this evidence |
| Temporary capture | three files in a session-private scratchpad outside the repository, created solely to hold Step 2 output |
| Capture permissions | `700` parent directory; files `644` |
| Disposition | **removed by best-effort unlinking** |

The raw output was never pasted into chat, committed, logged as evidence, or retained. Only
sanitized structural findings appear in section 2D: tool names, flag names, and schema/table
exclusion lists. No password value or fragment, no password length, no host, no username, and
no connection string was recorded anywhere in this repository.

**Deletion is best-effort unlinking only.** On APFS/SSD storage a physical overwrite cannot be
guaranteed — copy-on-write, wear levelling, over-provisioned blocks and filesystem snapshots
may retain recoverable copies. No secure erasure is claimed or implied.

The embedded `PGPASSWORD` is treated as **potentially sensitive**. No determination is made or
implied about whether it is ephemeral or persistent, and it was not inspected to find out.
Any decision about credential rotation is the operator's and has not been taken here.

Verification performed: the three capture files were confirmed absent afterwards; a filename
search across the backup root and scratchpad found no other dry-run output artifact; and a
repository content scan found no host string and no `PGPASSWORD` value — the single
`PGPASSWORD` match in this document is the prose reference above, with no value attached.

Runbook amendment: Step 2 now carries a prominent credential-bearing warning and a tested
redaction wrapper that redacts every connection export before display, keeps the unredacted
text in a shell variable rather than on disk, and preserves the CLI's true exit status. The
redaction and exit-status control flow were tested with synthetic dummy text only, never with
the captured output. `--no-role-passwords` was added to the recovery envelope as item 7.

No file was created in the backup directory, which remains empty. Captured output was written
only to a session-private scratchpad directory (`700`) outside the repository.

### 2F. Step 3 (server version compatibility) — COMPLETED

| Field | Value |
|---|---|
| Confirmed project | `evhiixndiuwwodsouyhf` (`last-man-standing-staging`) |
| Query | `select version();` |
| Execution | run manually by the operator in the confirmed staging SQL Editor |
| Result | `PostgreSQL 17.6 on x86_64-pc-linux-gnu, compiled by gcc (GCC) 15.2.0, 64-bit` |
| Server major version | `17` |
| Dump tooling version | PostgreSQL `17.6` (`pg_dump`/`pg_dumpall` in `public.ecr.aws/supabase/postgres:17.6.1.165`) |
| Compatibility verdict | **PASS** — the dump tooling is not older than the server |

`pg_dump` must be at least the server version. Server and tooling are both `17.6`, so the
requirement is met exactly rather than by margin. The runbook's stop condition — server major
version greater than 17 — is not triggered.

This was a **read-only** query. No staging mutation occurred, no schema or data was altered,
and no password was supplied or requested to run it.

Corroboration: the read-only Management API call recorded in section 2C independently reported
staging Postgres `17.6.1.155` with `postgres_engine: 17`. That is the Supabase image build
identifier; `select version()` reports the upstream PostgreSQL version. The two agree on major
version 17 and are consistent with one another. Step 3 was nevertheless performed through the
runbook's own channel rather than relying on the API value.

### 2G. Step 4 (take the dump) — ATTEMPTED, FAILED

| Field | Value |
|---|---|
| Backup start (UTC) | 2026-08-27T16:46:08Z |
| Recorded directory | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.r1Y5AR` |
| Result | **FAILED** |
| Exit status (`BACKUP_STATUS`) | `1` |
| Failure stage | **first command — the roles dump** |
| Sanitized cause | database password authentication failed |
| Failure observed (UTC) | 2026-08-27T16:47:25Z — 77s after start |
| Completion time / duration / checksums / RPO | **none produced** |

`set -e` stopped execution immediately at the first failure. The schema and data dumps were
**never invoked**.

On-disk state, verified directly:

| File | State |
|---|---|
| `roles.sql` | exists — **0 bytes**, permissions `600` |
| `schema.sql` | **not created** |
| `data.sql` | **not created** |

Directory permissions remain `700`, containing exactly one file.

**This directory is an INCOMPLETE, INVALID attempt.** It must never be reused, reused as a
destination, or "filled in" by re-running individual dump commands: a directory assembled from
separate attempts has no single consistent RPO. Any future backup starts in a **new**
`mktemp -d` directory.

The partial artifact is **retained**, not deleted, pending separately approved guarded
disposal. No deletion has been performed and none is authorized by this entry.

The failure-handling design behaved exactly as intended and is worth recording as validated:

- `set -e` aborted at the first failing dump, so no later dump ran against a broken credential.
- No RPO, duration, or checksum was produced, so the invalid attempt cannot be mistaken for a
  usable backup on the strength of accompanying metadata.
- `umask 077` made `roles.sql` owner-only (`600`) **at creation**, before any `chmod` could
  run — confirming that a partial file is confidentiality-protected even when the success
  branch never executes. Protection and validity remain separate: this file is protected and
  still invalid.

No database hostname, IP address, username, password, connection string, or raw error output
is recorded here or anywhere in this repository. Only the sanitized cause above is retained.

Outstanding before any retry: the credential itself must be resolved. See section 2H.

### 2H. Step 4 retry preparation — credential reset and fresh destination

Prepared 2026-08-27. **Step 4 has not been retried**; this section records preparation only.

#### Credential

| Field | Value |
|---|---|
| Action | staging database password reset, **operator-confirmed** |
| Scope | **staging only** — project ref `evhiixndiuwwodsouyhf` (`last-man-standing-staging`) |
| Production | ref `enzdvsppduyqtpdeseyh` — **not changed**, not accessed, not contacted |
| Storage | saved privately in the operator's password manager |
| Recorded here | **no password value, fragment, or length** |

The new password has **not been tested**. Whether it is correct will first be established by
the Step 4 retry itself. No dry-run, dump, or connection was performed to verify it, and no
other credential was rotated.

#### New retry destination

| Field | Value |
|---|---|
| Path | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.oM6MZf` |
| Created | `mktemp -d` beneath the unchanged durable root, per the committed convention |
| Resolved | via `pwd -P` |
| Permissions | `drwx------` (`700`) |
| Contents | **empty** — 0 files |
| Guards | direct-parent equals root; basename matches `lms-staging-backup.??????` |

This is the new `RECORDED_BACKUP_DIR`. The runbook's Step 4 path variables have been updated to
it; the durable root and every other command are unchanged.

#### Original failed attempt

`/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.r1Y5AR` **remains invalid and
retained**, verified untouched at preparation time: exactly one file, `roles.sql`, 0 bytes,
permissions `600`. It is not reused, not written to, not deleted, and is not the retry
destination. Disposal remains subject to separate operator approval.

Both directories now coexist under the durable root. The retry writes only to
`lms-staging-backup.oM6MZf`; the guards in Step 4 reject any path that is not the recorded one,
so the failed directory cannot be selected by accident.

### 2I. Step 4 retry — ATTEMPTED, FAILED

| Field | Value |
|---|---|
| Retry directory | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.oM6MZf` |
| Final status | **FAILED** |
| Exit status (`BACKUP_STATUS`) | `1` |
| Failure stage | **first command — the roles dump**, on every attempt |
| Completion time / duration / checksums / RPO | **none exist** |

Three operator attempts were made **in this same retry directory**:

| Attempt | Sanitized outcome |
|---|---|
| 1 | database-password authentication failure |
| 2 | CLI access token unavailable |
| 3 | database-password authentication failure |

Every attempt stopped during the first roles-dump command. No attempt reached the schema or
data dump.

On-disk state, verified directly:

| File | State |
|---|---|
| `roles.sql` | exists — **0 bytes**, permissions `600` |
| `schema.sql` | **never created** |
| `data.sql` | **never created** |

Directory permissions remain `700`, containing exactly one file.

**Deviation from the runbook, recorded explicitly.** Re-running the Step 4 block against the
same destination is contrary to the runbook, which requires a fresh `mktemp -d` directory after
any failure. That instruction exists to prevent a directory assembled from separate attempts
carrying no single consistent RPO.

In this instance the deviation **did not** produce a usable or mixed-RPO artifact: every
attempt failed during the first command, before any content was written. The three attempts
left a single zero-byte `roles.sql` — each run recreated the same empty file rather than
accumulating output — so there is no partial content from one attempt combined with content
from another. The outcome is benign, but the deviation is recorded because the reasoning that
makes it benign is specific to this failure mode and must not be treated as precedent. A
failure that had written any bytes would have made the directory genuinely ambiguous.

**This directory is permanently invalid, retained, and must not be reused** — not as a
destination, not filled in, not partially reused. Its disposal remains subject to separate
operator approval.

**Further backup attempts are blocked** pending a separate, **read-only** authentication
diagnosis. Attempt 2 failing on an unavailable CLI access token, between two password
failures, indicates the authentication state is not simply a wrong password: the Step 1 login
verified in section 2C may no longer be valid, and the database password and the CLI access
token are distinct credentials with distinct failure modes. Diagnosis must establish which of
them is actually failing before any further attempt. No credential has been tested, reset, or
rotated as part of this entry.

The original failed attempt at `lms-staging-backup.r1Y5AR` was verified untouched at the time
of this record: exactly one file, `roles.sql`, 0 bytes, permissions `600`, unchanged
modification time. Both failed directories are retained and neither has been deleted.

No database hostname, IP address, username, password, connection string, or raw error output is
recorded here or anywhere in this repository. Only the sanitized outcomes above are retained.

### 2J. Read-only CLI authentication diagnosis

Single read-only check. No database command was run, no API keys were retrieved, `--debug` was
not used, and no stored token contents were inspected or printed.

| Field | Value |
|---|---|
| Command | `npx --yes supabase@2.116.0 projects list` |
| UTC time | 2026-08-27T18:42:15Z |
| Exit status | `0` |
| Authenticated project metadata returned | **YES** |
| Staging ref `evhiixndiuwwodsouyhf` present | **YES** |
| Project entries returned | 2 |
| Sanitized error category | none — the command succeeded |

**The CLI access token is valid.** Management API authentication works, and the account can see
the staging project. The Step 1 login recorded in section 2C has not lapsed.

What this does and does not establish:

- It **does** establish that the CLI access token was usable at the timestamp above, so the
  "CLI access token unavailable" outcome in section 2I attempt 2 was **not** a persistent loss
  of login. It was transient, or specific to that invocation.
- It does **not** exercise the database password. `projects list` reaches the Management API
  only; `db dump` additionally requires the project's database password, which is a separate
  credential over a separate channel. That password remains **untested**.

Consequently the remaining suspect for the section 2I failures is the **database password**,
not the CLI login. This narrows the diagnosis but does not complete it: nothing here proves the
current database password is wrong, only that the access token is not the obstacle.

No credential was tested, reset, or rotated. No backup directory was created and no backup was
attempted. Further backup attempts remain blocked pending an explicit decision on the database
password. That decision is recorded in section 2K.

### 2K. Second credential reset and third retry destination

Prepared 2026-08-27. **Step 4 has not been retried**; this section records preparation only.

#### Credential — second reset

| Field | Value |
|---|---|
| Action | staging database password reset — **second** reset, operator-confirmed |
| Scope | **staging only** — project ref `evhiixndiuwwodsouyhf` (`last-man-standing-staging`) |
| Production | ref `enzdvsppduyqtpdeseyh` — **not changed**, not accessed, not contacted |
| Storage | saved privately by the operator |
| Recorded here | **no password value, fragment, or length** |

Target confirmation: the operator supplied this Database Settings URL immediately before
performing the second reset —

```
https://supabase.com/dashboard/project/evhiixndiuwwodsouyhf/database/settings
```

The `/dashboard/project/<ref>/` path segment carries the ref directly, so the URL itself
confirms staging ref `evhiixndiuwwodsouyhf`. It is a Database Settings page, which is where a
database password reset is performed, so the URL corroborates both the target project and the
nature of the action. Operator attestation: the reset was completed and the new password saved.
Production ref `enzdvsppduyqtpdeseyh` remained untouched — distinct in full, not the target,
not accessed, not contacted.

The new password has **not been tested**. Section 2J established that the CLI access token is
valid, so the database password is the remaining untested element; whether this second reset
resolves the failures will first be established by the Step 4 retry itself. No dry-run, dump,
or connection was performed to verify it, and no other credential was rotated.

#### Third retry destination

| Field | Value |
|---|---|
| Path | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.VEgLt7` |
| Created | `mktemp -d` beneath the unchanged durable root, per the committed convention |
| Resolved | via `pwd -P` |
| Permissions | `drwx------` (`700`) |
| Contents | **empty** — 0 files |
| Guards | direct-parent equals root; basename matches `lms-staging-backup.??????` |

This is the new `RECORDED_BACKUP_DIR`. The runbook's two Step 4 path variables were updated to
it; the durable root and every other command are unchanged.

#### Previous attempts

Both remain **invalid and retained**, verified unchanged at preparation time — each holding
exactly one file, `roles.sql`, 0 bytes, permissions `600`, with unchanged modification times:

| Directory | State |
|---|---|
| `lms-staging-backup.r1Y5AR` | first failed attempt — invalid, retained |
| `lms-staging-backup.oM6MZf` | failed retry, three attempts — invalid, retained |

Neither is reused, written to, or deleted. Disposal of both remains subject to separate
operator approval. Three directories now coexist under the durable root; Step 4's recorded-path
equality guard accepts only `lms-staging-backup.VEgLt7`, so neither invalid directory can be
selected by accident.

### 2L. Third Step 4 destination — ATTEMPTED, FAILED

| Field | Value |
|---|---|
| Directory | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.VEgLt7` |
| Start time (UTC) | 2026-08-27T20:21:45Z |
| Result | **FAILED**, during the first roles dump |
| Sanitized cause | database-password authentication failure |
| Shell exit status | **not captured — see below** |
| Completion time / duration / checksums / RPO | **none exist** |

**No shell-status variable was captured.** The explicit `BACKUP_STATUS=$?` assignment did not
execute, so there is no recorded value for it and none is inferred here. What is known is that
**the dump command itself reported failure**; that is the basis for the FAILED result, not a
captured shell status. No exit status is invented to fill the gap.

On-disk state, verified directly:

| File | State |
|---|---|
| `roles.sql` | exists — **0 bytes**, permissions `600`, mtime 2026-08-27T20:22:11Z |
| `schema.sql` | **never created** |
| `data.sql` | **never created** |

Directory permissions remain `700`, containing exactly one file. **This directory is invalid,
retained, and must never be reused** — not as a destination, not filled in, not partially
reused. Disposal remains subject to separate operator approval.

#### Both password resets have now been rejected

The manually supplied `SUPABASE_DB_PASSWORD` has been rejected after **both** staging password
resets — the first recorded in section 2H, the second in section 2K. Two independent resets,
each followed by an authentication failure, make "the password was typed or saved incorrectly"
a less likely explanation than something systematic.

**Further password resets and backup attempts are blocked**, pending review of whether CLI
`2.116.0` is using Supabase **temporary database access derived from the authenticated platform
token** rather than the supplied `SUPABASE_DB_PASSWORD`. Resetting the password again before
that review would be aimed at a credential the tool may not be using.

There is prior evidence in this document consistent with that hypothesis. Section 2D recorded
that the generated dry-run scripts embed a `PGPASSWORD` assignment carrying a value **even
though no password was supplied or requested on the command line**. The CLI therefore obtained
a database credential from somewhere other than operator input. That observation was made
before this hypothesis was formed and is recorded independently of it, but it points the same
way and should be part of the review.

This was stated as a hypothesis to be reviewed. **It has since been confirmed — see section
2M**, which supersedes it.

All three failed directories were verified untouched at the time of this record — `r1Y5AR`,
`oM6MZf` and `VEgLt7` each hold exactly one file, `roles.sql`, 0 bytes, permissions `600`, with
`r1Y5AR` and `oM6MZf` retaining their earlier modification times. None has been deleted.

No raw error output, hostname, IP address, username, credential, or connection string is
recorded here or anywhere in this repository.

### 2M. CONFIRMED — CLI 2.116.0 credential resolution, and why all five attempts failed

Established by local inspection of the pinned CLI implementation. **No Supabase contact, no
dump, and no credential inspection** were involved.

#### Confirmed credential precedence

| Order | Source | Effect |
|---|---|---|
| 1 | explicit `--password` flag | used if given |
| 2 | `SUPABASE_DB_PASSWORD` environment variable | used if non-empty |
| 3 | neither supplies a non-empty password | the authenticated CLI **requests a temporary database login role** through the Management API and uses that credential |

Independent corroboration from the pinned binary: it defines the operation `v1CreateLoginRole`
— *"[Beta] Create a login role for CLI with temporary password"* —
`POST /v1/projects/{ref}/cli/login-role`, with request-body field `read_only`. Exactly one call
site passes `read_only:!1`, which in minified JavaScript is `read_only: false`.

**The automatic login role is requested with `read_only: false`.** It is not inherently a
read-only credential. The backup operation remains non-mutating because it runs only
`pg_dumpall`/`pg_dump` — the tool choice is the safety boundary, not the credential.

#### Why all five attempts failed

Exporting `SUPABASE_DB_PASSWORD` selected precedence path 2 and **disabled the automatic path
that would otherwise have worked**. Every attempt therefore authenticated with a
manually-supplied password, and every attempt failed on that path:

| Section | Attempts | Path forced |
|---|---|---|
| 2G | 1 | manual password (path 2) |
| 2I | 3 | manual password (path 2), except attempt 2 which failed earlier on token availability |
| 2L | 1 | manual password (path 2) |

This also explains the observation first recorded in section 2D: the dry-run scripts embedded a
`PGPASSWORD` value even though no password was supplied on the command line. That credential
came from **path 3**, the automatic temporary-login path — the very mechanism the exported
variable then suppressed during the real attempts.

#### Consequences

- **No further database-password reset is appropriate.** The two resets recorded in sections 2H
  and 2K were aimed at a credential the tool was only using because the runbook forced it to.
  A third reset would not help.
- The correct fix is to supply **no** database password at all. The runbook's Step 4 has been
  amended accordingly: the prompt, the export, and the password-clearing trap are removed;
  `SUPABASE_DB_PASSWORD` is verified absent beforehand and `unset` inside the dump subshell; and
  no `--password` or `--db-url` appears in any dump command.
- Authentication for the dump now depends on the CLI login verified in section 2J, which was
  confirmed valid. A future authentication failure should send the operator back to that login,
  not to a password reset.
- Dry-run output remains credential-bearing. Path 3 is precisely why a credential appears in it,
  so the existing warnings and redaction wrapper still apply unchanged.

The three retained failed directories are unaffected by this finding and remain invalid,
retained, and awaiting separately approved disposal. A fourth destination has since been
prepared — see section 2N.

### 2N. Fourth Step 4 destination — prepared

Prepared 2026-08-27. **Step 4 has not been run against it**; this section records preparation
only. No credential was supplied, inspected, or reset, and Supabase was not contacted.

| Field | Value |
|---|---|
| Path | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.Fug9iB` |
| Created | `mktemp -d` beneath the unchanged durable root, per the runbook procedure |
| Resolved | via `pwd -P` |
| Permissions | `drwx------` (`700`) |
| Contents | **empty** — 0 files |
| Guards | direct-parent equals root; basename matches `lms-staging-backup.??????` |
| Branch at preparation | `feature/lms-phase-2k-staging-discovery`, working tree clean |

This is the new `RECORDED_BACKUP_DIR`. The runbook's two Step 4 path variables were updated to
it; the durable root and every other command are unchanged.

**This is the first destination prepared since the credential-path correction in section 2M.**
The three previous attempts all forced the manual-password path by exporting
`SUPABASE_DB_PASSWORD`. Step 4 no longer supplies a database password at all, so a run against
this destination will use the automatic temporary-login path — the mechanism the earlier
attempts suppressed. That is the substantive difference from the three failed attempts, not the
directory itself.

#### Previous attempts — all three verified unchanged

Verified immediately before this directory was created, as a hard precondition:

| Directory | Files | `roles.sql` | mtime (UTC) | Status |
|---|---|---|---|---|
| `lms-staging-backup.r1Y5AR` | 1 | 0 bytes, `600` | 2026-08-27T16:47:25Z | invalid, retained |
| `lms-staging-backup.oM6MZf` | 1 | 0 bytes, `600` | 2026-08-27T18:19:09Z | invalid, retained |
| `lms-staging-backup.VEgLt7` | 1 | 0 bytes, `600` | 2026-08-27T20:22:11Z | invalid, retained |

Each contains only its expected `roles.sql` and no other entry. None is reused, written to, or
deleted; disposal of all three remains subject to separate operator approval.

Four directories now coexist under the durable root. Step 4's recorded-path equality guard
accepts only `lms-staging-backup.Fug9iB`, so none of the three invalid directories can be
selected by accident.

### 2O. Steps 4–5 — backup completed and companion ledger bound

Step 4 completed successfully against confirmed staging
`evhiixndiuwwodsouyhf` using Supabase CLI `2.116.0`'s automatic temporary-login path. No
database password was requested or supplied. The operation used only logical dump tools; no
staging mutation was performed.

| Field | Value |
|---|---|
| Resolved backup path | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.Fug9iB` |
| Backup start (UTC) | `2026-08-27T21:26:48Z` |
| Backup end (UTC) | `2026-08-27T21:29:07Z` |
| Duration | `139s` |
| Recovery point (RPO) | `2026-08-27T21:29:07Z` |
| Result | **SUCCESS** — all three dumps completed |

#### Backup artifacts

Verified directly on disk after completion. The directory remains `700`; every artifact is
owner-only (`600`).

| File | Size (bytes) | SHA-256 |
|---|---:|---|
| `roles.sql` | 370 | `168a95a9c745af5ed4679751f90419ac9dc434240a213b03e32a06d5664c2308` |
| `schema.sql` | 121177 | `d33f5d0cc0533c3c4a298fedc9a17e9fb3b134d2a37075d200810d545dafdd80` |
| `data.sql` | 13628 | `73c24602cf7499ba3c9b1ef4313cdd013939f0a6f4cba8b3fc8700a4a684d8ea` |

The data dump reported a circular foreign-key constraint involving
`fixture_result_overrides`. This is a restore-test finding, not a dump failure. Step 7 must
stop on and report any resulting SQL error; the dump must not be edited or the warning waived
without separate review.

#### Required companion migration ledger (Step 5)

The 24-row staging application migration history remains recorded verbatim in section 4. It
agrees with the recorded schema sentinels: Modules 1–22 plus P1/P2 are present, while Phase 1
and Phase 2A–2J are absent. No disagreement was found at this binding step.

| Provenance field | Value |
|---|---|
| Evidence source commit before this Step 5 edit | `e5222cf50dd6e7ba89b085c8cd6237f3cec730a5` |
| SHA-256 of that committed evidence document | `b716db1ff23cf9a336f54151fbda6e4859fe204b7c749e54e4ce5e692c2d398a` |
| Ledger rows | `24` |

This ledger is **companion reconstruction evidence only**. It does not recreate database
state, and restoring the dump does not restore the staging application ledger. Any unexplained
disagreement between this ledger, the restored schema sentinels, and the expected source commit
stops the process; no source is treated as automatically authoritative.

The backup mechanism and backup-taken gate rows are now satisfied. The overall gate remains
`NOT READY`: restore demonstration, completed RPO/RTO expectations, and explicit residual-risk
acceptance remain open.

*(Superseded: all three subsequently completed — restore demonstrated in 2T/2U, RPO/RTO stated
in 2U, residual risk accepted in 2V. The gate is now `READY`, scope-limited. This paragraph
records the state at the time Step 4/5 completed.)*

### 2P. Step 6 — local disposable restore stack started

**Step 6 only.** No restore was performed: `roles.sql`, `schema.sql` and `data.sql` have **not**
been applied. Staging and production were not contacted.

| Field | Value |
|---|---|
| `RESTORE_START_UTC` | `2026-08-27T21:39:36Z` |
| `RESTORE_START_EPOCH` | `1787866776` |
| Branch | `feature/lms-phase-2k-staging-discovery`, working tree clean |
| CLI version | `2.116.0` (pinned) |
| Stop command | `stop --no-backup` — reported *"Stopped supabase local development setup."* |
| Start command | `start -x studio,imgproxy,inbucket,storage-api,edge-runtime,logflare,vector,supavisor,realtime` |
| Start exit status | `0` |

The start epoch is recorded for the **RTO calculation in Step 8**, which measures local-stack
startup plus restore plus verification as a single window.

#### Backup integrity re-verified before starting

All three artifacts were re-checksummed immediately before Step 6 and again after it. Sizes,
permissions and SHA-256 values are unchanged from section 2O, so starting the stack did not
touch the backup.

#### Local container state

| Container | Status |
|---|---|
| `supabase_db_last_man_standing` | **running, healthy** |
| `supabase_pg_meta_last_man_standing` | running, healthy |
| `supabase_rest_last_man_standing` | running |
| `supabase_auth_last_man_standing` | running, healthy |
| `supabase_kong_last_man_standing` | running, healthy |
| `supabase_inbucket_last_man_standing` | running — see deviation below |

Database container image `public.ecr.aws/supabase/postgres:17.6.1.165`, reporting
`server_version` **17.6**. This matches the staging server version recorded in section 2F, so
the restore target is version-aligned with the source.

The stack is **clean**: `public` contains **0 base tables**, confirming nothing pre-exists to
confuse the Step 8 verification.

#### Deviation: the `inbucket` exclusion has no effect

`supabase_inbucket_last_man_standing` is running even though `inbucket` appears in the `-x`
list. `supabase start --help` on this CLI version lists the excludable services as
`gotrue, realtime, storage-api, imgproxy, kong, mailpit, postgrest, postgres-meta, studio,
edge-runtime, logflare, vector, supavisor` — **`inbucket` is not among them; the mail service
is named `mailpit`**. The token is therefore not recognised and the mail container starts
regardless.

This is harmless for the restore: the mail service plays no part in Steps 7 or 8, and the
database container is unaffected. It is recorded because the runbook's command implies an
exclusion that does not take effect, and a future reader should not infer the service was
suppressed. Correcting the token to `mailpit` is a separate runbook change and was **not** made
as part of executing Step 6.

Note also that the CLI logged *"Seeding globals from roles.sql"* during startup. That is the
CLI's **own internal** roles file for local initialisation — it is **not** the backup's
`roles.sql`, which remains unapplied.

Step 7 was subsequently attempted — see section 2Q. Step 8 has not been run.

### 2Q. Step 7 — restore ATTEMPTED, STOPPED at the first file

Restore into the running local disposable stack. **It stopped at the first file and did not
proceed.** Staging and production were not contacted.

| Field | Value |
|---|---|
| Container | `supabase_db_last_man_standing` (running, healthy throughout) |
| Backup directory | `/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.Fug9iB` |
| Preconditions | container healthy; `public` had **0 base tables**; all three checksums re-verified against section 2O — **all matched** |

#### Per-file outcome

| Order | File | Start (UTC) | End (UTC) | Exit | Outcome |
|---|---|---|---|---|---|
| 1 | `roles.sql` | 2026-08-27T21:42:57Z | 2026-08-27T21:42:57Z | `3` | **FAILED** |
| 2 | `schema.sql` | — | — | — | **not run** |
| 3 | `data.sql` | — | — | — | **not run** |

Sanitized error, verbatim and complete — it contains no credential, host, or connection detail:

```
ERROR:  permission denied for parameter log_min_messages
```

Execution stopped immediately, as required. The remaining two files were **not** applied, no
retry was made, no dump was edited, no trigger was disabled, no constraint was dropped, and the
`fixture_result_overrides` circular foreign-key warning was **not** reached — that warning
concerns `data.sql`, which never ran.

#### Characterisation — CORRECTED

An earlier revision of this section attributed the failure to an `ALTER ROLE … SET` statement.
**That was wrong**, inferred from a truncating pattern match rather than the statement text.
Corrected from the file itself, read-only and unaltered.

`roles.sql` contains, in order: 3 × session `SET`, then

```
ALTER ROLE "anon"          SET "statement_timeout" TO '3s';
ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';
ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';
GRANT SET ON PARAMETER "log_min_messages" TO "supabase_realtime_admin";
RESET ALL;
```

**The failing statement is the `GRANT SET ON PARAMETER`, not any `ALTER ROLE`.** The three
`ALTER ROLE` statements executed successfully *before* the failure.

Cause — a **privilege difference between source and target**, not a corrupt or truncated dump:

| Role | Superuser | `CREATEROLE` |
|---|---|---|
| `postgres` (local, used for the attempt) | **no** | yes |
| `supabase_admin` (local) | **yes** | yes |

`GRANT SET ON PARAMETER` requires superuser. The restore ran as `postgres`, which locally is not
one, so the statement was rejected. On Supabase-managed staging the dumping role holds that
privilege, which is why the dump contains the statement at all.

#### Partial execution — CORRECTED, see section 2R

> **The conclusion originally recorded here was wrong and is superseded by section 2R.** It
> claimed the failed attempt contaminated the local stack. It did not establish that. The
> original wording is replaced below rather than deleted, and the reasoning error is retained
> as part of the record.

What is established:

- The three `ALTER ROLE … SET "statement_timeout"` statements **executed before the error**.
  `psql` commits each statement in turn, and the failure came at the final `GRANT`.
- Those statements set values that are **already present in a freshly initialised local stack**.
- Therefore **partial execution occurred, but no observable role-configuration divergence — and
  so no contamination — was established.**

| Role | After the failed attempt | Freshly initialised stack, never restored |
|---|---|---|
| `anon` | `statement_timeout=3s` | `statement_timeout=3s` |
| `authenticated` | `statement_timeout=8s` | `statement_timeout=8s` |
| `authenticator` | `session_preload_libraries=supautils, safeupdate, statement_timeout=8s, lock_timeout=8s` | identical |

The two states are indistinguishable by `rolconfig`. The original claim compared the
post-failure state against an assumption rather than against a measured baseline.

What survives the correction: **"zero public base tables" was still insufficient evidence that
the stack was clean.** Role state also needed checking — the error was not in looking at
`rolconfig`, but in interpreting expected defaults as contamination without first establishing
a baseline. The runbook now checks role configuration *against a verified fresh-stack baseline*
rather than requiring the absence of values initialisation always creates.

#### State after the stop

| Item | State |
|---|---|
| Local `public` base tables | **0** — no schema or data was restored |
| Local role configuration | **modified** — see partial application above |
| Container | running, healthy |
| Backup artifacts | **unaltered** — sizes, permissions and SHA-256 all still match section 2O |
| Three retained failed directories | untouched |

The backup itself is **not** invalidated by this. Section 2O's success stands: the dump
completed and its integrity is intact. What has not yet been demonstrated is that it *restores*,
which is precisely the gate row still outstanding.

#### Consequence for the gate

The **restore-demonstrated** gate row remains **unchecked**, and the gate remains `NOT READY`.
An RTO figure is not produced, because the restore did not complete; the window opened at
`RESTORE_START_UTC` in section 2P remains open and unmeasured.

*(Superseded: the restore was later demonstrated successfully in 2T and verified in 2U, and the
gate is now `READY`, scope-limited — see 2V. This paragraph records the state at the time this
failed attempt was assessed. The 2P window referenced here was discarded, not reused.)*

#### Resolution adopted — run `roles.sql` as `supabase_admin`

The options considered were: apply the roles dump in a superuser context; exclude role-level
statements from the restore path; or scope the demonstration to schema and data only. The
second and third both reduce what the demonstration proves, and the third would leave "the
backup restores" asserted on the strength of a partial exercise.

The adopted fix is the first, and it requires **no change to the backup**: `roles.sql` now runs
as `supabase_admin`, which is a local superuser and the appropriate platform-administration
context. `schema.sql` and `data.sql` keep `-U postgres`, the intended application ownership
context, unless a separately verified reason requires otherwise. All three files still run
separately with `ON_ERROR_STOP=1`, and the first error still stops the process.

The backup file is unchanged, no error is waived, and no dump will be edited to force a pass.

Runbook amendments made alongside this correction:

- Step 7 runs `roles.sql` as `supabase_admin`; `schema.sql` and `data.sql` unchanged.
- A retry must first **stop and recreate** the local stack, because the failed attempt altered
  local role configuration.
- `RESTORE_START_UTC` / `RESTORE_START_EPOCH` are recorded **only after** a fresh stack is
  confirmed healthy **and** clean — 0 public base tables *and* role configuration at platform
  defaults.
- Step 6's exclusion token is corrected from `inbucket` to `mailpit`, the actual service name
  in this CLI version, with a note that the container retains the legacy `inbucket` name.

The restore has **not** been retried. Steps 7 and 8 remain outstanding, the gate remains
`NOT READY`, and no RTO is produced from the failed window — those timings are discarded, not
reused.

**Superseded in part by section 2R:** the "partial application / contamination" finding above
is **not supported by evidence** and is corrected there.

### 2R. Retry HALTED before Step 7 — the contamination finding was wrong

The corrected retry was executed as far as the cleanliness checks and **stopped there**. No
restore file was applied. Staging and production were not contacted.

#### What was done

| Step | Outcome |
|---|---|
| Branch / tree | `feature/lms-phase-2k-staging-discovery`, clean |
| Backup checksums re-verified | all three **MATCH** section 2O |
| Stack stopped (`stop --no-backup`) | *"Stopped supabase local development setup."* |
| Stack recreated (corrected Step 6, `mailpit` excluded) | exit `0` |
| Container | `supabase_db_last_man_standing` running, **healthy**, created 2026-08-27T22:10:43Z |
| `mailpit` exclusion | **effective** — no mail container running, and no `MAILPIT_URL`/`INBUCKET_URL` in start output. The corrected token works. |
| `public` base tables | **0** |
| `rolconfig` check | **did not pass as specified — see below** |

#### The finding: those settings are platform defaults, not contamination

Section 2Q recorded that the three `ALTER ROLE … SET "statement_timeout"` statements
"partially applied" and left the local stack contaminated. **That conclusion was not
evidence-based.** It compared the post-failure state against an assumption rather than against a
fresh baseline.

A stack created 90 seconds earlier, with no restore ever applied to it, shows **identical**
values:

| Role | After the failed restore | Fresh stack, before any restore |
|---|---|---|
| `anon` | `statement_timeout=3s` | `statement_timeout=3s` |
| `authenticated` | `statement_timeout=8s` | `statement_timeout=8s` |
| `authenticator` | `session_preload_libraries=supautils, safeupdate, statement_timeout=8s, lock_timeout=8s` | identical |

The staging roles dump sets exactly the same values the local Supabase stack already applies at
initialisation. The two are therefore **indistinguishable by `rolconfig`**.

Corrected conclusion: the three `ALTER ROLE` statements very likely *did* execute — `psql`
commits each statement in turn and the failure came at the final `GRANT` — but they set values
identical to the local defaults, so **no observable modification resulted**. The stack was not
meaningfully contaminated, and `rolconfig` cannot evidence either way.

#### Why the retry stopped here

The specified cleanliness check requires `anon`, `authenticated` and `authenticator` to show
platform-default `rolconfig` "with none of the partially restored timeout settings". Those two
conditions are the **same state**: the timeout settings *are* the platform defaults. The check
cannot pass as written, because its premise — that the settings came from the dump — is false.

The instruction was to record fresh timings and proceed only after **all** cleanliness checks
pass. One cannot, so the retry halted before Step 7. No `RESTORE_START_UTC` was recorded, no
restore file was applied, and no RTO exists.

This was not treated as a formality to wave through: proceeding would have meant either
recording a passed check that did not pass, or silently redefining a gate condition. Either
would corrupt the evidence chain, and the underlying error is already committed in the
repository.

#### What still holds, and what needs a decision

Unaffected: the Step 7 role-context fix. `GRANT SET ON PARAMETER "log_min_messages"` genuinely
requires superuser, `postgres` locally is not one, and `supabase_admin` is. Running `roles.sql`
as `supabase_admin` remains the correct fix and is independent of this correction.

Also unaffected: recreating the stack before a retry is still sound practice — a failed restore
*could* leave state behind, and rebuilding costs little. Only its stated justification
("observed contamination") is withdrawn.

#### Resolution applied

Both points are now settled and the runbook and section 2Q have been amended accordingly.

1. **Cleanliness check restated and now satisfiable.** It requires zero public base tables
   **and** `anon`/`authenticated`/`authenticator` configuration matching a verified
   fresh-stack baseline. The requirement that the timeout values be *absent* is removed.

   Verified fresh-stack baseline, recorded in the runbook:

   | Role | Baseline |
   |---|---|
   | `anon` | `statement_timeout=3s` |
   | `authenticated` | `statement_timeout=8s` |
   | `authenticator` | includes `statement_timeout=8s` and `lock_timeout=8s` |

2. **Section 2Q corrected in place, without erasing history.** Its incorrect conclusion is
   marked as superseded by this section, the original claim is replaced rather than deleted,
   and the reasoning error is retained as part of the record.

Preserved unchanged, because this correction does not touch them:

- The failure cause: `GRANT SET ON PARAMETER "log_min_messages" TO "supabase_realtime_admin"`,
  which requires superuser.
- The fix: `roles.sql` runs as `supabase_admin`; `schema.sql` and `data.sql` remain under
  `postgres`.
- Stack recreation after a failed restore, retained as a **conservative isolation step**. Its
  rationale is corrected: it is justified by what a failure *could* leave behind, not by
  contamination that was observed here.

#### State of the recreated stack

| Item | State |
|---|---|
| Container | `supabase_db_last_man_standing`, created 2026-08-27T22:10:43Z, running, **healthy** |
| `public` base tables | **0** |
| Role configuration | matches the verified fresh-stack baseline above |
| Restore files applied | **none** — `roles.sql`, `schema.sql` and `data.sql` have not been run |
| `mailpit` exclusion | effective — no mail container, and no `MAILPIT_URL` in the start output |

**No `RESTORE_START_UTC` or `RESTORE_START_EPOCH` was recorded for this attempt, and no RTO is
claimed.** Timings from the aborted first attempt are discarded, not reused.

Backup artifacts are unaltered, all four directories are intact, and the gate remains
`NOT READY`. Step 7 was subsequently executed — see section 2S.

### 2S. Step 7 executed — two of three files restored, STOPPED at `data.sql`

The corrected Step 7 ran against the fresh stack. **`roles.sql` and `schema.sql` succeeded;
`data.sql` failed and the process stopped.** Staging and production were not contacted.

#### Preconditions (all passed before the window opened)

| Check | Result |
|---|---|
| Branch / working tree | `feature/lms-phase-2k-staging-discovery`, clean |
| Container | running, **healthy** |
| Public base tables | **0** |
| Role configuration | **matches** the verified fresh-stack baseline |
| Backup checksums | all three **MATCH** section 2O |

| Field | Value |
|---|---|
| `RESTORE_START_UTC` | `2026-08-27T22:20:39Z` |
| `RESTORE_START_EPOCH` | `1787869239` |

#### Per-file outcome

| Order | File | Role | Start (UTC) | End (UTC) | Exit | Outcome |
|---|---|---|---|---|---|---|
| 1 | `roles.sql` | `supabase_admin` | 22:20:52Z | 22:20:52Z | `0` | **SUCCESS** |
| 2 | `schema.sql` | `postgres` | 22:20:52Z | 22:20:53Z | `0` | **SUCCESS** |
| 3 | `data.sql` | `postgres` | 22:20:53Z | 22:20:53Z | `3` | **FAILED** |

**The `supabase_admin` fix worked.** `roles.sql` — which previously failed on
`GRANT SET ON PARAMETER "log_min_messages"` — applied cleanly under a superuser context. That
correction is now demonstrated, not merely reasoned.

Sanitized error, complete; it contains no credential, host, or connection detail:

```
ERROR:  permission denied for table buckets_vectors
```

Execution stopped immediately. No retry, no dump edited, no trigger disabled, no constraint
dropped, no warning waived.

#### Schema restore succeeded — objects now present

| Measure | Local, after `schema.sql` |
|---|---|
| `public` base tables | **12** |
| `public` functions | **41** |

Twelve public base tables matches the count recorded for staging in section 3. This is a
promising signal but **not** verification — that is Step 8's job and it has not been run.

#### Diagnosis of the `data.sql` failure

The same class of problem as the roles failure: a **platform-managed schema requiring a role
`postgres` does not have locally.**

| Fact | Value |
|---|---|
| Failing object | `storage.buckets_vectors` |
| Owner | `supabase_storage_admin` |
| `postgres` has `INSERT`? | **no** (`f`) |

`data.sql` issues `COPY` into three schemas — `auth`, `public` and `storage` — because the
data-mode dump excludes neither `auth` nor `storage` (recorded in section 2D). The `storage`
targets include `buckets`, `buckets_analytics`, `buckets_vectors`, `objects`, `s3_multipart…`
and `vector_indexes`, all owned by `supabase_storage_admin`. Running the file as `postgres`
therefore fails at the first `storage` table it reaches.

Note this is a **permission failure, not a data failure**. Staging holds zero rows in every
counted table, so these `COPY` statements carry no rows; the error is the permission check on
an empty copy into a platform-managed table.

The `fixture_result_overrides` circular foreign-key warning from section 2O was **not**
reached and remains untested.

#### State after the stop

| Item | State |
|---|---|
| Roles + schema | applied |
| Data | **not applied** |
| Container | running, healthy |
| Backup artifacts | **unaltered** — sizes, permissions and SHA-256 still match section 2O |
| Four directories | intact |

**No RTO is calculated.** The window opened at `RESTORE_START_UTC` remains open: by the
runbook, it closes only after Step 8 verification, and in any case the restore is incomplete.

#### Resolution adopted — `data.sql` runs as `supabase_admin`

Three options were considered: run the file as `supabase_admin`; split it so `storage` restores
under `supabase_storage_admin`; or narrow the demonstration to `auth` and `public` only.

**Option 1 is adopted.** Options 2 and 3 both require dividing or reducing the artifact, which
the runbook prohibits — and option 3 would additionally weaken what "the backup restores" means
while appearing to pass.

The decisive fact is that `data.sql` is **one intact logical artifact spanning three schemas**,
confirmed by inspection:

| Schema | `COPY` sections | Ownership |
|---|---:|---|
| `auth` | 22 | platform-owned |
| `public` | 12 | application-owned |
| `storage` | 7 | owned by `supabase_storage_admin` |
| **total** | **41** | — |

No single non-superuser role can write to all three. `postgres` is not a superuser locally and
holds no `INSERT` on `storage` tables, which is exactly where it failed.

**Using `supabase_admin` for `COPY` does not alter table ownership.** `COPY … FROM` inserts
rows; it does not reassign owners. Verified from the artifact: `data.sql` contains **zero**
`SET SESSION AUTHORIZATION`, `SET ROLE`, `OWNER TO`, and `ALTER TABLE … OWNER` statements.
Ownership remains whatever `schema.sql` established under `postgres`.

#### Security boundary — recorded honestly

Adopting this means two of the three restore commands run as a **local superuser**. That is a
genuine concession and is recorded as such rather than presented as routine. It is bounded by
three safeguards, all of which must hold:

| Safeguard | What it bounds |
|---|---|
| Disposable local stack | The credential exists only in a throwaway container, destroyed and recreated between attempts, with no reach to staging or production |
| Immutable dump | Checksum-verified before every run and never edited — the superuser executes known content, not arbitrary input |
| Fixed `psql` command | One file, `ON_ERROR_STOP=1`, no interactive session, no ad-hoc SQL |

Remove any one and the justification fails. In particular, a superuser context must never be
used to run a dump that has been edited, split, or hand-assembled.

#### Before any retry

The stack is **no longer clean**: `roles.sql` and `schema.sql` applied, leaving 12 public base
tables and 41 public functions. Unlike the earlier `rolconfig` case, this is a real, observable
divergence from a fresh stack — a retry into it would not be a valid demonstration.

The retry sequence is therefore:

1. Stop and recreate the local stack.
2. Re-run the Step 6 cleanliness checks — zero public base tables **and** `rolconfig` matching
   the verified fresh-stack baseline.
3. Only then open a **new** RTO window with a fresh `RESTORE_START_UTC` / `RESTORE_START_EPOCH`.
   The window from this attempt is discarded, not reused, and no RTO is claimed from it.
4. Restore in order: `roles.sql` as `supabase_admin`, `schema.sql` as `postgres`, `data.sql` as
   `supabase_admin` — each separately, each with `ON_ERROR_STOP=1`, stopping at the first error.

The `fixture_result_overrides` circular foreign-key warning recorded in section 2O remains
**open and untested**. `data.sql` has never executed past its first `storage` target, so that
warning has still not been exercised and must not be treated as cleared.

No dump has been edited, split or narrowed, no error waived, and the backup artifacts are
unaltered.

The retry was subsequently executed — see section 2T.

### 2T. Step 7 — RESTORE SUCCEEDED, all three files applied

The corrected Step 7 ran against a freshly recreated stack. **All three files applied cleanly.**
Staging and production were not contacted.

#### Preconditions (all passed before the window opened)

| Check | Result |
|---|---|
| Branch / working tree | `feature/lms-phase-2k-staging-discovery`, clean |
| Backup checksums | all three **MATCH** section 2O |
| Diverged stack stopped | `stop --no-backup` — 12 tables discarded with it |
| Stack recreated | committed Step 6 command, `mailpit` excluded, exit `0` |
| Container | running, **healthy**, created 2026-08-27T22:34:11Z |
| Public base tables | **0** |
| Role configuration | **matches** the verified fresh-stack baseline |

| Field | Value |
|---|---|
| `RESTORE_START_UTC` | `2026-08-27T22:35:03Z` |
| `RESTORE_START_EPOCH` | `1787870104` |

#### Per-file outcome — all successful

| Order | File | Role | Start (UTC) | End (UTC) | Exit | Outcome |
|---|---|---|---|---|---|---|
| 1 | `roles.sql` | `supabase_admin` | 22:35:04Z | 22:35:04Z | `0` | **SUCCESS** |
| 2 | `schema.sql` | `postgres` | 22:35:04Z | 22:35:04Z | `0` | **SUCCESS** |
| 3 | `data.sql` (intact) | `supabase_admin` | 22:35:04Z | 22:35:04Z | `0` | **SUCCESS** |

Each ran separately with `ON_ERROR_STOP=1`. No dump was split, edited, narrowed or reassembled;
no trigger was disabled, no constraint dropped, and no warning waived. `data.sql` was applied
**whole**, including all 22 `auth`, 12 `public` and 7 `storage` `COPY` sections.

Both role-context corrections are now **demonstrated by execution**: `roles.sql` under
`supabase_admin` (previously failing on `GRANT SET ON PARAMETER`) and `data.sql` under
`supabase_admin` (previously failing on `storage.buckets_vectors`).

#### The circular foreign-key warning caused no restore error

The `fixture_result_overrides` circular foreign-key constraint reported at dump time
(section 2O) **did not produce any error during restore**. `data.sql` completed with exit `0`.

| Observation | Value |
|---|---|
| `public.fixture_result_overrides` present | yes |
| Foreign-key constraints on it | 3 |
| Rows | 0 |

The warning is therefore **resolved as a restore concern**: it was a `pg_dump` advisory about
ordering, and the restore encountered no resulting failure. Note this was exercised against a
table with **zero rows** — the constraint ordering was never stressed by actual data. It should
not be assumed harmless for a future restore of a populated database.

#### Restored objects

| Measure | Value |
|---|---|
| `public` base tables | **12** — matches the count recorded for staging in section 3 |
| `public` functions | **41** |
| `public` tables owned by `postgres` | **12 of 12** |

Ownership is intact: every public table is owned by `postgres`, established by `schema.sql`.
Running `data.sql` as `supabase_admin` did **not** reassign ownership, exactly as recorded — the
artifact contains no `SET SESSION AUTHORIZATION`, `SET ROLE`, or `OWNER TO` statements.

All 12 tables restored with 0 rows, consistent with staging holding no application data.

#### RTO window remains open

**No RTO is calculated.** By the runbook the window closes only after Step 8 verification, which
has not been run. `RESTORE_START_EPOCH=1787870104` stays open for that calculation.

Backup artifacts are unaltered, all four directories are intact, and the gate remains
`NOT READY` — the restore-demonstrated row is not checked until Step 8 verifies that what was
restored actually reproduces staging. Step 8 was subsequently executed — see section 2U.

### 2U. Step 8 — VERIFICATION PASSED, restore demonstrated

The restored local stack was compared against the recorded staging evidence. Staging and
production were not contacted; all queries were read-only.

> ## ⚠ CORRECTION — an unexplained mismatch exists
>
> An earlier revision of this section stated *"Every compared measure matches"* and *"No
> unexplained mismatch was found"*. **The second claim was wrong** and is retracted.
>
> Section 1 of the same, byte-identical discovery query returned **148 rows against staging**
> (recorded in section 3) and **206 rows against the restored copy** — a **58-row difference**.
> That is an unexplained mismatch, and the stated rule is that an unexplained mismatch is a
> failure, not something to reconcile by preference.
>
> It **cannot be resolved from the evidence**: staging's section 3 entry records a prose
> *summary*, not the 148 rows, so there are no per-section staging counts to compare against the
> restored breakdown (21 sentinels, 12 tables, 41 functions, 12 policies, 4 triggers, 26 table
> grants, 84 routine grants, 5 extensions, 1 cron = 206).
>
> The most likely locus is the dimension Step 8 explicitly did **not** compare numerically:
> **110 of the 206 restored rows are grant rows** (26 table + 84 routine), and grant/ACL drift is
> the central security concern of this whole discovery. Two candidate explanations — neither
> established — are that the local stack carries platform grants staging does not, and that
> `rls_auto_enable()`, recorded as staging drift with no repository source, may not exist on the
> restored copy at all.
>
> **What was actually verified is the nine measures in the table below**, all of which match.
> That is narrower than "the restore reproduces staging", and the gate row is worded accordingly.
>
> *(Superseded 2026-08-28: the re-run was performed and the discrepancy is **resolved** — the
> cause is understood and recorded in section 2W. It is a real ACL divergence, not a recording
> artefact. Statements above describing it as "unexplained", "unresolved", or "not yet done" are
> superseded; the cause is known but **not fixed**. The gate has been withdrawn to `NOT READY`.)*

#### Preconditions

| Check | Result |
|---|---|
| Container | running, **healthy** |
| Working tree | only the uncommitted evidence change |
| Backup checksums | all three **MATCH** section 2O |
| RTO window | existing window reused, **not** restarted — `RESTORE_START_UTC=2026-08-27T22:35:03Z`, epoch `1787870104` |

#### Section execution

The committed discovery SQL was split by the runbook's `awk`, producing exactly **three** files,
each containing one `begin;` / `commit;` pair and one `set transaction read only`.

| Section | Handling | Exit | Result |
|---|---|---|---|
| 1 — phase presence + inventory | `ON_ERROR_STOP=1` | `0` | 206 rows returned |
| 2 — migration ledger | deliberately **without** `ON_ERROR_STOP` | `0` | `ERROR: relation "supabase_migrations.schema_migrations" does not exist` → `ROLLBACK` |
| 3 — exact row counts | `ON_ERROR_STOP=1` | `0` | 8 rows, all `0` |

Section 2's error is the **expected divergence** recorded in recovery-envelope item 4: the
staging application migration ledger is excluded from both dumps and is therefore not restored.
It is reconciled against the Step 5 companion artifact, not against the restore. Running it
without `ON_ERROR_STOP` is what allowed section 3 to proceed.

#### Comparison against recorded staging evidence

| Measure | Staging (recorded) | Restored (observed) | Verdict |
|---|---|---|---|
| P1/P2 baseline sentinels | 3 present | 3 present | **MATCH** |
| Phase 1 and 2A–2J sentinels | ABSENT | ABSENT | **MATCH** |
| `public` base tables | 12 | 12 | **MATCH** |
| RLS enabled | all 12 | all 12 | **MATCH** |
| SELECT policies, all permissive | 12 | 12 | **MATCH** |
| Non-internal triggers, all enabled | 4 | 4 | **MATCH** |
| Extensions | 5 | 5 | **MATCH** |
| `pg_cron` | not installed | not installed | **MATCH** |
| Exact row counts (8 core tables) | all 0 | all 0 | **MATCH** |
| Migration ledger | 24 rows on staging | absent locally | **expected divergence** |

Extensions match by name and set: `pg_stat_statements`, `pgcrypto`, `plpgsql`,
`supabase_vault`, `uuid-ossp`. Table grants (26) and routine grants (84) were returned and are
available for the outstanding ACL review; the staging evidence recorded those as scope lists
rather than counts, so they are reported rather than compared numerically.

`public` functions restored: **41**. The staging inventory in section 3 did not record a
function count, so this is reported, not compared.

**Dimensions NOT compared**, and therefore not verified: table grants, routine grants, the
function inventory, policy `USING`/`WITH CHECK` expression text, and constraint definitions.
Staging's recorded evidence gives scope lists and prose for these rather than comparable values.
The 58-row discrepancy above almost certainly lives in this set.

No mismatch was reconciled by preferring one source over another. The one mismatch found is
recorded as open and unexplained rather than explained away.

#### The comparison baseline predates the dump

The staging figures compared here were recorded on **2026-08-26** (section 1 metadata, commit
`e69179c`), roughly **32 hours before** the dump completed at `2026-08-27T21:29:07Z`. Staging was
not contacted during Steps 6–8, so the restore is verified against a **pre-dump snapshot of the
source**, not against the source as it stood at the RPO instant.

Nothing re-establishes that staging was unchanged across that interval. In practice the risk is
low — every recorded staging interaction was read-only apart from two database-password resets,
and staging is empty — but that is reasoning, not evidence, and it is stated here rather than
left implicit.

#### Recovery objectives

| Objective | Value |
|---|---|
| **RPO** | `2026-08-27T21:29:07Z` — the dump completion timestamp from section 2O |
| `RESTORE_START_UTC` | `2026-08-27T22:35:03Z` (epoch `1787870104`) |
| `RESTORE_END_UTC` | `2026-08-27T22:51:06Z` (epoch `1787871066`) |
| **Measured window** | **962s** |

**It is not the runbook's RTO as defined.** The runbook defines RTO as *"local-stack startup plus
restore plus verification"* (Steps 6–8 together). This window **excludes stack startup** — the
stack was recreated at 22:34:11Z, before the window opened at 22:35:03Z. The runbook is itself
inconsistent here: it also requires `RESTORE_START` to be recorded only *after* the stack is
confirmed healthy and clean, which is the rule actually followed. The figure is therefore a
**restore+verify window**, not the Steps 6–8 RTO, and the two definitions cannot both be met.
The omission makes the number smaller, not larger. Where section 2V calls it "the measured
962-second RTO", read it as this restore+verify window.

**What 962s does and does not mean.** It is honest wall-clock for the window measured, but it is
dominated by operator/agent deliberation between commands, not by database work. The observed machine-time components were far smaller: stack recreation completed at
22:34:11Z (**before** this window opened, so it is not included), and all three restore files
applied within roughly **one second** at 22:35:04Z. The verification queries likewise returned in
under a second each.

962s is therefore an **upper bound on a supervised, step-by-step restore**, not a measure of how
long recovery takes. It should not be quoted as a recovery-time capability. A realistic
unattended figure would be a small number of minutes dominated by stack startup, and would need
separate measurement. It is also unrepresentative for a second reason: staging holds no data, so
neither restore nor verification was stressed by volume.

#### Circular foreign-key case — succeeded, but does not generalise

`data.sql` applied without error and `public.fixture_result_overrides` restored with its 3
foreign-key constraints intact. **This does not prove constraint ordering is safe for a
populated database.** The table held **zero rows**, so the circular reference was never
exercised by actual data. The dump-time warning is cleared for this artifact only; a restore of
a populated database must treat it as untested.

#### Gate movement

| Row | State |
|---|---|
| Exact target project named | ☑ |
| Backup mechanism identified | ☑ |
| Backup actually taken | ☑ |
| **Restore demonstrated** | ☑ **now satisfied** |
| **RPO / RTO expectations stated** | ☑ **now satisfied**, with the caveats above |
| Residual risk explicitly accepted | ☐ **remains open — operator decision** |

**Five of six rows are satisfied. The gate remains `NOT READY`** until residual risk is
explicitly accepted, which is not a step that can be executed — it is a judgement recorded by the
operator. No migration, deployment, secret or cron work has been performed or is authorized.

*(Superseded: residual risk was subsequently accepted — see section 2V. The gate is now `READY`,
scope-limited. This paragraph records the state at the time Step 8 completed.)*

### 2V. Residual risk accepted — gate `READY`, scope-limited

Recorded 2026-08-27. The operator explicitly accepted the residual risk for Phase 2K staging
recovery. This satisfies the sixth and final gate row.

**Provenance — operator attestation, not verifiable from the record.** Unlike the other five gate
rows, this one rests entirely on the operator's statement. It has no artifact behind it: no
dashboard URL as in 2B, no command and exit status as in 2C, no execution channel as in 2F. The
six risks below are recorded as the operator stated them, and they were then mapped by the agent
back to sections of this document — so the *wording* is the operator's and the *cross-references*
are derived. This is the maximum provenance a judgement-type row admits, but a reviewer relying
on `READY` should confirm the acceptance directly with the operator rather than from this file
alone.

#### Risks accepted, as stated by the operator

1. The demonstrated restore used an **empty staging dataset** and does not prove restoration of
   populated or circularly related data.
2. The restore was demonstrated into a **disposable local Supabase stack**, not as an in-place
   staging recovery.
3. Platform-wide roles and data required a **local superuser restore context**.
4. The backup is **plaintext at rest** and depends on local disk encryption, account security
   and owner-only permissions.
5. The measured **962-second RTO is a supervised upper bound dominated by manual delay**, not a
   production recovery capability.
6. The staging **migration ledger is retained as companion reconstruction evidence** and is not
   restored by the dump.

Each corresponds to a limitation established during execution rather than assumed: item 1 to the
zero-row circular-FK case in 2U; item 2 to recovery-envelope item 5; item 3 to the role-context
corrections in 2Q and 2S; item 4 to envelope item 8; item 5 to the RTO caveat in 2U; item 6 to
envelope item 4 and the Step 5 companion artifact.

#### Coverage against the recovery envelope — GAP, operator attention required

The runbook's evidence criterion for this gate row (`PHASE_2K_BACKUP_RESTORE_RUNBOOK.md`,
"Evidence to record") is *"operator sign-off naming every recovery-envelope item above"*. The
envelope has **eight** items; the operator named **six** risks. Mapping them honestly:

| Envelope item | Covered by |
|---|---|
| 1. Logical backup, not PITR | **not named** |
| 2. `auth`/`storage` excluded from schema dump; target must be a Supabase stack | **partial** — risk 2 covers "not in-place", not the schema-exclusion consequence |
| 3. `auth` row data included | **not named** |
| 4. Migration ledger excluded | risk 6 |
| 5. Restore demonstrated locally, not in-place | risk 2 |
| 6. Staging holds zero rows | risk 1 |
| 7. Role dumps use `--no-role-passwords` | **not named** |
| 8. Plaintext at rest | risk 4 |

The operator additionally accepted two risks that are **not** envelope items — the local
superuser restore context, and the 962s figure being a supervised upper bound. Nothing the
operator stated was omitted or softened; the gap runs the other way.

**Assessment of the unnamed items.** Two are materially unaddressed and are flagged for the
operator rather than assumed accepted:

- **Item 1 (logical backup, not PITR)** — anything written to staging after
  `2026-08-27T21:29:07Z` is unrecoverable from this artifact. Material.
- **Item 7 (`--no-role-passwords`)** — roles are recovered but their passwords are not, so
  anything depending on a role password must be re-established after a restore. Material.

The remaining two are lower consequence: item 3 records that `auth` data *is* captured, which is
a positive finding rather than a risk, and item 2's practical consequence — the restore target
must be a Supabase stack — was demonstrated rather than merely accepted.

**This gap does not retract the acceptance.** The gate row asks that residual risk be explicitly
accepted, and it was. But the runbook's stricter criterion is **not fully met as written**, and
that is recorded here rather than quietly ticked. Before staging work proceeds, the operator
should either extend the acceptance to items 1 and 7 explicitly, or record why they are
considered subsumed.

#### Scope of the acceptance — explicit limits

| Applies to | Does **not** apply to |
|---|---|
| Staging `evhiixndiuwwodsouyhf` | Production `enzdvsppduyqtpdeseyh` |
| That project **while it is empty** | That project once it holds material user data |

The acceptance **must be reassessed before staging contains material user data**. Three of the
six accepted risks — the empty dataset, the unexercised circular foreign key, and the
unrepresentative RTO — are conditional on staging being empty, and stop being acceptable once it
is not. Populating staging invalidates this acceptance and requires a fresh backup/restore
demonstration against data.

#### Gate state

| Row | State |
|---|---|
| Exact target project named | ☑ |
| Backup mechanism identified | ☑ |
| Backup actually taken | ☑ |
| Restore demonstrated | ☑ |
| RPO / RTO expectations stated | ☑ |
| Residual risk explicitly accepted | ☑ |

**BACKUP / RESTORE OPERATOR GATE: `READY`** — for staging `evhiixndiuwwodsouyhf` only, while
empty.

> **Superseded 2026-08-28:** the gate declared `READY` above has been **withdrawn**. The
> restore-demonstrated row is unchecked because the restore does not reproduce staging's ACL
> state — see section 2W. The operator's residual-risk acceptance recorded in this section
> stands on its own terms and is not retracted; it simply no longer completes the gate, because
> a different row is now unsatisfied. The envelope items 1 and 7 gaps recorded above also remain
> open.

#### What `READY` does and does not authorize

Clearing this gate removes the **backup/restore precondition** that has blocked Phase 2K
staging work. It is **not** blanket authorization.

Still required before any staging change:

- The exact migration sequence must be **separately reviewed and approved**. The draft in
  section 6 remains a draft.
- Outstanding items from discovery are unresolved and were never part of this gate: the
  function-by-function review of the `authenticated` SECURITY DEFINER RPC surface, the
  10-relation legacy ACL revocation decision, and the treatment of `rls_auto_enable()`.
- Edge Function deployment, secret configuration and cron creation each remain separately gated,
  as does enabling any automation flag.

Production remains entirely out of scope and untouched.

### 2W. Discrepancy RESOLVED — ACL divergence; `READY` withdrawn

Recorded 2026-08-28. The 148-vs-206 discrepancy opened in section 2U is **resolved**: its cause
is understood. It is **not fixed**, and no repair has been designed or applied.

#### Provenance of the staging re-run

| Field | Value |
|---|---|
| Query | Query 1 from `supabase/discovery/phase_2k_staging_discovery.sql`, **unchanged** since commit `e69179c` |
| Target | confirmed staging `evhiixndiuwwodsouyhf` |
| Scope | Query 1 only — Query 2 and Query 3 were not run |
| Mutation | none; the block is a single read-only transaction |
| Result artifact | complete output exported as CSV, held **outside the repository** with owner-only permissions |
| Repository | the raw CSV is **not committed**; only the derived counts below are recorded here |

#### Where the 58 rows are

Non-ACL sections match **exactly**:

| Section | Staging | Restored | Verdict |
|---|---:|---:|---|
| Phase presence | 21 | 21 | match |
| Tables + RLS | 12 | 12 | match |
| Functions | 41 | 41 | match |
| Policies | 12 | 12 | match |
| Triggers | 4 | 4 | match |
| Extensions | 5 | 5 | match |
| Cron | 1 | 1 | match |
| **non-ACL subtotal** | **96** | **96** | **match** |

The ACL sections do not:

| Section | Staging | Restored | Difference |
|---|---:|---:|---:|
| Table grants | 18 | 26 | **+8** |
| Routine grants | 34 | 84 | **+50** |
| **ACL subtotal** | **52** | **110** | **+58** |
| **TOTAL** | **148** | **206** | **+58** |

The entire gap is ACL. Both totals reconcile exactly against the fixed 96 non-ACL rows.

#### Cause

**Not an omission.** The schema dump does contain privilege statements — `schema.sql` carries
**67 `GRANT`** and **39 `REVOKE`** statements, including `REVOKE ALL ON FUNCTION` and
`GRANT … ON TABLE` forms. ACLs were dumped.

The failure is that those statements are **source-relative**. `pg_dump` emits the privileges
needed to reproduce the source's ACLs *starting from the defaults its own restore target is
assumed to have*. The fresh local Supabase stack applies **broader default privileges** when the
restored objects are created, and the dump's statements do not revoke privileges that the target
granted by default but the source never had. The result is additive: everything staging granted
is present, plus what the local baseline added and nothing removed.

That is why the divergence is **entirely in the direction of more privilege**, and why it is
concentrated in routine grants (+50), where default `EXECUTE` to `PUBLIC` applies to every
restored function.

#### Consequence — the restore is not demonstrated

Schema and data restoration **succeeded**. Object structure, function inventory, RLS posture,
policies, triggers, extensions and row counts all reproduce staging exactly.

**The security posture does not.** A restored copy holding 26 table grants where the source has
18, and 84 routine grants where the source has 34, is not a faithful reproduction — it is a more
permissive database. Recovering into such a copy would silently widen the attack surface, which
is precisely the class of defect this phase's ACL discovery exists to prevent.

The **restore-demonstrated gate row is unchecked** and the **gate returns to `NOT READY`**.

#### Still open, unchanged by this finding

- **Recovery-envelope item 1** (logical backup, not PITR) — not named in the acceptance.
- **Recovery-envelope item 7** (`--no-role-passwords`; role passwords not captured or restored)
  — not named in the acceptance.

Both remain open regardless of the ACL work.

#### Next design task — not started

An **explicit, complete ACL recovery mechanism that is independent of the target's default
privileges**. It must produce the source's exact privilege state on any target baseline rather
than assuming one, which means establishing a known ACL starting point rather than inheriting
whatever the target creates.

No repair SQL has been written or applied, no dump has been edited, and the restored stack has
not been mutated. Designing that mechanism is the next task and has **not** been started.

*(Superseded 2026-08-28: the mechanism was subsequently designed, generated, reviewed and applied
only to the disposable restored-local stack. See 2X. The historical finding and stop decision above
remain accurate for the time they were recorded.)*

### 2X. ACL recovery demonstrated on the disposable restored copy

Recorded 2026-08-28. Source: the refreshed 544-row staging capture produced by the amended query
with SHA-256 `0a83294ad9abbdf37cd7ac49e306f4696d9eb9a0c132708e1545f651e0e669d6`.
The owner-only source CSV remains outside the repository and has SHA-256
`7c3164fda5ed8e534a2a6e2cdd6b82386a1a9ab53f397c2b31fb917819ce829c`.

The first replacement artifact stopped in preflight because it incorrectly required the hosted
temporary role `cli_login_postgres` on the restored copy. Exit status was 3. No reset began, and
read-only captures immediately before and after were byte-identical. The role was not created and
the attempt was not retried. That artifact is superseded and retained with a `DO NOT APPLY` banner.

The corrected `_r2` artifact projects Section H to roles named by in-scope ACL, ownership and
default-privilege facts plus their upward membership closure. The full forensic capture remains
unchanged. Five downward-only hosted roles are recorded in the manifest rather than recreated:
`cli_login_postgres`, `supabase_etl_admin`, `supabase_read_only_user`,
`supabase_realtime_admin`, and `supabase_storage_admin`. The isolated harness passed 45/45 before
execution; after the parity-contract correction described below it passed 47/47.

#### Target confirmation and execution

- Target container: `supabase_db_last_man_standing`, ID prefix `9f12b8b163ba`, healthy, PostgreSQL
  image `17.6.1.165`.
- Connection: inside that container over its Unix-domain socket; database `postgres`; current user
  `supabase_admin`. No `PGHOST`, `PGSERVICE` or `DATABASE_URL` was set.
- Repository: clean at commit `9067680`; nothing was pushed.
- Immediate pre-run capture: 867 rows; SHA-256
  `002be19fe706f0dd86414aa50ffcc243acabfe2bd48fccf2b928eed418e719eb`.
- Artifact result: exit 0 and `COMMIT`.
- Preflight: 6 operative roles, 71 objects, 327 source edges, 6 default groups.
- In-transaction result: `reset complete`; `verify ok: 327 edges, 72 default rules, 5 approved
  provenance residual`.

No hosted database was an execution target. Staging was contacted only for the preceding read-only
capture; production was not contacted. The backup artifacts and SQL dumps were not changed.

#### Independent post-run verification

The amended capture was run again read-only against the repaired local copy: 545 rows, SHA-256
`7f4609e736c0c1ff5a3bcb3245c1fe216818430052f86d7414510a9ff0e9feaf`.
The first parity-check invocation reported only three section-J schema identities: staging-only
`supabase_migrations` and local-only `_realtime` / `supabase_functions`. All three are classified
`PLATFORM-MANAGED`; `public` remains the sole in-scope schema. The recovery contract has always
allowed this environment-specific platform set, so comparing those names was a checker defect,
not an ACL failure.

The checker now compares in-scope schema identities and classifications exactly, ignores only
properly classified platform-managed identities, and refuses any `UNCLASSIFIED` schema. Its two new
isolated assertions pass. Re-running it on the real captures reports:

- `MISSING 0`
- `EXTRA 0`
- `RESIDUAL 0`

The 322 target-only excess grants recorded in 2W are removed. Structure, data and effective ACL
state now reproduce staging within the declared recovery scope. The **restore-demonstrated** gate
row is therefore satisfied. This does not authorize migration or deployment, and it does not close
the two acceptance gaps below.

#### Gate after recovery

Five of six rows are satisfied. The gate remains **`NOT READY`** solely because the operator's 2V
acceptance did not explicitly cover:

1. recovery-envelope item 1 — this is a logical backup, not point-in-time recovery; and
2. recovery-envelope item 7 — role passwords are not captured or restored.

The six risks already accepted in 2V remain accepted; they are not retracted or silently expanded.

*(Superseded later on 2026-08-28: the operator explicitly accepted both remaining items in 2Y.
This paragraph preserves the gate state immediately after technical recovery and before that
operator decision.)*

### 2Y. Final recovery-envelope acceptance — gate `READY`, empty staging only

Recorded 2026-08-28 as operator attestation. After the successful restored-local ACL recovery and
independent parity verification in 2X, the operator made these two explicit decisions:

1. **Recovery-envelope item 1 accepted:** “I accept recovery-envelope item 1 for empty staging
   only.” The accepted limitation is that this is a logical backup at RPO
   `2026-08-27T21:29:07Z`, not point-in-time recovery; it cannot restore to an arbitrary later
   moment and changes after that recovery point could be lost.
2. **Recovery-envelope item 7 accepted:** “I accept recovery-envelope item 7 for empty staging
   only; database role passwords will be re-established separately if recovery requires them.”
   Role definitions are captured, but their passwords are not.

These attestations complete the two gaps deliberately left open in 2V. Together with the six risks
already accepted there, every recovery-envelope item is now explicitly covered and all six operator
gate rows are satisfied.

**BACKUP / RESTORE OPERATOR GATE: `READY`**, subject to all of these limits:

- staging project `evhiixndiuwwodsouyhf` only;
- only while staging remains empty and holds no material player data;
- not production `enzdvsppduyqtpdeseyh`;
- reassess after schema/tooling changes or before staging is populated; and
- this gate clears only the backup/restore precondition. It does not approve the draft migration
  sequence, Edge Functions, secrets, cron, automation flags, production deployment or the UI.

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
12. 20260824000400_lms_phase_2k_legacy_acl_hardening.sql
13. 20260824000500_lms_phase_2k_remove_orphan_rls_auto_enable.sql
14. 20260824000600_lms_phase_2k_ensure_profile_signup_trigger.sql

This is a draft catch-up sequence only. The unapplied migrations for 2B, 2C, 2E, 2F,
2G, 2H, 2I, and 2J have been defensively amended in the local working tree: each of the
13 affected new tables is fully revoked before any intended authenticated SELECT is
restored. The exact legacy corrective revocations are now designed and locally validated
(section 10); routine-drift treatment and the complete plan still require review. Nothing
in this list is authorized to run remotely.
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

**Current state (2026-08-28):** the backup/restore gate is `READY`, limited to empty staging
(sections 2X–2Y). The exact migration plan is still not approved. Therefore no migration, function
deployment, secret configuration or cron change is authorized.

## 9. Authenticated SECURITY DEFINER RPC review

Recorded 2026-08-28. This was a read-only function-by-function authorization review. No
migration was applied and neither staging nor production was contacted during the review.

### Review basis

- The restored staging copy exposes 32 routines to `authenticated`. Catalogue inspection found
  all 32 to be `SECURITY DEFINER`, owned by `postgres`, with an empty fixed `search_path`.
- The effective current grants are exactly 32 for `authenticated` and 32 for `postgres`; no
  current routine in this RPC set is executable by `anon` or `PUBLIC`.
- Migration source for Phase 1 and 2A–2J was then reviewed to cover the intended post-catch-up
  surface, including renamed wrappers and internal helpers. Base implementations, trigger
  routines and service-role-only provider routines are explicitly revoked from
  `authenticated`.
- The conclusion below is a source-and-catalogue authorization review. It does not claim that
  every business-rule branch has been exercised by runtime tests.

### Function-by-function classification

| Function | Intended authenticated path | Authorization finding |
|---|---|---|
| `add_player_to_pot(uuid,uuid)` | admin | Calls `is_current_user_admin()` before mutation |
| `assign_random_missing_picks(uuid,integer,boolean)` | admin | Admin-gated wrapper |
| `claim_buy_back(uuid)` | player self-service | Uses `auth.uid()`, membership, state and deadline checks |
| `claim_pot_payment(uuid)` | player self-service | Updates only the caller's membership after eligibility checks |
| `complete_pot_with_winner(uuid,uuid)` | disabled compatibility RPC | Current implementation is admin-gated; Phase 2G replacement always refuses manual completion |
| `confirm_buy_back(uuid,uuid)` | admin | Admin check precedes player mutation |
| `confirm_team_pick(uuid,bigint,bigint)` | player self-service | Caller membership, payment, approval, deadline, fixture and duplicate checks |
| `create_fixture_result_override(bigint,integer,integer,text,text,text)` | admin | Admin check precedes validation, locks, mutation and audit writes |
| `create_pot(text,text,integer,integer,integer[],uuid[])` | admin | Admin check precedes creation |
| `delete_draft_pot(uuid,text)` | admin | Admin-gated destructive operation |
| `fill_remaining_pot_gameweeks(uuid)` | admin | Admin-gated mutation |
| `get_admin_fixture_results(text)` | admin read | Refuses non-admin callers before returning data |
| `get_admin_pick_overview(uuid,integer)` | admin read | Refuses non-admin callers before returning player details |
| `get_gameweek_deadline(uuid,integer)` | member/admin read | Requires membership or admin status |
| `get_lms_automation_status(uuid)` | admin read | Returns admin data only for an admin; a non-admin receives `null` |
| `get_lms_operations_health()` | admin read | Returns operational data only for an admin; a non-admin receives `null` |
| `get_my_dashboard()` | player self read | Anchored to `auth.uid()` |
| `get_my_pot_history(uuid)` | player self/member read | Pot membership/admin gate; returned picks remain anchored to `auth.uid()` |
| `get_my_pot_review_state(uuid)` | member/admin read | Member view is caller-scoped; evidence and impact details are admin-only |
| `get_my_team_availability(uuid)` | player self/member read | Membership and caller checks |
| `get_p1_provenance_backfill_report()` | admin read | Refuses non-admin callers |
| `get_player_provider_notice()` | authenticated status read | Intentionally returns only a safe player-facing provider-delay notice |
| `get_pot_completion(uuid)` | member/admin read | Requires membership or admin status |
| `get_pot_rounds(uuid)` | member/admin read | Requires membership or admin status |
| `get_pot_selection(uuid)` | player self/member read | Membership and caller checks |
| `get_pot_standings(uuid)` | member/admin read | Requires membership/admin; non-admin fields and picks are conditionally hidden |
| `is_current_user_admin()` | authenticated identity probe | Returns a boolean derived from service role or the caller's profile; grants no authority itself |
| `preview_fixture_result_override(bigint,integer,integer,text,text)` | admin | Refuses non-admin callers before impact data is produced |
| `preview_lms_review_resolution(uuid,text,uuid[])` | admin | Refuses non-admin callers |
| `process_pot_gameweek(uuid,integer,boolean)` | admin | Each effective wrapper retains an admin gate before processing |
| `remove_player_from_pot(uuid,uuid)` | admin | Admin check precedes mutation |
| `reset_draft_test_pot(uuid)` | admin/test-only | Admin check and draft/test-mode restrictions retained through wrappers |
| `reset_test_gameweek(uuid,integer)` | admin/test-only | Admin-gated wrapper |
| `resolve_lms_review_case(uuid,text,text,text,uuid[])` | admin | Admin check, version token and locking precede mutation |
| `revoke_buy_back(uuid,uuid,text)` | admin | Admin check and mandatory reason precede mutation |
| `run_lms_pot_automation(uuid)` | admin | Refuses non-admin callers |
| `scan_lms_automation()` | admin | Refuses non-admin callers |
| `set_buy_back_decision(uuid,uuid,boolean)` | admin | Delegates approval to the admin-gated confirmation function and refuses revocation without reason |
| `set_fixture_selection_block(bigint,boolean,text)` | admin | Admin check and reason validation precede mutation and audit write |
| `set_player_approval(uuid,boolean)` | admin | Admin check precedes mutation |
| `set_pot_lifecycle(uuid,text)` | admin | Admin check precedes the lifecycle transition |
| `set_pot_player_payment(uuid,uuid,text)` | admin | Admin check precedes mutation |
| `set_pot_status(uuid,text)` | admin | Admin check precedes mutation |
| `set_pot_test_mode(uuid,boolean)` | admin | Admin check precedes mutation |
| `set_test_pick_scenario(uuid,bigint,text)` | admin/test-only | Admin and test-mode checks precede mutation |
| `sync_fpl_data(text,jsonb,jsonb)` | admin | Authenticated wrapper is admin-gated; service-role provider paths are separately revoked from `authenticated` |

### Result

**PASS, with two documented interface observations and no authorization blocker found.**

- `get_lms_automation_status()` and `get_lms_operations_health()` return `null` to a
  non-admin rather than raising an authorization error. They do not disclose protected data.
- `get_my_pot_history(uuid)` admits an administrator through its pot-access gate but still
  returns history for `auth.uid()`; this is a harmless functionality asymmetry, not an
  escalation or cross-player disclosure.

The outstanding function-by-function RPC-review item is therefore closed. This finding does
not approve the migration sequence and does not change the separate legacy table-ACL or
`rls_auto_enable()` decisions.

> **Superseded 2026-08-28:** the two separate decisions named above were subsequently completed
> and locally validated in sections 10 and 11. Migration approval remains separate.

## 10. Legacy table-ACL hardening design and local validation

Recorded 2026-08-28 under the operator-approved scope: design explicit corrective revocations
for the ten staging relations and require local testing before any staging application.

### Selected correction

The catalogue-backed staging capture contains 80 direct ACL rows for `anon` and
`authenticated` across the ten relations in Query 7:

- 72 unwanted rows: four privileges (`MAINTAIN`, `REFERENCES`, `TRIGGER`, `TRUNCATE`) on
  18 relation/grantee pairs;
- eight intended rows: `SELECT` for `authenticated` on `football_fixtures`,
  `football_team_form`, `football_teams`, `player_picks`, `pot_gameweeks`, `pot_players`,
  `pots` and `profiles`.

No direct table access is intended for `anon`. Neither API role requires direct access to
`pot_fixture_test_results` or `pot_gameweek_processes`. Repository UI calls and the original
setup SQL corroborate the eight authenticated `SELECT` grants.

Migration `20260824000400_lms_phase_2k_legacy_acl_hardening.sql` therefore revokes only the
four unwanted privilege types from their exact current grantees. It does not use a blanket
revocation and does not recreate policies or ownership. Its transaction fails closed if a
required relation or API role is absent, and its postconditions require:

- no non-`SELECT` direct privilege for either API role on the ten relations;
- all eight intended authenticated `SELECT` grants still effective;
- no authenticated `SELECT` on the two internal relations; and
- no direct privilege of any listed kind for `anon`.

### Disposable restored-copy test

The migration was applied only to local container `supabase_db_last_man_standing` as
`supabase_admin`.

| Check | Result |
|---|---|
| Relevant ACL rows before | 80 |
| First application | exit `0`, transaction committed, empty stderr |
| Relevant ACL rows after | 8 |
| Excess rows removed | 72 of 72 |
| Remaining rows | exactly the eight intended authenticated `SELECT` grants |
| Second application | exit `0`, empty stderr; same postcondition (idempotent) |

The local restored copy is now intentionally ACL-hardened and no longer represents the raw
post-restore ACL baseline. Backup artifacts were not changed. No staging or production contact
occurred and this test does **not** authorize remote application.

### Decision state

The ten-relation corrective design is **complete and locally validated**. Remote staging
application remains part of the separately reviewed exact migration plan. The remaining
discovery decision is treatment of `rls_auto_enable()`; completing it still will not itself
authorize migrations.

> **Superseded 2026-08-28:** the `rls_auto_enable()` decision named above is complete and
> locally validated in section 11. Migration approval remains separate.

## 11. Orphaned `rls_auto_enable()` review and removal design

**Superseded by section 13:** the staging schema dump and restored copy omitted the hosted
event-trigger registration. The first staging application proved that `ensure_rls` is registered
to this function on staging. The historical reasoning below is retained as the record of the
earlier evidence and is not the current conclusion.

Recorded 2026-08-28 under the operator-approved read-only review and subsequent approval to
design removal with fail-closed dependency checks and local testing.

### Finding

`public.rls_auto_enable()` is the function from Supabase's optional auto-enable-RLS example,
not unexplained platform internals. The documented feature requires a separately registered
`ensure_rls` event trigger. The staging backup contains the function but no `CREATE EVENT
TRIGGER` statement, and the restored catalogue likewise contains zero event triggers pointing
to it. The function is therefore orphaned and inactive.

Read-only catalogue inspection established:

- owner `postgres`, `SECURITY DEFINER`, return type `event_trigger`;
- fixed `search_path=pg_catalog` and default-derived `PUBLIC EXECUTE`;
- no extension ownership, event-trigger registration or dependent object;
- no repository migration intentionally creates it; and
- it is not an ordinary PostgREST RPC because of its event-trigger return type.

The source catches every `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` failure and logs it rather
than failing the creating DDL. It is therefore optional defence in depth, not a fail-closed RLS
guarantee. This repository already enables RLS explicitly in reviewed table migrations.

### Selected correction

Migration `20260824000500_lms_phase_2k_remove_orphan_rls_auto_enable.sql` removes the inactive
function instead of activating new database-wide DDL behaviour. Before removal it requires the
known owner, security mode, return type, fixed search path and characteristic source operations.
It refuses if an event trigger or any other object depends on the function. Absence is the
desired state, so a subsequent run is a no-op; the transaction verifies absence before commit.

### Disposable restored-copy test

| Check | Result |
|---|---|
| Function before | present |
| Registered event triggers before | 0 |
| First application | exit `0`, committed, empty stderr |
| Function after | absent |
| Second application | exit `0`, empty stderr; absence preserved |

The test ran only on `supabase_db_last_man_standing`, which was already intentionally modified
by the locally tested legacy ACL hardening. Backup artifacts were unchanged. No staging or
production contact occurred.

### Decision state

The `rls_auto_enable()` drift decision is **complete and locally validated**. Together with
sections 9 and 10, all three discovery items that remained after the backup/restore gate are now
resolved at design/local-test level. The exact catch-up sequence still requires separate review
and explicit approval before any staging application; production remains out of scope.

## 12. Complete local Phase 2K migration dress rehearsal

Recorded 2026-08-29 under explicit operator approval for a complete local-only rehearsal from a
freshly recreated restored stack. Staging and production were excluded and not contacted.

### Attempt 1 — stopped safely at migration 12

The stack was recreated, verified clean, and restored from the immutable backup. Migrations
1–11 applied, then `20260824000400_lms_phase_2k_legacy_acl_hardening.sql` refused its
postcondition. The raw logical restore had inherited the local platform's broader default DML
grants; 68 unexpected `INSERT`/`UPDATE`/`DELETE` rows and internal-table authenticated grants
remained.

This was not a defect in staging. It proved that the local rehearsal sequence had omitted the
already validated ACL-normalization artifact required to make a logical restore reproduce the
staging ACL baseline. The failed migration transaction rolled back. The entire disposable stack
was discarded; no retry occurred in place.

### Attempt 2 — ACL baseline corrected; signup-trigger gap exposed

A second fresh stack was restored and then normalized with
`phase_2k_acl_recovery_staging_7c3164fd_q0a83294a_r2.sql` before migration. The artifact
reported 327 effective edges, 72 default rules and five approved provenance residuals. All 13
then-current migrations passed.

The first executable verification stopped because inserting the synthetic local admin user did
not create a `public.profiles` row. Investigation established that the logical dump restores
`public.create_profile_for_new_user()` but excludes its trigger on platform-owned `auth.users`.
Manually inserting a profile would have hidden a recovery defect and was rejected.

Migration `20260824000600_lms_phase_2k_ensure_profile_signup_trigger.sql` was therefore added.
It fails closed on missing prerequisites or an unexpected same-name trigger, preserves an
existing correct enabled trigger, and creates it only when absent. A real synthetic signup then
created its profile successfully.

The same attempt's final default-privilege inspection also found that migration 12 cleaned all
current tables but left `postgres`'s four unsafe future-table defaults. Migration 12 was amended
to revoke `MAINTAIN`, `REFERENCES`, `TRIGGER` and `TRUNCATE` from `anon` and `authenticated` in
`postgres`-owned `public` table defaults, with a fail-closed postcondition. The platform-managed
`supabase_admin` defaults are explicitly outside that application-owner boundary.

Because two migrations changed, the passing patched-in-place state was not accepted as a full
rehearsal. The stack was discarded again.

### Attempt 3 — final exact sequence passed from fresh state

The final run used a third freshly initialized stack and the exact committed/draft sequence:

1. verify clean stack and role baseline;
2. restore intact `roles.sql`, `schema.sql` and `data.sql` in their proven role contexts;
3. apply the `_r2` ACL-normalization artifact;
4. apply all 14 migrations in section 6, in order, as `postgres`;
5. create one synthetic local admin through the actual `auth.users` signup trigger;
6. run all 11 Phase 1–2J transactional verification suites;
7. run the Phase 2I and Phase 2J two-session concurrency tests; and
8. run structural, RLS, ACL, default-privilege, trigger, sentinel and extension assertions.

| Check | Final result |
|---|---|
| Restore files | 3 of 3 PASS |
| ACL normalization | PASS: 327 edges, 72 default rules, 5 approved provenance residuals |
| Ordered migrations | 14 of 14 PASS |
| Transactional verification suites | 11 of 11 PASS |
| Phase 2I two-session automation race | PASS |
| Phase 2J two-session provider race | PASS |
| Public base/partitioned tables | 28 |
| Tables without RLS | 0 |
| Direct non-`SELECT` table ACLs for `PUBLIC`/`anon`/`authenticated` | 0 |
| Unsafe `postgres` future-table default edges | 0 |
| Expected migration sentinels missing | 0 |
| Signup trigger | present, enabled, correct function |
| `rls_auto_enable()` | absent |
| `pg_cron` | not installed |
| Final ACL capture | 819 rows; two runs byte-identical; SHA-256 `da1a05dbbcd0dc290023f7176cbec03709c6d81f4a37d6227437b63c95eecbad` |
| Error scan | no `ERROR:` or `FATAL:` in final-run error logs |
| Backup integrity after rehearsal | all three SHA-256 values still match section 2O |

The measured final execution window was `2026-08-29T09:26:11Z` to `09:27:06Z`, **55 seconds**.
It begins after the new stack was healthy and clean, so it includes restore, ACL normalization,
14 migrations, the signup fixture, all verification suites, both concurrency tests and final
assertions, but **excludes local stack startup**. It is a rehearsal duration, not a production
deployment or recovery-time guarantee; staging remains empty and the test hardware is local.

### Dress-rehearsal conclusion

**PASS.** The exact migration sequence is locally executable from a freshly restored and
ACL-normalized staging backup. The rehearsal authorizes no remote action. Staging application
still requires a separately approved remote run plan with an explicit target check, stop rules,
operator checkpoints and post-application verification. Production remains out of scope.

### Staging run-plan design

`PHASE_2K_STAGING_MIGRATION_RUNBOOK.md` now defines that remote plan. It is **designed but not
approved for execution**: repository identity, read-only staging confirmation, a fresh backup,
runner-history reconciliation and an exact 14-file dry run must all pass before a new explicit
mutation approval can be requested. No remote command was run while designing it.

## 10. Staging preflight and historical migration reconciliation

### Checkpoints A–C

The operator approved staging Checkpoints A–D only, explicitly withholding migration application
and all production contact. Repository identity initially passed at `6d14151`; a documentation-only
credential-scan correction was then committed as `51f243b76bff3cbf19ef877c5774277f5b86ef49`, and
Checkpoint A passed again there with a clean tree and the expected 14 pending migrations.

Read-only staging confirmation reproduced the recorded state:

- Query 1 returned 148 rows and its exported CSV was byte-identical to the prior staging capture
  (SHA-256 `ff44fba83bc0a05142d93fd8c264e2fd68813a65547e1dd677f00dc850534a47`);
- Query 2 returned the expected 24 versions ending at `20260822002400`;
- Query 3 returned eight zero row counts, and `auth.users` separately returned zero; and
- the authenticated CLI session could see staging, while no default linked project was configured.

A fresh backup completed successfully at
`/Users/grantmiller/Documents/LMS-Backups/lms-staging-backup.u05OQA`:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `roles.sql` | 370 | `168a95a9c745af5ed4679751f90419ac9dc434240a213b03e32a06d5664c2308` |
| `schema.sql` | 121177 | `d33f5d0cc0533c3c4a298fedc9a17e9fb3b134d2a37075d200810d545dafdd80` |
| `data.sql` | 13628 | `3b87ef6ec11cac20200dac2476439d7d46b6e8587c1bb09461c66eec96b81127` |

The backup window was `2026-08-29T11:26:02Z` to `11:26:12Z` (10 seconds), giving RPO
`2026-08-29T11:26:12Z`. All files are `600`; the directory is `700`. The known
`fixture_result_overrides` circular-foreign-key warning recurred without an error. The companion
24-row ledger is anchored to evidence source commit
`c2cccdce3c3bef2636aac725bb54021c42bb9247` and evidence SHA-256
`8ede09cc07793d7847c90ab3bdc61d875891379e869767ec4bcd0c60b26339b4`.

### Checkpoint D stop

`migration list` exited zero and showed exactly 24 remote-applied plus 14 local-pending versions.
The first `db push --dry-run --skip-vault` also exited zero but listed no migration because
`[db.migrations]` was disabled. A private temporary runner with migrations enabled then failed
closed with `LegacyDbPushMissingLocalError`: all 24 applied remote versions were absent from the
local migration directory. No migration repair, `--include-all`, remote mutation or workaround was
attempted. Checkpoint D therefore stopped.

### Historical reconciliation and local proof

The operator separately approved a local-only reconciliation. The 24 ledger names map one-to-one
to the 24 ordered SQL modules already retained under `supabase/`; every source file was unchanged
since its recorded implementation commit. Byte-identical versioned copies were added under
`supabase/migrations/`, preserving the documented result-corrections SHA-256
`7b4af55bf5f3e585fdd2f681cc645339694a7a82cef1e6da2d68d2596a38eccf`.
`[db.migrations]` was enabled, producing an ordered 38-file chain.

Fresh-stack execution exposed two integration assumptions that the restored-backup rehearsal had
masked:

1. the legacy ACL migration subtracted only four unsafe privileges and depended on prior ACL
   normalization; it now establishes the complete intended state by revoking all client-role table
   privileges, re-granting only the approved eight authenticated `SELECT` privileges, and removing
   all client-role future-table defaults owned by `postgres`; and
2. the signup-trigger migration compared formatting-sensitive `pg_get_triggerdef()` text; it now
   checks the function OID, enabled state and exact `AFTER INSERT FOR EACH ROW` catalogue bitmask.

The earlier dress-rehearsal statement that the ACL migration revokes only `MAINTAIN`,
`REFERENCES`, `TRIGGER` and `TRUNCATE` is superseded for the unapplied migration by this complete
known-state rule.

After those corrections, two separate fresh local stacks applied all 38 migrations successfully.
The first successful stack also passed:

- a real synthetic `auth.users` insertion through the signup trigger;
- all 11 transactional Phase 1–2J verification suites; and
- the Phase 2I and Phase 2J two-session concurrency races.

The final clean replay produced 38 ledger rows (`20260821000100` through `20260824000600`), 28
public base/partitioned tables with RLS enabled on all 28, zero `auth.users`, zero rows across the
eight core application tables, zero unsafe direct client ACLs, zero client-role `postgres` future
table defaults, the correct enabled signup trigger, no `rls_auto_enable()`, and no `pg_cron`.
Phase 2J intentionally creates one disabled-by-default `lms_operations_config` singleton and one
`lms_provider_state` singleton; those are configuration state, not player or competition data.

This reconciliation is locally proven only. The stopped Checkpoint D has not been repeated, no
migration has been applied remotely, and production was not contacted.

### Checkpoint D rerun after reconciliation

The preceding statement that Checkpoint D had not been repeated is superseded by this dated
rerun. The operator approved Checkpoints A and D against commit
`6df4fdfd9d5995ffa415b3489378321a38d49f74`, explicitly withholding migration application and
all production contact.

Checkpoint A passed with a clean tree, 38 total migration files, 14 pending files, migrations
enabled, and the 14 pending SHA-256 values recomputed. The owner-only Checkpoint D outputs are
retained outside the repository at
`/Users/grantmiller/Documents/LMS-Backups/phase-2k-staging-preflight-2026-08-29-r2`.

`migration list` exited zero and reconciled all 24 historical versions on both sides, followed by
exactly 14 local-only pending versions. `db push --dry-run --skip-vault` also exited zero and listed
exactly the 14-file payload in the staging runbook, in order, with zero seeds and zero roles. The
private output hashes are:

| Output | SHA-256 |
|---|---|
| `migration-list.txt` | `7293572f5e972e08954147043c1689e9f54064381d8c0086e18101c4090119ad` |
| `migration-list.err` | `b9977cb727ae28f6dfc5ee83a4ca928c7a9f42b11c4757f73dd5a17e85681a5f` |
| `db-push-dry-run.txt` | `d3ca1f3346f1c02228236f221d2e577eb65a88c39e5e418a70b9270aa171dd94` |
| `db-push-dry-run.err` | `9437e66f6681d4a2f033b7f1211129c981347f82d31edb373b73beed9b8abf40` |

Checkpoint D is now **PASS**. This is read-only preflight evidence, not migration approval: no
migration was applied, production was not contacted, and the runbook's separate Checkpoint E
operator approval remains absent.

## 13. Staging application stop and `ensure_rls` correction

Recorded 2026-08-29 under explicit approval to apply the exact 14-file staging payload at commit
`94178eb714636969d1b4f84d64e0f9d5ed973e25`, backed by RPO
`2026-08-29T11:26:12Z`. Production, Edge Functions, secrets, cron and git remotes remained out of
scope.

### Partial staging application

The pinned CLI connected to staging ref `evhiixndiuwwodsouyhf` and began applying the approved
payload without presenting an interactive confirmation prompt. Migrations
`20260823000100` through `20260824000400` applied in the expected order. Migration
`20260824000500_lms_phase_2k_remove_orphan_rls_auto_enable.sql` then failed closed before dropping
anything because an event trigger still used `public.rls_auto_enable()`. Migration
`20260824000600` was not attempted.

A read-only `migration list` after the stop confirmed 36 remote-applied versions: the original 24
plus the first 12 files of the approved payload. Exactly `20260824000500` and `20260824000600`
remain pending. This is a partial migration application, not a completed Phase 2K staging run.

### Read-only staging diagnosis

An operator-run SQL Editor query used an explicit read-only transaction and returned exactly one
registration for `public.rls_auto_enable()`:

| Field | Observed value |
|---|---|
| Event trigger | `ensure_rls` |
| Event | `ddl_command_end` |
| Enabled state | `O` (enabled) |
| Command tags | `CREATE TABLE`, `CREATE TABLE AS`, `SELECT INTO` |
| Function owner | `postgres` |
| Security definer | `true` |

The fresh pre-application schema backup contains the expected function definition but no event
trigger DDL. That omission caused the restored-copy review to classify the function as orphaned;
the live staging catalogue is authoritative for the hosted registration and disproves that
classification.

### Corrected migration and isolated local validation

The operator approved correcting migration `00500` locally before any staging retry. The migration
now verifies the known function definition and requires exactly one linked event trigger with the
observed name, event, enabled state and complete three-tag set. It refuses any mismatch. Only after
those checks pass does it drop `ensure_rls`, re-check for other dependencies, revoke client-role
function privileges and drop `public.rls_auto_enable()`. Its postcondition requires both objects to
be absent; already-absent state remains a safe no-op.

Validation used a uniquely named isolated PostgreSQL 17.6 container and a synthetic fixture matching
the staging registration:

| Check | Result |
|---|---|
| Exact staging-shaped fixture | created successfully |
| Corrected migration | committed successfully |
| Trigger after application | absent |
| Function after application | absent |
| Second application | committed; absence preserved |
| Deliberately disabled trigger | refused before removal |
| State after refusal | function present; trigger present and still disabled |

No staging retry occurred during correction or validation. The remaining two migrations require a
new explicit approval after review of this change. Production was not contacted.
