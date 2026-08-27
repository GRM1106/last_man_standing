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
- ☑ Backup mechanism identified: pinned Supabase CLI `2.116.0` logical dump
  (`roles.sql`, `schema.sql`, `data.sql`) plus the companion migration ledger
- ☑ Backup actually taken: completed 2026-08-27T21:29:07Z; see section 2O
- ☐ Restore **demonstrated** into a scratch database — an untested dump does not count
- ☐ Recovery point / recovery time expectations stated
- ☐ Residual risk explicitly accepted

Restore demonstration notes (what was restored, where, and what verified it):

```
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
