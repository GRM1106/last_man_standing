# Phase 2K — ACL Recovery Mechanism: Design Note

**An executable artifact HAS been generated and is under review. It has NEVER been applied
anywhere. See "Generated recovery implementation" and "Independent adversarial audit" below.
This note does not authorize its execution.**

> ## ⛔ NOT AUTHORIZED TO APPLY — artifact generated and audited, never executed
>
> **Read the third-round update at the end of this banner first: it supersedes the status below.**
> The three original mechanisms were disproven and have since been replaced by mechanisms proven
> experimentally. What remains blocked is authorization, not correctness. The history is kept in
> full because each superseded claim explains a defect that a future implementation could
> reintroduce.
>
> An adversarial review (2026-08-28, 50 agents, 18 confirmed findings) established that the core
> repair algorithm below **does not work as specified**. Verified directly on a disposable
> PostgreSQL 17.6 container built from the same image as the LMS stack:
>
> **1. `GRANT … GRANTED BY <grantor>` does not exist for object privileges (§6).** All forms fail
> with `ERROR: grantor must be current user`, including when run as the superuser
> `supabase_admin`. The "where available" branch of §6 is *never* available. Grantor preservation
> as designed is impossible by that route.
>
> **2. The §1 reset is grantor-blind and does not converge (§1, §4).** With an ACL containing
> `grantee_c=r/bystander`, a superuser `REVOKE ALL … FROM grantee_c` had **no effect**, and
> repeating it still had no effect. `REVOKE … GRANTED BY bystander` also failed with
> `grantor must be current user`. The claim that "reset must remove what it does not recognise"
> is **false as written** — a privilege granted by a third role survives the reset, so
> reset-then-grant does not remove all excess. The only mechanism observed to remove it was
> `REVOKE GRANT OPTION FOR … FROM bystander CASCADE`, which is a different algorithm than this
> note specifies.
>
> **3. Replay has no grantor-dependency ordering (§2, §8).** A chained grant requires the
> intermediate grantor to hold its grant option *before* the dependent grant is replayed, and the
> capture's total order (`object_identity`, then `grantee`) actively sorts them the wrong way
> when the dependent grantee sorts alphabetically first. Preflight as specified cannot detect it.
>
> **UPDATE 2026-08-28 — blocker RETAINED, but its reason has changed.** Isolated experiments
> (below, "Redesign experiments") **disproved blocker 2's stronger reading**: grantor-scoped
> removal *is* achievable, and a reset/replay algorithm was built that reproduces a full
> grantor-scoped ACL graph exactly, repeatably, and with clean rollback. Blocker 1 stands
> unchanged — `GRANT … GRANTED BY` remains unusable — but a working substitute was found.
>
> **UPDATE 2026-08-28 (second round) — blocker NARROWED.** Schema privileges and
> default-privilege rules have since been implemented and tested to the same standard (see
> "Schema and default-privilege experiments"). All required cases passed: exact parity including
> grantor, target-only excess removed, cycle broken, complete rollback, and probe objects created
> after replay inheriting the intended privileges.
>
> **UPDATE 2026-08-28 (third round) — blocker REDUCED TO AUTHORIZATION AND OUT-OF-SCOPE CLASSES.**
> All four remaining scope gaps were closed in one integrated design-validation cycle (below,
> "Integrated cross-class validation"). `pg_type.typacl` is now captured as section I; the
> system-column exclusion was **disproven experimentally** and the section C predicate widened to
> `attnum <> 0`; the vague "non-public schemas" gap was replaced by an explicit fail-closed scope
> contract that was shown to refuse; and all six classes were exercised together in a single
> atomic transaction against one database, proving seven properties including exact
> effective-security parity across 3,196 privilege probes.
>
> Verifying that work then surfaced a **fifth, previously unrecorded gap**: relation-backed row
> types can hold an explicit, enforced `typacl` that section I excludes. It is latent on the LMS
> stack (13 such types, none carrying an ACL) but it is a real hole, and it is listed below.
>
> **UPDATE 2026-08-28 (fourth round) — the row-type gap is CLOSED.** Section I now captures
> relation-backed row types. The backing relkinds were established exhaustively rather than
> assumed: `pg_class.reltype` is non-zero only for relkind `c, f, m, p, r, v`, so tables,
> partitioned tables, views, materialized views and foreign tables have row types while indexes,
> **sequences** and TOAST tables have none at all — a sequence has no row type rather than a
> suppressed one. All eight required behaviours were proven, the integrated recovery test was
> re-run with row types included, and the capture was re-validated twice against the untouched
> LMS stack. See "Relation-backed row types" below. One bounded consequence is recorded there and
> is provenance-only: a NULL `typacl` cannot be restored *as* NULL through SQL.
>
> Two further defects were found *by that cycle* and corrected before it passed. Both are recorded
> because each would have produced a repair that reported success while leaving the target wrong:
>
> * **`acldefault('S', …)` returns the FOREIGN SERVER default, not the sequence default.**
>   `pg_default_acl.defaclobjtype` spells sequences `'S'`; `acldefault()` spells them `'s'` and
>   uses `'S'` for foreign servers. Passing `defaclobjtype` straight through yields
>   `{owner=U/owner}` instead of `{owner=rwU/owner}`, and the rule can never reach its baseline.
> * **A default-privilege rule's "no row" baseline is scope-dependent.** It is
>   `acldefault(objtype, owner)` for an unscoped rule but the *empty ACL* for an `IN SCHEMA` rule.
>   Resetting by revoking only the recorded grants leaves an empty-ACL residue row, and an empty
>   row is **not** equivalent to no row — it suppresses the built-in default. Symmetrically, a
>   grant-only replay cannot reproduce a source rule that is a strict subset of the built-in
>   default (for example `FUNCTIONS` with `PUBLIC EXECUTE` revoked).
>
> **What the blocker still covers.** Not a broken mechanism, and not the capture:
>
> 1. **Execution is not authorized.** The artifact exists (generated 2026-08-28, audited, never
>    applied); this note does not approve running it.
> 2. **The algorithm has never run against a Supabase-hosted database.** Every result here comes
>    from disposable local containers built from the LMS stack's own image. Staging and production
>    were not contacted; the restored LMS stack was read from and never modified.
> 3. **Object classes outside the scope contract are unimplemented** — large objects, foreign-data
>    wrappers and servers, databases, tablespaces, languages, and configuration parameters. The
>    scope contract fails closed on anything it cannot classify, so these produce refusals rather
>    than silent passes.
> 4. **Row-level security is verified separately and is never represented as an ACL.**
>    "Effective-security parity" below means ACL parity, proven with `has_*_privilege`. RLS state
>    and policies are covered by their own artifacts — `supabase/discovery/phase_2k_staging_discovery.sql`
>    reports `relrowsecurity`, `relforcerowsecurity` and per-relation `pg_policy` counts and
>    enumerates the policies, and `supabase/verification/lms_integrity_phase_1_verification.sql`
>    asserts RLS is enabled on `player_picks` and `pot_gameweeks`. Two databases can pass every
>    check in *this* note and still differ in their policies.
>
> The remaining findings are recorded inline and in "Audit corrections" at the end.

This describes how a later recovery artifact would reproduce a source database's privilege state
on a target whose defaults differ. It is written to be reviewed *before* anything is generated,
because the defect it addresses was caused by trusting a generated artifact whose assumptions
were never stated.

## The problem this must solve

`PHASE_2K_DISCOVERY_EVIDENCE.md` section 2W records the failure. A logical restore reproduced
staging's schema and data exactly, but not its privileges:

| | Staging | Restored | |
|---|---:|---:|---|
| Table grants | 18 | 26 | +8 |
| Routine grants | 34 | 84 | +50 |

`schema.sql` was not missing its ACLs — it contains 67 `GRANT` and 39 `REVOKE` statements. Those
statements are **source-relative**: `pg_dump` emits what is needed starting from the defaults it
assumes the target has, and does not revoke what a different target grants by default. The result
composes rather than replaces:

```
target_actual  =  target_defaults  ∪  dump_grants        ⟵ what happens now
target_wanted  =  source_actual                          ⟵ what is required
```

**Scope of the observed evidence.** *This observed divergence was additive and toward more
privilege*, concentrated in routine grants where default `EXECUTE` to `PUBLIC` applies to every
restored function. That is what the 148-vs-206 comparison established — it is **not** a general
law. A target with narrower defaults than the source would diverge the other way, and this design
must not assume the error is one-directional.

**The fix is to stop assuming a baseline and start asserting one.**

## Source of truth

`supabase/discovery/phase_2k_acl_capture.sql` — strictly read-only, nine text columns per row
across eight sections: schema, relation, column, routine privileges; ownership; default-privilege
rules; observed grantees; role security context.

Properties that matter to this design:

- **Routines are identified by schema, name and identity arguments**; columns by
  `schema.table.column`. Never OIDs, never `information_schema.specific_name`, whose numeric
  suffix differs between environments.
- **`acl_source` distinguishes `explicit` from `default-derived`.** A NULL ACL means the built-in
  defaults apply, not that no privileges exist.
- **Column ACLs are never reconstructed.** A NULL `attacl` means no column-specific grants exist;
  there are no column defaults to derive.
- **Role security context is captured** because a privilege's real reach depends on membership
  and inheritance. **No secrets**: `pg_authid` is never read and `rolpassword` never selected.

## How the recovery artifact would work

### 1. Reset each audited object to a known baseline

Rather than assume the target's starting privileges, **assert** them.

Two different enumerations are involved, and conflating them is the trap:

| Question | Answered by |
|---|---|
| *Which objects must exist and be reset?* | the **source** capture's ownership section (E) |
| *Which grantees must be revoked from each object?* | the **target's own current ACL**, read at repair time |

**The revoke list must come from the target, not the source.** For each object, the repair
inspects that object's current ACL on the target and revokes **every** edge it finds — including
the owner's own aclitems, and including grantees that appear nowhere in the source capture.

> **Finding 10 is CLOSED, and the paragraph above was corrected with it.** An earlier draft
> exempted the owner, which made the target's floor the owner's full default rights and left a
> deliberately empty ACL unreproducible. The implementation exempts nobody: on the LMS workload the
> reset issues 625 revokes, i.e. every edge, 156 of them the owner's own. Section E's distinction
> between `acl empty: no privileges` and `acl null: defaults apply` is honoured — an `empty` source
> ACL is reproduced exactly when the target holds one, though it cannot be reached from a NULL
> target (see "Remaining gaps").

**Source-only grantee enumeration is insufficient**, and this is the crux of the whole design. A
grantee the target holds but the source does not will never appear in the source capture, so a
reset driven by source grantees cannot revoke it. That excess is exactly the 2W defect: the
restored copy held privileges the source never had. Reset must remove what it does not recognise,
not merely what it was told about.

Source ownership still drives the object list, because a privilege query alone cannot enumerate
objects: an object whose ACL is empty produces no privilege rows at all. Section E lists every
object unconditionally, so nothing is skipped.

The reset covers the schema itself, relations, columns, routines, **and default-privilege
rules** (§5).

### 2. Re-grant exactly the captured privileges

Replay the capture's rows: grantee, privilege type, and `WITH GRANT OPTION` where `is_grantable`
is true. `PUBLIC` is a real grantee and must be reproduced as such.

**Decision — `default-derived` rows are replayed explicitly.** This is now settled, not open:

- Every current-object privilege in the capture is granted explicitly by the artifact, whether the
  source held it explicitly or derived it from defaults.
- This removes all dependence on the target's defaults, which is the entire point.
- **Consequence, recorded deliberately:** `acl_source` will differ for those rows after recovery.
  A privilege that read `default-derived` at the source will read `explicit` at the target,
  because it is now stored in the object's ACL rather than implied by a NULL ACL.

That difference is **intentional and provenance-only**. It changes how a privilege is recorded,
not who holds it. It is pre-approved under the provenance-parity contract in §7.

### 3. Never change ownership

The artifact issues no `ALTER … OWNER`, no `REASSIGN OWNED`, and no `SET SESSION AUTHORIZATION`.

Ownership is captured to be **verified**, not modified. An owner mismatch is a stop condition
(the §6 stop-condition table), not something to correct silently — changing ownership alters who implicitly holds full
rights, a larger change than the drift being repaired.

### 4. Depend on no target default privileges

The artifact must be correct on a target with any default-privilege configuration:

- It never relies on an object arriving with useful defaults.
- It never relies on defaults being absent.
- Every privilege the source has is granted explicitly.
- Every privilege the source lacks is revoked explicitly, whether or not the target granted it.

Reset-then-grant delivers this. Grant-only cannot: it has no way to remove what it did not add,
which is the 2W failure.

### 5. Default-privilege rules are reset and reproduced exactly

Section F is **in scope for verification**, not excluded from it. The target's existing
`ALTER DEFAULT PRIVILEGES` rules are reset, and the source's rules are reproduced exactly.

**The same target-side enumeration rule as §1 applies here.** The rules to remove are enumerated
from the **target's own `pg_default_acl`**, not from the source capture. A default-privilege rule
the target has and the source does not would otherwise survive the repair untouched — and it is
precisely such a rule that produced the 2W divergence in the first place. Rules absent from the
source are removed; rules present in the source are reproduced exactly, including their
`defaclrole`, grantee, privilege set and grantability.

This matters beyond tidiness. Leaving a target rule in place would re-introduce excess privileges
on any object created *after* recovery, so a target that verified clean immediately would drift
again on the next migration — a repair that appears to work and silently stops working.

### 6. Grantor identity is preserved by a controlled grantor context

The grantor is part of the privilege's identity: it determines who may later revoke it, and
`REVOKE` issued by the wrong role silently does nothing.

**Mechanism.** Privileges are replayed under a controlled grantor context — `GRANT … GRANTED BY
<recorded grantor>` where available, falling back to a scoped role context established *only*
around privilege replay. Constraints:

- The controlled context applies to **privilege replay only**. It never spans object creation or
  alteration, so it cannot change ownership (§3).
- It is established and released within the single transaction of §8.
- **If the recorded grantor cannot be reproduced — the role is absent, or the executing role
  cannot legitimately act as it — the artifact fails closed and rolls back.** It does not
  substitute a different grantor, and it does not fall back to the executing role. A privilege
  recorded as granted by one role but installed as granted by another is a provenance difference
  that is *not* pre-approved, because it changes who can revoke it later.

### 7. Verification — two explicit contracts

Whole-output byte-equality is **not achievable** and is not the rule. §2 deliberately changes
`acl_source` for replayed default-derived rows, so a naive full-output diff would always fail and
would train reviewers to ignore it. Two contracts replace it:

**Contract 1 — effective-security parity. Must match exactly. Any difference is a failure.**

The parity key is **`section` + `object_kind` + `object_identity` + `grantee` + `privilege_type`**.
Both `section` and `object_kind` are part of the key explicitly: without them, a column privilege
on `public.pots.status` and a relation privilege could collide in comparison, and a row that moved
between sections — say a privilege that became default-derived rather than explicit on a
different object kind — would diff as equal when it is not.

| Field | Why it is security-relevant |
|---|---|
| **section** | which catalogue dimension the privilege lives in; part of the key |
| **object_kind** | table vs column vs routine changes what the privilege permits; part of the key |
| object identity | which object is exposed |
| owner | who implicitly holds full rights |
| grantee | who holds the privilege |
| privilege type | what they may do |
| is_grantable | whether they may pass it on |
| default-privilege rules (section F) | what future objects will expose |
| role existence, attributes, membership, inheritance (section H) | the real reach of every grant, including `admin_option`, `inherit_option` and `set_option` |

**Contract 2 — provenance parity. Must match exactly *or* be a specifically documented,
pre-approved difference.**

| Field | Pre-approved difference |
|---|---|
| `acl_source` (sections A–D) | `default-derived` → `explicit` for current-object privileges replayed under §2 |
| `acl_source` (section E) | `ownership (acl null: defaults apply)` → `ownership`, for the **same** objects. This is a necessary consequence of the first: a `default-derived` A–D row exists only because the object's ACL is NULL, and replaying it explicitly makes that ACL non-NULL, which changes section E's annotation for that object. Omitting it made Contract 2 self-contradictory — any run exercising the pre-approved difference was forced to roll back |
| grantor | **none pre-approved** — see §6; a grantor mismatch is a failure |

Both `acl_source` differences are pre-approved **only for objects whose A–D rows were
`default-derived` at the source**. Any other `acl_source` change, on any other object, is a
failure.

Anything not in that table is a failure, including any `acl_source` change other than the one
named. "Pre-approved" means enumerated in this note before the run, not judged afterwards.

**Method.** Re-run `phase_2k_acl_capture.sql` against the repaired target and diff against the
source capture, section by section. Contract 1 fields are compared for exact equality. Contract 2
fields are compared, and every difference must match the pre-approved table. Row-count equality is
insufficient — the full row sets are diffed. This is why the output contract is fixed, fully
text-cast and totally ordered.

### 8. Transactional execution

The repair runs as one transaction. Nothing is left half-applied:

```
begin
  acquire scoped advisory lock          -- pg_advisory_xact_lock, released on commit/rollback
  run all preflight checks (§6 table)   -- before any change
  reset privileges and default rules    -- §1, §5
  replay privileges and default rules   -- §2, §5, §6
  verify parity                         -- §7, both contracts, inside the transaction
commit  -- only if every check and both contracts pass
rollback -- otherwise, completely
```

Points that are not negotiable:

- **The advisory lock is transaction-scoped**, so a crash cannot strand it, and it prevents two
  concurrent repairs interleaving resets and grants.
- **Preflight runs before the first reset**, so a failure cannot leave the target in a state that
  is neither the source's nor its own. The 2Q failure — a partial `roles.sql` that committed three
  statements before erroring — is the precedent.
- **Verification runs inside the transaction, before commit.** Verifying after commit would mean
  discovering a bad state that is already permanent.
- Any failure at any stage rolls back **completely**. There is no partial success.

### 9. Idempotence

Running it twice leaves the same state as running it once; running it against an already-correct
target is a no-op in effect.

Reset-then-grant is naturally idempotent: the reset drives to a known baseline from any starting
point, and the grants are absolute assertions rather than deltas. The artifact contains no "if not
already granted" conditionals — those reintroduce dependence on the starting state.

### 10. The capture must be whole

The artifact is generated from a complete, unmodified capture. Editing, truncating, splitting or
hand-assembling a capture is prohibited, and a repair generated from one must not be run. This
mirrors the rule already enforced for the dump itself: restored whole, or the attempt is recorded
as failed. A superuser-context repair driven by hand-edited input is precisely the combination the
runbook's security boundary rules out.

## Security-relevant vs provenance-only differences

| Difference | Class | Consequence |
|---|---|---|
| Grantee gains or loses a privilege | **security** | fails Contract 1 |
| `is_grantable` differs | **security** | fails Contract 1 — changes who may re-grant |
| Owner differs | **security** | fails Contract 1 and preflight |
| Default-privilege rule differs | **security** | fails Contract 1 — future objects diverge |
| Role absent, or membership/inheritance differs | **security** | fails Contract 1 — changes reach |
| Column privilege differs | **security** | fails Contract 1 |
| `acl_source` `default-derived` → `explicit` for replayed rows | provenance-only, **pre-approved** | expected under §2 |
| Grantor differs | **security-adjacent, NOT pre-approved** | fails Contract 2 — determines who can revoke |

Grantor is listed as security-adjacent deliberately: it grants no additional access by itself, but
it controls revocability, so treating it as cosmetic would leave privileges that cannot later be
removed by the expected role.

## What this design does not do

- It does not restore role passwords. Recovery-envelope item 7 (`--no-role-passwords`) is a
  separate, still-open gap, and the capture deliberately reads no secrets.
- It does not create or alter roles. Missing roles are a stop condition.
- It covers schema `public` only, **with one exception**: the capture's section F also reports
  default-privilege rules with `defaclnamespace = 0`, labelled `(all schemas)`, which apply
  database-wide. §5 instructs that such rules be reset and reproduced, so the design's blast
  radius is wider than `public` and the earlier flat "public only" statement was inaccurate.
  Other schemas' object privileges, large objects, tablespaces, foreign data wrappers and
  databases remain out of scope; extending scope requires extending the capture **first**.
- It does **not** capture `pg_type.typacl`. Privileges on TYPEs and DOMAINs are invisible to the
  capture even though section F reports `future type` rules, and a NULL `typacl` confers `USAGE`
  to `PUBLIC` — so a source that revoked it cannot be distinguished from one that did not.
- It is not a substitute for verifying schema and data, which section 2U covers.

## Capture validation — local stack only, 2026-08-28

> **SUPERSEDED — historical snapshot.** The figures in this section (837 rows; E 58; F 96; no
> sections I or J; 99,975 bytes) describe the capture query as it stood *before* row types,
> type privileges and the schema-scope section were added. They are internally consistent for that
> version and are kept as a record. Current measurements are 867 rows, E 71, F 102, sections A–J —
> see "Relation-backed row types" and "Staging vs restored-local comparison".

The capture was executed **against the restored local PostgreSQL 17.6 stack only**
(`supabase_db_last_man_standing`). Staging and production were not contacted. Only structural
counts and outcomes are recorded here; the raw CSV is held outside the repository at `700`/`600`
and is not committed.

| Check | Result |
|---|---|
| Exit status, both runs | `0`, empty stderr |
| Determinism | two runs **byte-identical** (99,975 bytes, matching SHA-256) |
| Columns | exactly **9**, header as specified |
| Rows | **837** |
| Ordering | re-sorting by `1,3,5,7,2,4,6,8,9` reproduces file order exactly |
| Routine identities | 166 rows, all identity-argument form, **zero** OID suffixes |
| Secrets | zero matches for password/passwd/secret/token/hash/md5/scram/`sbp_`/`eyJ` |
| Expected roles | `anon`, `authenticated`, `service_role` present in **G and H**; `PUBLIC` present in **G only** — it is excluded from the role closure by construction, so it cannot appear in H. The earlier claim that all four appear in both was wrong. |
| Membership controls | 25/25 rows carry grantor, `admin_option`, `inherit_option`, `set_option` |
| Closure integrity | 20 roles closed, 25 edges, 18 distinct endpoints — **all inside the closed set** |
| `PUBLIC` handling | absent from the closed role set, as a pseudo-grantee should be |
| Grantee resolvability | every A–D grantee is `PUBLIC` or a member of the closed set |

Section counts: A 7 · B 452 · C **0** · D 166 · E 58 · F 96 · G 10 · H 48.

### Section C returned zero rows on the LMS stack — correctly

`public` on the restored LMS stack has **0** columns with a non-null `attacl`, while 17 columns
elsewhere in that database do. The catalogue column is populated and readable; there are simply no
column-level grants in `public`, so section C emitting nothing is the designed behaviour.

That left the column-privilege path **unexercised**, which is not the same as proven. It was
therefore validated separately, below.

## Section C validation — synthetic container, 2026-08-28

Validated in a **separate, uniquely named, disposable PostgreSQL 17.6 container**
(`pg17-aclc-validate`, own volume, synthetic credentials and data only). The restored LMS stack
was neither used nor modified. The capture ran **unmodified** — same file, same checksum.

Synthetic fixture: roles `anon`/`authenticated`/`service_role` (created only where absent, since
the Supabase image already ships them), one table `public.synthetic_widget` with four columns, a
column `SELECT` for `anon` on one column, and a column `UPDATE` **with grant option** for
`authenticated` on another — deliberately exercising both grantability states. Two columns were
left with a NULL `attacl` to prove they are not invented.

| Check | Result |
|---|---|
| Exit status, both runs | `0`, empty stderr |
| Determinism | two runs **byte-identical**, 23,019 bytes |
| Columns | 9 |
| Section C appears | **yes — exactly 2 rows**, matching the 2 columns holding an `attacl` |
| Identity form | `public.synthetic_widget.public_label` / `.extra_col` — **no OID** |
| Owner / grantee / grantor | `postgres` / `anon` and `authenticated` / `postgres` — all correct |
| Privilege type | `SELECT` and `UPDATE` — correct per column |
| `acl_source` | `explicit` on both, as designed for column ACLs |
| Grantability | `false` and **`true`** — correctly differentiated |
| NULL-`attacl` columns | **not emitted** — no invented rows |

All 14 field-level assertions passed.

Section counts in the synthetic environment: A 7 · B 32 · **C 2** · D 0 · E 2 · F 96 · G 10 · H 42
(191 rows). Every section executed successfully. D is legitimately empty — the synthetic database
has no `public` routines — which additionally demonstrates that an empty section is an absence of
matching objects, not a failure.

Teardown: the throwaway container and its volume were removed by name-guarded commands that refuse
any other target; synthetic CSVs were deleted and none entered the repository. The LMS container
was confirmed **byte-identical to its pre-test baseline** — same container ID, same
`StartedAt`, 12 tables, 41 functions, 0 column ACLs, and no synthetic object present.

**Coverage, stated precisely.** No single run exercised all sections: locally C was 0 and D was
166; synthetically D was 0 and C was 2. Coverage is a **union across two different databases**,
not one end-to-end validation. Field-level assertion was performed only for section C's 2
synthetic rows; sections A, B, D, E, F, G and H were validated structurally — they executed,
produced well-formed rows in the fixed contract, ordered deterministically and reproduced
byte-identically — but their values were not asserted row-by-row against an independent
expectation. Saying the capture is "validated for all sections A–H" without those qualifications
overstated it.

## Status

| Item | State |
|---|---|
| Capture query | sections A–J, including relation-backed row types. Executed and byte-deterministic on the local stack, a synthetic container, an integrated synthetic database and the restored LMS stack. Sections C, E and I field-asserted; A, B, D, F–H, J structurally validated, J additionally proven to fail closed |
| Output format | validated on isolated fixtures, the restored LMS stack and the refreshed staging capture; raw CSVs remain owner-only outside the repository |
| Recovery algorithm | proven in isolated containers across all six supported classes and applied successfully to the confirmed disposable restored-local copy; one atomic transaction, in-transaction verification, then independent capture parity |
| Recovery artifact | `_r2` applied **only** to `supabase_db_last_man_standing`: exit 0, `COMMIT`, 327-edge / 72-default-rule verification, then independent 0-missing / 0-extra parity. Earlier artifacts are superseded. Never run against staging or production |
| Source capture | staging `evhiixndiuwwodsouyhf` captured manually by the operator 2026-08-28, 544 rows, verified by SHA-256; compared against the restored target and found sufficient for the validated algorithm. Raw CSVs are held outside the repository and are not committed |
| Gate | `NOT READY` — restore demonstration is now satisfied, but recovery-envelope items 1 and 7 still require explicit operator acceptance |

## Redesign experiments — 2026-08-28, isolated container only

Conducted in a uniquely named disposable PostgreSQL 17.6 container (`pg17-aclredesign`, own
volume, synthetic roles and data). The LMS stack was never used or modified; container and volume
were removed afterwards by name-guarded commands. **No LMS repair artifact was produced.**

### Synthetic cases built

All ten required cases, verified present in the catalogue before testing:

| # | Case | Observed ACL |
|---|---|---|
| 1 | Owner grants directly | `t_direct :: direct_grantee=r/owner_role` |
| 2 | Third-party grantor | `t_third :: third_party=r*/owner_role, direct_grantee=r/third_party` |
| 3 | Three-level chain | `t_chain :: role_a=r*/owner_role, role_b=r*/role_a, role_c=r/role_b` |
| 4 | `PUBLIC` | `t_public :: =r/owner_role` |
| 5 | Column-level | `t_col.col1 :: role_a=r/owner_role`; `t_col.col2 :: role_b=w*/owner_role` |
| 6 | Routine | `fn_demo :: role_c=X/owner_role` |
| 7 | Schema / table / sequence | `public :: owner_role=UC/...`; `s_seq :: role_b=rU/owner_role` |
| 8 | Default-privilege rules | `owner_role/r :: role_a=r/owner_role`; `owner_role/f :: role_b=X/owner_role` |
| 9 | Explicit grant to the owner | `t_third :: owner_role=r/third_party` |
| 10 | Grantable and non-grantable | `role_a=r*` vs `direct_grantee=r` |

### What was proven

**Grantor-scoped removal works, via a transaction-scoped role context.** `SET LOCAL ROLE
<grantor>` followed by `REVOKE`, then `RESET ROLE`. `SET LOCAL` is bounded by the transaction and
reverts on commit or rollback, so the elevated context cannot leak. This is the substitute for the
unusable `GRANT … GRANTED BY`.

**Leaf-peeling removes chains without CASCADE.** Repeatedly revoke only edges whose grantee is not
itself a grantor for the same object, so dependents always precede their enablers. The three-level
chain `t_chain` cleared to `{}` in 5 passes — third-party and chained grants **are** removable,
contrary to the stronger reading of blocker 2.

**Grantor cycles deadlock leaf-peeling and need a CASCADE break.** With `owner_role → third_party`
and `third_party → owner_role` on the same object, no edge is ever a leaf and the loop stalls. The
fix is to detect no-progress-with-edges-remaining and issue
`REVOKE GRANT OPTION FOR <priv> … FROM <grantee> CASCADE` as that edge's grantor, then resume
peeling. Verified: `t_third` cleared to `{}` afterwards.

**Replay must be dependency-ordered.** A grantor that is not the owner must already hold the
privilege `WITH GRANT OPTION` before its dependent grant can be replayed. Implemented as passes
that skip unsatisfied edges and revisit them; converged in **2 passes**.

**The completion check must cover every object class.** An early version checked only
`kind='relation'`, so column and routine edges never matched as "already done" and were re-granted
on every pass — the loop ran to its 41-pass cap instead of converging. Correcting the check to
cover all classes dropped it to 2 passes. A loop that reaches the right end state without
converging is a latent defect, not a cosmetic one.

### Evidence

| Requirement | Result |
|---|---|
| Third-party grants actually removed | `t_chain` and `t_third` both reached `{}` |
| Reconstructed grantor graph matches source | **58 live edges vs 58 source; 0 missing, 0 extra** — compared on object, column, grantee, **grantor**, privilege and grantability |
| Mid-transaction failure rolls back | error raised mid-transaction; `t_chain` ACL byte-unchanged afterwards; `current_user` restored to `supabase_admin` |
| Repeatability | second full run reproduced the identical end state: same 8 reset passes, same 2 replay passes, same 58/58 with 0 missing and 0 extra |
| Exit statuses | repair transaction exit `0`; parity queries exit `0` |
| Sanitized errors observed | `ERROR: grantor must be current user`; `ERROR: dependent privileges exist / HINT: Use CASCADE`; `WARNING: SET LOCAL can only be used in transaction blocks` |

**Repeatability, stated precisely — this is not a no-op.** A second full run does **not** detect
"already correct" and skip work. It performs the entire reset again (8 passes, including the
CASCADE cycle-break) and the entire replay again (2 passes), and converges to a byte-identical end
state. That is convergence to a fixed point from any starting state, which is the property the
repair needs — but it is weaker than no-op idempotence, and the observed pass counts are recorded
above rather than summarised as "idempotent". A reader should not infer that re-running is cheap
or side-effect-free within the transaction; it is neither.

The rollback proof is stronger than designed: a *real* error (`dependent privileges exist`, from
revoking a chain edge out of order) aborted the transaction before the injected exception fired.
Rollback was complete regardless of which error triggered it.

### Why the blocker is retained

**Two required cases are not covered by the tested algorithm.** Confirmed by direct audit after
the run:

| Class | Reset | Replay | State after the run |
|---|---|---|---|
| Relation | yes | yes | reproduced exactly |
| Column | yes | yes | reproduced exactly |
| Routine | yes | yes | reproduced exactly |
| **Schema privileges** | **no** | **no** | `public` `nspacl` untouched |
| **Default-privilege rules** | **no** | **no** | both `owner_role` rules still present |

Leaving default-privilege rules unreset is not a partial success — it is the specific failure mode
that produced the 2W divergence, and a target verifying clean immediately would drift again on the
next object created. Until both classes are covered and tested to the same standard, this
algorithm must not be used to generate a repair artifact.

Also untested: `pg_type.typacl` (not captured at all), system-column ACLs, and any object class
outside schema `public`.

## Schema and default-privilege experiments — 2026-08-28, isolated container only

Conducted in `pg17-schemadefacl` (disposable PostgreSQL 17.6, own volume, synthetic roles and
objects). The LMS stack was never used or modified; container and volume were removed afterwards
by name-guarded commands. **No LMS repair artifact was produced.**

### Schema ACL — all eight cases passed

Fixture on synthetic schema `s_test` owned by `schema_owner`, exercising `USAGE`/`CREATE`, direct
owner grants, a third-party grantor, a three-level chain with grant options, a grantor cycle
(`schema_owner ↔ role_x`), `PUBLIC`, and target-only excess injected after the snapshot.

The relation algorithm transferred **unchanged in shape**: `SET LOCAL ROLE <grantor>` → `REVOKE
… ON SCHEMA` → `RESET ROLE`, leaf-peeling, and no-progress detection breaking the cycle with
`REVOKE GRANT OPTION FOR … ON SCHEMA … CASCADE`. Reset converged in 6 passes, replay in 2.

| Check | Result |
|---|---|
| Parity including grantor | **13 live vs 13 source, 0 missing, 0 extra** |
| Target-only excess removed | grants to `target_only`: **0** |
| Cycle handled | cycle-breaker fired on `role_x`, then peeling completed |

### Default-privilege rules — all thirteen cases passed

Fixture covering schema-specific and global rules, two default-owning roles, `PUBLIC`, named
roles and grant options, across future **tables, sequences, routines, types and schemas**.
PostgreSQL 17 does support `ALTER DEFAULT PRIVILEGES … ON SCHEMAS` (global only, no `IN SCHEMA`).

**Mechanism.** Reset and replay both use
`ALTER DEFAULT PRIVILEGES FOR ROLE <defaclrole> [IN SCHEMA s] REVOKE|GRANT <priv> ON <objkw> …`
executed under `SET LOCAL ROLE <defaclrole>`. Grantor preservation is simpler here than for
relations: every `defaclacl` entry's grantor **is** the `defaclrole`, so acting as that role
reproduces the grantor by construction. Object-type codes map `r→TABLES, S→SEQUENCES,
f→FUNCTIONS, T→TYPES, n→SCHEMAS`; `n` rules cannot carry `IN SCHEMA`.

| Check | Result |
|---|---|
| Parity including grantor | **10 live vs 10 source, 0 missing, 0 extra** |
| Target-only rules removed | `defaclacl` entries for `target_only`: **0** |
| Multiple default-owning roles | `defowner_a` and `defowner_b` both reproduced |

### Probe objects created after replay

Objects created by each default-owning role after the replay, to prove future objects actually
inherit the intended privileges:

| Probe | Expected | Result |
|---|---|---|
| table in `s_test` by `defowner_a` | `role_x=r/defowner_a` | **PASS** |
| sequence in `s_test` by `defowner_a` | `role_y=U*/defowner_a` (grant option) | **PASS** |
| type by `defowner_a` (global rule) | `role_x=U/defowner_a` | **PASS** |
| table in `s_test` by `defowner_b` | `role_z=a*/defowner_b` (grant option) | **PASS** |
| schema by `defowner_b` (global rule) | `role_y=U/defowner_b` | **PASS** |
| function in `s_test` by `defowner_a` | `PUBLIC=X/defowner_a` | **non-discriminating** |

The function probe is recorded honestly rather than counted as a pass or a failure. Its rule
grants `EXECUTE` to `PUBLIC`, which is *already* the built-in default —
`acldefault('f', defowner_a)` is `{=X/defowner_a,defowner_a=X/defowner_a}` — so PostgreSQL stores
`proacl` as NULL because there is no deviation to record. The **rule** is verifiably reproduced
(it appears in `pg_default_acl` as `{=X/defowner_a}` and is counted in the 10/10 parity); the
probe simply cannot distinguish "rule present" from "rule absent" for that case.

**This is a general limitation of probe-based verification**: any default rule that grants exactly
what the built-in default already grants is invisible on created objects. `pg_default_acl` parity
is the authoritative check; probes corroborate it, and cannot replace it.

### Rollback and repeated-run behaviour

**Rollback:** an injected failure after revoking every schema edge and every default rule left
both dimensions byte-unchanged (13 schema edges, 10 defacl rows) and restored `current_user` to
`supabase_admin`. `SET LOCAL ROLE` reverted with the transaction.

**Repeated run — not a no-op.** A second full run again performed the entire reset (6 schema
passes plus a full default-rule sweep) and the entire replay (2 schema passes plus a full
default-rule sweep), converging to an identical state: 13/13 and 10/10, 0 missing and 0 extra.
As with the relation algorithm, this is convergence to a fixed point, not skip-if-correct.

## Integrated cross-class validation — 2026-08-28, isolated container only

Closes the four scope gaps left by the previous round, in one cycle, on a disposable
PostgreSQL 17.6 container (`public.ecr.aws/supabase/postgres:17.6.1.165`, the same image as the
LMS stack). Nothing in this section ran against staging or production. The restored LMS stack was
read from twice and never modified. The synthetic container and its volume were uniquely named
and removed afterwards.

### Gap 1 — grantable type classes and `pg_type.typacl`

Determined by construction rather than assumption:

| Type class | `typacl` | Tested behaviour |
|---|---|---|
| enum `e`, domain `d`, standalone composite `c` (`typrelid` → `relkind 'c'`), range `r`, base `b` | stored | `GRANT USAGE` accepted and recorded; selected by the section I CTE |
| multirange `m` | never | `GRANT USAGE ON TYPE public.t_multirange` → `ERROR: cannot set privileges of multirange types` / `HINT: Set the privileges of the range type instead.` |
| array (`typcategory 'A'`) | never | `GRANT … ON TYPE x[]` is a **syntax error**; granting on the internal name `"_x"` → `ERROR: cannot set privileges of array types` / `HINT: Set the privileges of the element type instead.` The array's `typacl` stays NULL and the element type's ACL is unchanged |
| relation-backed row type `c` (`typrelid` → `relkind` in `r, p, v, m, f`) | **stored and enforced** | captured — see "Relation-backed row types" |

Section I captures the storing classes and marks a NULL `typacl` `default-derived`, since types
have a non-empty built-in default (`{=U/owner,owner=U/owner}`) that a restore can diverge from
silently.

#### A coverage gap this verification found in section I — since closed

The earlier exclusion of table row types was documented as "privileges live on the relation, not
the type". **That reason is false**, and was disproven by direct test on 17.6:

* `GRANT USAGE ON TYPE public.rt_tbl TO tr` **succeeded** and stored a `typacl` on the row type,
  separate from and additional to the table's `relacl`.
* `REVOKE USAGE ON TYPE public.rt_tbl FROM PUBLIC` flipped
  `has_type_privilege('tu', 'public.rt_tbl'::regtype, 'USAGE')` from **true to false**.
* It is **enforced**, not merely reported: with USAGE revoked, `CREATE TEMP TABLE probe(x
  public.rt_tbl)` failed with `ERROR: permission denied for type rt_tbl`, while
  `select count(*) from public.rt_tbl` still succeeded under the table's own `relacl`. The two
  ACLs are independent.

The section I CTE excludes every composite whose `typrelid` names a `pg_class` entry with
`relkind <> 'c'` — the row types of tables, partitioned tables, views, materialised views,
foreign tables and sequences. Such a type can therefore carry an explicit, enforced ACL that the
capture drops silently, and that a recovery built on this capture would neither reproduce nor
remove.

**Exposure today is nil, but the hole is real.** On the restored LMS stack `public` holds 13
relation-backed row types and **none** carries an explicit `typacl`; no public type of any class
does. The gap is latent, not active — but a source database could acquire one, and a divergent
restore could add one that the recovery would never remove.

Standalone composite types are unaffected and remain covered: `t_comp`, whose `typrelid` has
`relkind 'c'`, is selected by the CTE. **This gap was closed in the following round** — see
"Relation-backed row types".

### Gap 2 — system-column ACLs: the exclusion was wrong

The previous note excluded `attnum <= 0` by assumption. Tested directly:

* `GRANT SELECT (ctid | xmin | cmin | xmax | cmax | tableoid)` **all succeeded** and produced
  negative-`attnum` rows in `pg_attribute.attacl`.
* `has_column_privilege(role, table, 'ctid', 'SELECT')` returned **true** while the same role's
  ordinary column `a` returned **false** — the grant is real and independently effective.

The section C predicate is now `attnum <> 0 and not attisdropped and attacl is not null`.
`attnum = 0` (the whole-row pseudo-attribute) is still excluded; it never carries an ACL.

Section C's assertions were re-run because its structure changed. Against purpose-built fixtures
the predicate emitted **exactly** four rows and nothing else:

| Fixture | `attnum` | Emitted | Why |
|---|---|---|---|
| `c_grant.a` SELECT | 1 | yes | ordinary column grant |
| `c_grant.b` UPDATE WITH GRANT OPTION | 2 | yes | grant option preserved |
| `c_sys.ctid` SELECT | -1 | yes | **system column, newly covered** |
| `c_sys.xmin` SELECT | -2 | yes | **system column, newly covered** |
| `c_plain` (no column grants) | — | no | `attacl` NULL, nothing to derive |
| `c_drop.z` (granted, then dropped) | — | no | `attisdropped` |
| `c_empty.a` (granted, then fully revoked) | — | no | `attacl` returns to NULL |

### Gap 3 — explicit fail-closed scope contract

The vague "non-public schemas are out of scope" is replaced by section J, which classifies every
schema outside `pg_*` and `information_schema` as one of `IN SCOPE`, `PLATFORM-MANAGED: do not
overwrite from source ACLs`, or `UNCLASSIFIED: recovery must FAIL CLOSED`, and by a matching
preflight in the recovery algorithm. Proven end-to-end: with an unclassified schema `app_custom`
present, the capture labelled it `UNCLASSIFIED: recovery must FAIL CLOSED` and the recovery
aborted with `PREFLIGHT: unclassified schema present - fail closed`, leaving all five divergence
measures unchanged. The classification is not advisory — it stops the run.

### Gap 4 — one integrated database, one transaction, all six classes

A single synthetic database carrying every supported class at once: nested role memberships
(`grp_outer` → `grp_inner`), a third-party grant chain (`own_r` → `third` WITH GRANT OPTION →
`rb`), a schema-privilege chain and cycle, column grants including a system column, a routine,
four grantable type classes, and default-privilege rules across three owners including both an
empty rule and a rule that is a strict subset of the built-in default.

Baseline: **683 capture rows**, byte-identical across two consecutive runs — 40 ACL edges
(relation 15, schema 13, type 6, column 3, routine 3), 7 default-privilege groups, 10 default
edges, and a **3,196-probe effective-security matrix** built from `has_table_privilege`,
`has_sequence_privilege`, `has_function_privilege`, `has_type_privilege`, `has_schema_privilege`
and `has_column_privilege`, each probed with and without `WITH GRANT OPTION`.

Divergence was then injected in **both directions in every class**: 8 target-only edges
(schema, relation incl. a second-level grant made under an injected grant option, column, routine,
type), 8 source-only edges (including one on the third-party chain and one on a system column),
14 default-edge differences and 5 default-group differences — **69 effective probes diverged**.

The reset/replay then ran in one transaction under `pg_advisory_xact_lock`, ordered reset
types/routines/columns → relations (leaf-peeling, `REVOKE GRANT OPTION FOR … CASCADE` to break
cycles) → schema last, then replay schema first → objects → default rules. Reset converged in
4 passes (relations) and 3 (schema); replay in 2 and 2.

| # | Property | Result |
|---|---|---|
| 1 | Exact effective-security parity | **PASS** — 3,196 / 3,196 probes identical, both directions, cardinality unchanged |
| 2 | Permitted provenance parity only | **PASS**, and stronger than required — provenance was *exact*: 448 `explicit` and 8 `default-derived` rows, unchanged |
| 3 | Exact grantor graph | **PASS** — all 40 grantor-bearing edges identical, including the one third-party edge `i_tbl → rb GRANTED BY third` |
| 4 | Exact default-rule parity | **PASS** — 7 groups (1 with an empty ACL) and 10 edges identical |
| 5 | Removal of all target-only excess | **PASS** — 0 target-only edges; role `excess` holds no privilege in any class |
| 6 | Rollback after an injected mid-run failure | **PASS** — failure raised after the final replay stage; all five divergence measures unchanged |
| 7 | Repeated-run fixed-point convergence | **PASS** — runs 2 and 3 reproduced identical pass counts (4/3/2/2) and left divergence at zero |

Independently of the internal measures, the amended capture re-run after the repair was
**byte-identical to the 683-row pre-divergence reference — zero differences across all ten
sections**.

Property 6 was demonstrated twice, once unintentionally: the first integrated attempt aborted on a
genuine defect (below) and left every measure unchanged, before the deliberate injection did the
same.

### Two defects this cycle found and corrected

Both were in the default-privilege phase, and both are recorded in the banner because either
would have produced a repair that reported success while leaving the target wrong.

1. **`acldefault()` object-type codes do not match `pg_default_acl.defaclobjtype`.** Sequences are
   `'S'` in `defaclobjtype` but `'s'` in `acldefault()`, where `'S'` means *foreign server*. The
   uncorrected code computed `{owner=U/owner}` where the true sequence default is
   `{owner=rwU/owner}`, so the rule could never be driven to its baseline. This is the same
   type-code inconsistency already recorded for `relkind`, reaching a third catalogue.
2. **The "no row" baseline for a default-privilege rule is scope-dependent.** Proven with probe
   rules created and then reset:

   | Rule scope | Row materialises as | Row is deleted when its ACL becomes |
   |---|---|---|
   | unscoped (`ALTER DEFAULT PRIVILEGES FOR ROLE x`) | built-in default **plus** the grant | `acldefault(objtype, owner)` |
   | `IN SCHEMA s` | the grant **only** | the empty ACL |

   Two consequences follow, and the algorithm was corrected for both. Revoking only the recorded
   grants leaves an empty-ACL residue row on unscoped rules for object types whose built-in
   default is non-empty (`TYPES`, `FUNCTIONS`); that residue is **not** equivalent to no row,
   because it suppresses the built-in `PUBLIC` privilege on every future object. And a grant-only
   replay cannot reproduce a source rule that is a strict *subset* of the built-in default. Each
   group is therefore driven to an exact target ACL — revoke `baseline \ source`, then grant
   `source \ baseline` — with the baseline chosen by scope.

### One hazard tested and found not to exist

Fully revoking every privilege leaves `relacl`, `typacl`, `proacl` and `nspacl` holding an **empty
array rather than NULL** (`attacl` alone reverts to NULL). Since `coalesce` cannot rescue an empty
array, this looked like it would abort the capture on `aclexplode`. It does not: a
catalogue-stored empty ACL is *one-dimensional* with cardinality 0, which `aclexplode` accepts,
returning zero rows. The capture already handles the state correctly, emitting an ownership row
annotated `(acl empty: no privileges)` — which is the right distinction, since an empty ACL means
"nobody, not even the owner" while NULL means "built-in defaults apply".

The zero-dimensional array that *does* raise `ACL arrays must be one-dimensional` is produced only
by a text round-trip (`relacl::text::aclitem[]`). **Implementation note for any future artifact:**
never round-trip a captured ACL through text and cast it back; carry `aclitem[]` directly, or
guard every explode with a cardinality check.

### Capture validation runs

| Target | Runs | Result |
|---|---|---|
| Integrated synthetic database, before divergence | 2 | exit 0, no stderr, **byte-identical**, 683 rows, sections A–J all present |
| Integrated synthetic database, after repair | 2 | exit 0, no stderr, **byte-identical**, and identical to the pre-divergence reference |
| Restored LMS stack (`supabase_db_last_man_standing`), read-only | 2 | exit 0, no stderr, **byte-identical**, 854 rows |

On the LMS stack all 11 non-system schemas classified — 1 `IN SCOPE`, 10 `PLATFORM-MANAGED`, none
`UNCLASSIFIED` — so the scope contract would permit a run there. Sections C and I returned empty,
and that emptiness was confirmed against the catalogues directly rather than assumed: `public`
holds **0** columns with a non-NULL `attacl`, and **13** grantable-class types of which **0** carry an explicit `typacl`. The two new sections
are therefore untested against real LMS data by absence of subject matter, not by omission.

## Relation-backed row types — 2026-08-28, isolated container only

Closes the coverage gap recorded in the round above. Disposable PostgreSQL 17.6 container
(`public.ecr.aws/supabase/postgres:17.6.1.165`). Staging and production were not contacted; the
restored LMS stack was read from twice and never modified; the container and volume were uniquely
named and removed afterwards.

### Which relations have a row type — established, not assumed

`pg_class.reltype` is non-zero only for relkind `c, f, m, p, r, v`, and zero for `i` (index),
`S` (sequence) and `t` (TOAST). `GRANT USAGE ON TYPE` was then attempted against one object of
each kind:

| Object | Row type | `GRANT USAGE ON TYPE` |
|---|---|---|
| table `r`, partitioned table `p`, view `v`, materialized view `m`, foreign table `f` | yes | accepted, `typacl` stored |
| standalone composite `c` | yes (itself) | accepted, already covered |
| sequence `S` | **none** | `ERROR: type "public.k_seq" does not exist` |
| index `i`, TOAST `t` | none | not addressable |

A sequence therefore has **no row type at all** rather than one whose privileges are suppressed,
so the set of backing relkinds in section I is closed for 17.6. Anything not on the list is
excluded rather than mislabelled.

### The eight required behaviours

| # | Behaviour | Result |
|---|---|---|
| 1 | Row-type USAGE granted and revoked independently of table privileges | **PASS** — with `own_r` granting `SELECT` on the table to `vic` and `USAGE` on the row type to `tp`/`gr`, the two axes are fully orthogonal: `vic` has table SELECT and no type USAGE, `tp` and `gr` have type USAGE and no table SELECT |
| 2 | Enforcement through a column declaration | **PASS** — as a role without USAGE, `CREATE TEMP TABLE probe (x public.k_tbl)` fails `ERROR: permission denied for type k_tbl`, while `select count(*) from public.k_tbl` still succeeds under the table's own `relacl`; a role holding USAGE declares the column successfully |
| 3 | Explicit grant and grant option | **PASS** — `{own_r=U/own_r,gr=U/own_r,tp=U*/own_r,...}`; the `U*` grant option round-trips through capture and replay |
| 4 | Third-party grantor | **PASS** — `tp`, holding the grant option, granted onward to `gr`, producing `gr=U/tp`; captured and replayed with grantor intact |
| 5 | Target-only excess removal | **PASS** — excess grants injected against all three source baselines (explicit, NULL, empty) and all removed |
| 6 | Exact replay of owner, grantor, grantee, privilege, grantability | **PASS** — 68 edges, 22 of them type edges, 0 missing and 0 extra |
| 7 | Rollback | **PASS** — failure injected after the final replay stage; all five divergence measures unchanged |
| 8 | Repeated-run fixed-point convergence | **PASS** — runs 2 and 3 reproduced identical pass counts (4/3/2/2) with divergence at zero |

### How section I represents them

A row type shares its schema-qualified name with its relation, so `object_identity` alone is
ambiguous. `object_kind` disambiguates: the relation is `table`/`view`/… in sections B and E, the
type is `row type (table)`/`row type (view)`/… in sections I and E. Identity itself is unchanged
and stable.

Privilege rows for row types are emitted **only when `typacl` is explicit**, while ownership and
existence rows are emitted **unconditionally** in section E, annotated `acl null: defaults apply`,
`acl empty: no privileges`, or plain `ownership`. Standalone types keep their existing behaviour
of expanding a NULL `typacl` to `acldefault` and marking it `default-derived`.

The asymmetry is deliberate. Row types are as numerous as relations, so expanding every NULL one
would restate the built-in default once per relation — 26 rows on the LMS stack purely to say
"nothing has been changed here" — and bury the explicit grants that matter. The three-state
annotation in section E carries strictly more information than the expansion would, because it
distinguishes NULL from empty, which the expansion cannot. It is also what the recovery consumes:
the section E existence rows are the authoritative type inventory, and the preflight fails if a
captured type is absent from the target or has changed owner. Types whose source ACL is NULL or
empty contribute no privilege edges and would otherwise be invisible to the recovery.

**If this asymmetry is not wanted, the alternative is to expand NULL row-type ACLs like standalone
ones.** That is a one-line change, and it would make the two halves of section I uniform at the
cost of the volume described above. It is flagged rather than decided here.

### Three baselines, and what the recovery must do with each

| Source `typacl` | Means | Recovery target |
|---|---|---|
| explicit array | exactly these grants | reproduce the edge set exactly, grantor included |
| NULL | built-in defaults apply — `PUBLIC` and the owner hold USAGE | drive to `acldefault('T', owner)` |
| empty `{}` | **nobody**, not even the owner | drive to `{}` |

NULL and empty are not interchangeable, and conflating them would be a security change in either
direction. The integrated fixture carried all three simultaneously, and excess grants were
injected against each.

### Leaf-peeling had to be generalised

Types carry grant chains exactly as relations do — `own_r` → `t_grantee` WITH GRANT OPTION →
`rc` on a table's row type. A flat revoke loop would hit `dependent privileges exist`, so the
reset's leaf-peeling and its `REVOKE GRANT OPTION FOR … CASCADE` cycle-break were generalised from
relations alone to all four object classes. Reset converged in 4 passes and replay in 2.

### Integrated re-run

The full integrated synthetic recovery test was rebuilt with row types included: relations, a
sequence, columns including a system column, a routine, three standalone types, six row types
across four backing relkinds and all three baselines, nested role memberships, third-party grant
chains on both a relation and a row type, and default-privilege rules across three owners.

Baseline 796 capture rows, byte-identical across two runs; 68 ACL edges; 7 default groups; a
**4,454-probe effective-security matrix**, 306 of those probes covering type privileges.
Divergence was injected in both directions in every class — 11 target-only edges, 10 source-only
edges, 16 default-rule differences, 59 diverging probes. After the repair, every measure was
**zero**, including 4,454 of 4,454 effective probes.

### The one bounded consequence: NULL provenance cannot be restored

PostgreSQL does not normalise `typacl` back to NULL when it becomes equal to `acldefault` — that
was tested directly, and the array persists explicitly. There is no SQL that restores the NULL
state, so a type whose source `typacl` is NULL and whose target has been diverged ends the repair
holding an explicit ACL **byte-equal to `acldefault`**. Effective privileges are identical; only
provenance differs, which is exactly the permitted-difference class already defined in this note.

That difference is visible in the capture and is bounded precisely. Re-capturing after the
integrated repair produced **12 differing lines against the pre-divergence reference, and nothing
else**: two section E annotations changing from `acl null: defaults apply` to `ownership`, the
four section I rows those two types now emit, and the four section G counts that move by exactly
+2 each to match. The empty-ACL row type kept `{}` exactly. Recorded here so a future reader does
not mistake it for a defect — but it does mean capture-level parity after a repair is
**not byte-identical** for NULL-sourced types, and only edge-level and effective-level parity are.

### Capture validation

| Target | Runs | Result |
|---|---|---|
| Integrated synthetic database, before divergence | 2 | exit 0, no stderr, byte-identical, 796 rows |
| Integrated synthetic database, after repair | 2 | exit 0, no stderr, byte-identical; 12 lines differ from the reference, all the provenance case above |
| Restored LMS stack, read-only | 2 | exit 0, no stderr, **byte-identical**, 867 rows |

On the LMS stack the capture grew from 854 to 867 rows — **+13 lines, 0 removed, every one an
`E. OWNERSHIP` row-type row**. All 13 public row types now appear in ownership/existence coverage
(12 `row type (table)`, 1 `row type (view)` — `football_team_form`), each annotated `acl null:
defaults apply`, and **section I contains 0 rows**: none of them currently carries an ACL
privilege. A direct catalogue cross-check agrees — 12 table row types and 1 view row type, 0 with
an explicit `typacl`.

## Staging vs restored-local comparison — 2026-08-28

First comparison of a **real** source capture against the restored target. Source: the staging
capture exported manually from project `evhiixndiuwwodsouyhf` by the operator (544 rows, 9 columns,
mode `600`, SHA-256
`7c3164fda5ed8e534a2a6e2cdd6b82386a1a9ab53f397c2b31fb917819ce829c`, all re-verified before
analysis; all 544 rows parse to exactly nine fields). Target: a fresh read-only capture taken from the untouched restored LMS stack with
the query at commit `12bf9ec`, run twice and byte-identical, 867 rows. Neither CSV is committed;
both live in an owner-only directory outside the repository. Staging was not contacted by this
analysis — the operator ran the query — and the local stack was read from only.

### Structural counts

| Section | Source | Target | Delta |
|---|---:|---:|---:|
| A. Schema privileges | 7 | 7 | 0 |
| B. Relation privileges | 245 | 452 | **+207** |
| C. Column privileges | 0 | 0 | 0 |
| D. Routine privileges | 75 | 166 | **+91** |
| E. Ownership | 71 | 71 | 0 |
| F. Default privileges | 78 | 102 | **+24** |
| G. Grantees observed | 10 | 10 | 0 |
| H. Role security context | 48 | 48 | 0 |
| I. Type privileges | 0 | 0 | 0 |
| J. Schema scope | 10 | 11 | +1 |
| **Total** | **544** | **867** | **+323** |

Parity under both contracts: **effective-security** — 6 source-only, 329 target-only;
**provenance** — 24 source-only, 347 target-only. The difference between the two contracts is
18 rows that agree on every security-relevant field and differ only in `acl_source`.

### Classified differences

| Class | Count | Detail |
|---|---:|---|
| Source-only **required grants** | **0** | staging holds no privilege the target lacks, in any section |
| Target-only **excess grants** | **322** | 207 relation, 91 routine, 24 default-privilege |
| **Grantability** differences | **0** | no `is_grantable` mismatch anywhere |
| **Grantor** differences | **0** | every shared edge agrees on its grantor |
| **Ownership** differences | **0** | 71 objects, identical owners; only `pg_database_owner` and `postgres` own anything in `public` |
| Approved **ACL-source provenance** differences | **13 edges + 5 ownership annotations** | all one direction: NULL in staging, explicit locally |
| Role / schema-scope **blockers** | **0** | see below |

The divergence is therefore **purely additive toward more privilege**, exactly as section 2W
observed on the 148-vs-206 comparison, and the capture's own warning that this is an observation
rather than a law still stands — it simply happens to hold again here.

### The excess, characterised

All 322 excess edges are grants to the three Supabase client roles, and none is grantable:

| Grantee | Relation | Routine | Default | Total |
|---|---:|---:|---:|---:|
| `anon` | 73 | 41 | 8 | 122 |
| `authenticated` | 73 | 9 | 8 | 90 |
| `service_role` | 61 | 41 | 8 | 110 |

Spread over **57 distinct objects** — every relation, sequence and routine in `public` (16 + 41). **Zero excess edges carry a grant option**, so no dependent
privileges hang off any of them.

The 24 default-privilege excess rows are confined to the three `postgres`-owned groups in schema
`public`, which locally hold 4/12/32 edges for future routines/sequences/tables against staging's
1/3/20. The three `supabase_admin`-owned groups are **identical on both sides** at 4/12/32. The
local `postgres` rules have in effect been widened to match `supabase_admin`'s broader ones — which
is precisely the drift that makes any newly created object inherit the wrong privileges, and the
reason resetting default rules is not optional.

### The provenance differences are the known NULL case, now on real objects

Thirteen edge rows across five objects are `default-derived` in staging and `explicit` locally:
three sequences (`football_fixtures_id_seq`, `football_teams_id_seq`, `player_picks_id_seq`) and
two functions (`create_profile_for_new_user()`, `rls_auto_enable()`). The five matching section E
rows differ the same way — `ownership (acl null: defaults apply)` in staging, plain `ownership`
locally. Those same five objects also carry excess: 9 target-only edges on each sequence and 3 on
each function.

This is the NULL-provenance case already documented for row types, **now confirmed to occur on
real relations and routines**. The consequence is unchanged and unavoidable: PostgreSQL does not
restore a NULL ACL, so after a repair these five objects will hold an explicit ACL byte-equal to
their built-in default. Effective privileges will match staging exactly; the 13 edge rows and 5
annotations will still differ. **That residual is expected and must not be treated as a failed
repair.**

### Roles, objects and scope — nothing blocks recovery

Source ACL and ownership rows reference exactly six roles — `anon`, `authenticated`,
`pg_database_owner`, `postgres`, `service_role`, `supabase_admin` — and **all six exist locally**.
All **71 objects** named by the source exist locally; none is missing.

Fourteen further roles exist in staging but are referenced by no in-scope ACL edge or ownership
row, so none is required for recovery. One of them, `cli_login_postgres`, is the temporary login
role the Supabase CLI creates; its presence records how the capture was taken and is not a
dependency.

The two databases do not carry the same platform schema set: staging has `supabase_migrations`,
the local stack has `_realtime` and `supabase_functions`. Every schema on both sides classifies as
`IN SCOPE` (`public` only) or `PLATFORM-MANAGED`, and **neither side has any `UNCLASSIFIED`
schema**, so the fail-closed preflight passes against this pair. The platform-schema difference is
outside the recovery's scope by contract and needs no action.

Section G's three differing counts (`anon` 41→155, `authenticated` 73→155, `service_role` 53→155)
are a consequence of the excess, not an independent finding. Section H holds 48 rows on each side —
**23 role-attribute rows naming 20 distinct roles, plus 25 membership rows**. There are therefore
**20 roles per side, 19 of them shared, with zero attribute differences** across the 19; the two
non-shared roles are `cli_login_postgres` in staging and `supabase_functions_admin` locally. (An
earlier revision of this paragraph said "45 roles … 43 shared". That was wrong: it counted the 25
membership identity strings such as `cli_login_postgres -> postgres` as if they were roles, and
overstated the breadth of the check by 2.3x. The conclusion — zero attribute differences — is
unaffected and was re-confirmed.)

### Recovery specification — deterministic workload, no SQL generated

| Phase | Step | Workload | Acting as |
|---|---|---|---|
| RESET | 1 | 166 routine revokes | `postgres` |
| RESET | 2 | 452 relation revokes | `postgres` |
| RESET | 3 | — no column or type ACLs exist on either side | — |
| RESET | 4 | 7 schema revokes, **last**, so USAGE survives every object operation | `pg_database_owner` |
| RESET | 5 | 6 default-privilege groups driven to their built-in baseline | `postgres`, `supabase_admin` |
| REPLAY | 6 | 7 schema grants, **first**, restoring USAGE before any object grant | `pg_database_owner` |
| REPLAY | 7 | 245 relation grants | `postgres` |
| REPLAY | 8 | 75 routine grants | `postgres` |
| REPLAY | 9 | 6 default-privilege groups driven to the exact source ACL | `postgres`, `supabase_admin` |

**625 revokes and 327 grants**, in one transaction. The default-privilege phase touches 12 groups
but issues one `ALTER DEFAULT PRIVILEGES` **per edge**, not per group: the reset drives 6 target
groups holding 96 edges to their baseline and the replay drives 6 source groups to 72 edges, so it
is roughly **168 statements**, not 12.
The recovery must be able to assume three grantor identities: `pg_database_owner`, `postgres` and
`supabase_admin`.

Because **no edge on either side is grantable and no edge has a grantor different from its owner**
— both measured — the `REVOKE GRANT OPTION FOR … CASCADE` cycle-break and the replay's
grant-option precondition never engage on this workload.

**Leaf-peeling does engage, and an earlier revision of this paragraph wrongly said it does not.**
The peel predicate defers any edge whose grantee is the grantor of another edge in the same object
family, and `postgres` / `pg_database_owner` are both grantor and grantee of their own aclitems:
**156 of the 625 target edges** meet that condition (2 schema, 113 relation, 41 routine). The reset
therefore takes three passes, not two — the owner's own edges are revoked only after every edge
they granted. A reviewer told the pass loop is inert would not scrutinise it, so the claim is
corrected here rather than softened.

### Is the validated algorithm sufficient for this capture?

**Yes. Every construct in this comparison is a strict subset of what was proven**, and the harder
cases the algorithm exists for are simply absent: no grant options, no third-party grantors, no
cycles, no column ACLs, no type ACLs, no missing roles, no missing objects, no unclassified schema,
no ownership drift. Two default-privilege owners appear together, which the multi-owner synthetic
fixture already covered.

One case is new only in *where* it appears: the NULL-ACL provenance difference, previously proven
on types, occurs here on three sequences and two functions. It needs no algorithm change — the
capture already represents it and the replay already handles it — but it does mean a post-repair
capture of this pair **will not be byte-identical to the source**, and the expected residual is
exactly 13 edge rows plus 5 ownership annotations. Anyone verifying the repair should compare under
the effective-security contract, not the provenance contract.

### Algorithm selected

**The full reset/replay algorithm is selected for this workload.** It is the form the seven proven
properties apply to — exact effective-security parity, permitted-only provenance parity, exact
grantor graph, exact default-rule parity, complete removal of target-only excess, atomic rollback
after an injected mid-run failure, and repeated-run fixed-point convergence — and every construct
in this real workload is already covered by that testing.

**The differential revoke-only shortcut is explicitly NOT selected and remains unvalidated.**
Because there are zero source-only grants, the divergence could in principle be cleared by revoking
only the 322 excess edges rather than performing 625 revokes and 327 grants, and that form is both
smaller and never leaves the schema without USAGE mid-transaction. Those advantages are real and
they are still not sufficient: none of the seven properties has been demonstrated for it, it has no
fixed-point or rollback evidence of its own, and its correctness depends on the "zero source-only
grants" precondition continuing to hold at execution time — a precondition this comparison
establishes for one moment on one pair of databases, not a property of the mechanism. It is
recorded so the reasoning stays visible and so nobody re-derives it later as a fresh idea; adopting
it would require its own full validation cycle first.

## Generated recovery implementation — 2026-08-28

The executable artifact has been **generated but not applied**. It has never been run against the
restored LMS stack, and never against staging or production. Everything below was proven in a
disposable PostgreSQL 17.6 container built from the LMS stack's own image, which was removed
afterwards.

This section brings the design contract into agreement with what was actually built. Where the
implementation deviates from what earlier sections describe, the deviation is stated here rather
than left to be discovered by reading code.

### Architecture: generator, template, artifact, manifest

| Component | Purpose |
|---|---|
| `scripts/generate_phase_2k_acl_recovery.py` | reads a capture CSV, validates it, decomposes identifiers, emits the artifact and manifest. Connects to nothing and executes nothing |
| `scripts/phase_2k_acl_recovery_template.sql` | the **fixed algorithm**. Does not vary with the input |
| `supabase/recovery/phase_2k_acl_recovery_<sha-prefix>.sql` | the generated artifact: template + staged source snapshot |
| `supabase/recovery/…​.manifest.txt` | the review anchor: four full SHA-256 hashes, structural counts, expected workload, permitted provenance residual |

**Why the template is separated from the data.** The artifact is 1,313 lines, most of it staged
rows. If the algorithm were regenerated alongside the data, every review would have to re-read the
algorithm to confirm it had not silently changed, and a diff between two artifacts would mix
algorithm drift with data drift. Splitting them makes the algorithm a fixed, separately hashed
object: `generator_template_sha256` in the manifest pins it, a diff of two artifacts generated from
different captures shows **only** staged rows, and reviewing the algorithm once is enough until
that hash changes.

Determinism follows from the same split. Every emitted row set is sorted by an explicit total key,
and no timestamp, hostname, path or environment value is written into the artifact. Regenerating
from the same capture reproduces `artifact_sha256` exactly — confirmed by generating twice and
comparing bytes.

### Identifier decomposition and refusal rules

The capture emits identities as unquoted concatenations: `public.foo`, `public.foo.col`,
`public.foo(a integer, b text)`. Splitting those inside SQL at run time would mis-handle an
identifier containing a dot. The generator therefore decomposes every identity in Python into
`(schema, name, args, column)` and stages them as separate columns, so **the artifact never parses
a dotted identity**. An identity that does not decompose unambiguously — the wrong number of
dot-separated parts, or a routine with no argument list — is refused rather than guessed.

A relation and its row type share an identity and differ only in `object_kind`, so the ownership
index is keyed on `(class, identity)`, never on identity alone. A column privilege has no ownership
row of its own; its parent is resolved to the owning relation or sequence, and a column whose parent
has no `E. OWNERSHIP` row is refused as an incomplete capture.

The generator refuses, writing no artifact, on all of the following. **Every one was exercised
against a deliberately corrupted copy of the real capture; each exits non-zero and leaves no file
behind.**

  1. source-capture SHA-256 mismatch
  2. a header that is not the nine expected columns
  3. any row whose field count is not nine
  4. a duplicate whole row
  5. a duplicate `(object_kind, identity)` in `E. OWNERSHIP`
  6. an unknown section
  7. an unsupported `object_kind` in a section it must interpret
  8. an `UNCLASSIFIED` schema in section J
  9. a routine identity carrying no argument list
  10. an identity that does not decompose unambiguously (a dot inside an identifier)
  11. a privilege row naming an object that has no `E. OWNERSHIP` row

Identifiers are emitted through `format('%I')` and `quote_ident()`, never by string concatenation,
and `PUBLIC` is emitted as the keyword rather than as a quoted role name.

### Policy: target-only default-privilege groups

A default-privilege rule present on the target but absent from the capture is target-only excess,
and property 5 of the validated algorithm requires it to be removed. The implementation removes it
— **but only when its default-owning role appears in the capture's authorized role set.**

  * If the owning role **is** in the source capture's role set, the group is target-only excess for
    a role this recovery is already authorized to act on. The reset drives it to its built-in
    baseline, PostgreSQL deletes the row, and the replay does not restore it.
  * If the owning role is **absent** from the source capture, the run **fails closed** before any
    mutation, with the owner, object type and schema named in the error.

The reason for the split is that a default-privilege rule is not scoped like an object grant. An
unscoped rule (`ALTER DEFAULT PRIVILEGES FOR ROLE x` with no `IN SCHEMA`) governs future objects in
**every** schema, including platform-managed ones. Deleting such a rule for a role the capture has
never heard of would change a stranger platform role's future objects, in schemas this recovery is
explicitly forbidden to touch, on the strength of a capture that says nothing about it. Refusing
costs an operator decision; proceeding would be a silent out-of-scope change.

Restricting removal to roles the capture names keeps the property that matters — genuine excess is
removed for every role the recovery is authorized over — without extending the blast radius to
roles it is not. On the LMS pair this branch is never taken: both sides hold the same six groups,
owned by `postgres` and `supabase_admin`, and both roles are in the capture's role set.

**This policy was not in the earlier design.** The first implementation refused *every* target-only
group, which contradicted property 5; the synthetic fixture caught it on the first run.

### Policy: the replay and verification skip rule

An object whose captured ACL is NULL is at PostgreSQL's built-in default. If the target is **also**
still NULL for that object, the two agree already and there is nothing to do. The replay therefore
skips it, leaving the ACL NULL rather than materialising the default edges explicitly.

Without that rule the recovery would rewrite every untouched object's ACL from NULL to an explicit
array — on the LMS pair, all 13 row types plus every relation and routine that has never been
granted on — creating provenance drift with no security benefit whatsoever.

The verification mirrors the same predicate. A synthesized default edge belonging to an object that
is NULL on both sides is **not** expected to appear in the target enumeration, and must not be
reported as a missing captured edge. The first implementation omitted this mirror and aborted with
"36 captured edges missing" — a false failure, caught by the artifact's own verification rather
than by inspection.

Two boundaries make the rule safe:

  * **Columns are excluded from it.** A NULL `attacl` means "no column grants at all", not "fall
    back to a default". A column edge is always replayed.
  * **Only the default-edge case is exempt.** The skip applies solely where source and target are
    both at the built-in default. Any real difference in effective privilege — a missing captured
    edge on an object that is not at its default, or any target-only edge anywhere — still fails
    the verification and rolls the entire run back.

### The approved provenance residual, precisely

PostgreSQL does not restore a NULL ACL. Once an object's ACL has been materialised, revoking back
to `acldefault` leaves an explicit array, not NULL — tested directly. So an object whose captured
ACL is NULL, and whose target has diverged, necessarily ends the run holding an explicit ACL
byte-equal to its built-in default.

The permission for that residual is **source-derived and conditional, not blanket**:

  * The **permitted set** is computed from the source capture alone: every object whose captured
    ACL state is NULL. For the LMS capture that is **18** objects — 2 routines, 3 sequences and 13
    row types — listed by class and identity in the manifest.
  * Permission is **conditional**. A residual is accepted only when the object's effective edges
    are identical to the capture's and the *sole* difference is `default-derived` becoming
    `explicit`. Any difference in grantee, grantor, privilege or grantability fails.
  * Eligibility does **not** license drift. The artifact snapshots each object's provenance state
    **before** the reset, and fails if an object that was NULL before the run is explicit after it.
    An eligible object that the recovery itself pushed from NULL to explicit is a failure, not an
    approved residual.
  * Anything outside the permitted set that differs in provenance fails outright.
  * The permitted count is an upper bound, not a prediction. How many actually drift depends on the
    target: an object NULL on both sides is skipped and does not drift at all. For the LMS pair the
    comparison recorded above predicts **5** of the 18 — the 2 routines and 3 sequences — with the
    13 row types untouched.

### Implementation hazard: PL/pgSQL alias collision

In a `DO` block, a qualified reference such as `e.cls` resolves to a PL/pgSQL **variable** named
`e` in preference to a table alias `e`, and a `record` variable that has not yet been assigned has
no tuple structure. The result is a run-time `record "e" is not assigned yet` from a statement that
reads as ordinary SQL.

The template declares `e` and `g` as record variables, and originally also used `e` as a table
alias inside `create temp table _p2k_want_edge … from _p2k_src_edge e`. That aborted the run. The
aliases are now `se`/`so`, with a comment at the site recording why. **Any future edit to this
template must avoid `e` and `g` as table aliases inside the `DO` blocks.** This is a real hazard
rather than a typo: it fails at run time, not at parse time, so it survives static review.

### Validation results

Nothing below involved the restored LMS stack, staging or production.

| Check | Result |
|---|---|
| Generator determinism | artifact and manifest **byte-identical** across repeated runs |
| Refusal paths | all **11** refuse, exit non-zero, write no file |
| Static lint / parse | the LMS artifact parses in full and aborts in **preflight** against a database it does not describe, mutating nothing |
| Synthetic fixture | 308-row capture: grant options, third-party chains on both a relation and a row type, a grantor cycle, column ACLs including a system column, row types in all three ACL states, standalone types, a sequence, a procedure, default rules across three owners including a strict-subset and an empty rule |
| Synthetic apply | 95 source edges, 17 objects, 12 default groups, 103 default edges, 16 roles → reset 6 passes / 45 revokes, replay 3 passes / 63 grants, `verify ok: 63 edges, 103 default rules, 1 approved provenance residual` |
| Capture parity after apply | **8 differing lines**, every one attributable to the single object drift was injected on — one section E annotation, the two section I rows it now emits, and two section G counts moving to match |
| Repeated-run fixed point | runs 2 and 3 identical (7 passes / 42 revokes, 63 grants); state after run 1 **byte-identical** to state after run 3 |
| Rollback | failure injected after the final replay stage; post-abort capture **byte-identical** to the pre-run capture; a clean run afterwards converged to the same fixed point |

The reset pass count differs between the first run and later ones (6 then 7) because the first
starts from a diverged state and later ones from the converged one. That is convergence from any
starting state, not idempotence — the run repeats the full reset and replay every time.

### Manifest and workload reconciliation

The manifest carries four full 64-character SHA-256 hashes — source capture, generator, template,
generated artifact — each re-verified against the file it names. Every expected workload count was
recomputed independently from the source capture and reconciles: 544 rows, 327 source edges
(7 schema + 245 relation + 75 routine, with sections C and I empty), 71 owned objects, 6 default
groups, 72 default edges plus 6 rule-exists markers accounting for all 78 section F rows, 6 roles,
and 18 objects eligible for the provenance residual.

**No part of this implementation is authorized for execution.** The artifact targets restored
copies only, carries that prohibition in its own header, and has not been applied anywhere.

## Independent adversarial audit — 2026-08-28

Four independent auditors reviewed the generator, template, artifact, manifest and this note
through separate lenses: generator hostile-input handling; SQL safety and PostgreSQL 17.6
semantics; capture-to-artifact completeness and verification correctness; and claims versus
evidence. Each worked read-only on the repository in its own disposable container. Every finding
below was then re-verified independently before any correction was applied; the reproductions
quoted are from that refutation pass, not from the auditors' reports.

**Nothing was refuted.** Every consequential finding reproduced.

### Gating result: none of the algorithm defects can fire on this target

Measured read-only against the restored LMS stack, all zero: domains over array types in `public`;
unscoped default-privilege rules; a role literally named `PUBLIC`; objects with a NULL ACL on the
target; column ACLs; non-owner self-grant edges; grantable edges. The defects below were therefore
latent for this pair — but they were real, and they are fixed rather than documented around.

### Confirmed defects, and what changed

| ID | Defect | Correction |
|---|---|---|
| Injection | `privilege_type` and a routine's argument list are the only capture fields interpolated **unquoted** (`format('%s')`). `EXECUTE` runs multiple statements, and the default-privilege replay runs under `SET ROLE` of a superuser. A payload using `COPY … TO PROGRAM` executed a shell command on the database host **and survived the rollback** — verification cannot undo non-transactional effects | the generator now validates `privilege_type` against an allowlist of PostgreSQL privilege keywords and rejects statement terminators, comment introducers, dollar-quoting and newlines in argument lists. Both refuse at generation time |
| Leaf-peel scope | a column privilege is authorised by a **table-level** grant option, but leaf-peeling grouped by `(cls, ident)`, putting `public.t` and `public.t.col` in different groups. The table revoke then succeeds and **orphans the column grant**: the grantee keeps it and not even the owner can remove it, because only the recorded grantor may revoke and it has lost the authority | enumeration gained an object-family key; a column edge and its parent relation are peeled as one dependency group |
| Self-grant | the predicate excluded every row sharing a grantee, so `owner → X` and `X → X` were **both** leaves. Revoking the owner edge first gives `ERROR: dependent privileges exist`; which happened depended on the plan | the exclusion is now the identical row only, plus an explicit carve-out so two self-grants by the same role do not block each other (without it the owner's own aclitems deadlocked) |
| Subset-of-default | granting onto a **NULL** ACL materialises `acldefault` alongside the granted edge. Any captured ACL that is a strict subset of the default — `REVOKE EXECUTE … FROM PUBLIC` on a routine, the ordinary Supabase pattern, and the shape of **39 of the 41** captured routines — left extra edges and aborted **identically on every retry** | a TRIM phase after the replay removes anything present but not wanted, leaf-peeled like the reset |
| `SET ROLE` test | preflight used `pg_has_role(…, 'USAGE')`, which reports inheritance. Since PG 16 that is independent of `SET` capability: measured `USAGE=t/SET=f` for one membership and `USAGE=f/SET=t` for another. The first passes preflight and then dies **mid-reset, after mutations** | the test is now `'SET'`, and object owners are included because a NULL-ACL type's default edges are synthesized with the owner as grantor |
| `PUBLIC` role | `CREATE ROLE "PUBLIC"` is accepted and renders identically to the grantee-0 pseudo-role in both capture and enumeration, so replay would silently convert grants between them and verification is blind | preflight refuses when such a role exists |
| Domain over array | a domain over an array has `typtype='d'` but `typcategory='A'`, so the filter meant to exclude true array types (where `GRANT` really is refused) also hides it — from the capture **and** from the target enumeration, so the "no target object absent from the capture" guard cannot see it either. Such a type is genuinely grantable and enforced | preflight refuses when one exists. **The capture query still has this hole and needs a separate fix plus a re-capture** — see remaining gaps |
| Unscoped excess rules | a target-only **unscoped** default-privilege rule was deleted whenever its owner was named anywhere in the capture. Unlike an object grant it governs future objects in **every** schema, so this reached into platform-managed schemas | only `IN SCHEMA public` target-only rules are removable; unscoped ones fail closed |
| Concurrent DDL | the transaction is READ COMMITTED with no lock on `public`, and the object-inventory check ran once. An object created after preflight had its entire ACL stripped and the run **committed reporting success** | verification re-checks the inventory before commit, so such a run rolls back |
| Pass cap | `exit when passes > 200` left the loop with no assertion, so a silently incomplete reset could reach commit | both reset loops now assert zero remaining edges |
| Schema NULL/NULL | the object replay skips objects already at the built-in default; the schema replay did not, yet verification's provenance check covers `schema` — so **two identical databases** aborted on the artifact's own check | the same guard is applied to the schema replay |
| Grantor USAGE | a grantor that already lacks `USAGE` on `public` aborts mid-reset | preflight checks it up front |
| Alias shadowing | `n` was a declared scalar and also a table alias in preflight check 8, resolving correctly only because it is scalar | renamed, with the hazard noted |

Counter reporting was also corrected: the schema and object replay phases shared one counter, so the
object notice printed a running total.

### Contract amendment: what verification does and does not cover

Contract 1 lists section H — role existence, attributes, membership, inheritance — under "must
match exactly; any difference is a failure". An earlier implementation did not honour that and did
not disclose the deviation. **Section H is now implemented** (see "Closing the audit gaps"). What
remains true:

  * The generator consumes sections A–F, H and I. **Section G is deliberately not consumed** — see
    below for why it need not be.
  * Preflight now verifies the captured role graph exactly — attributes for every role in the
    closure, and every membership among those roles including its grantor, `admin_option`,
    `inherit_option` and `set_option`, compared in both directions. Roles are never mutated: a
    divergence is a refusal.
  * Verification performs four checks: ACL-edge parity, default-rule parity, ownership unchanged,
    and the provenance residual. It reads no RLS state.
  * **"Exact effective-security parity" in the property list means ACL-edge parity**, proven with
    set equality — not the `has_*_privilege` probing used in the synthetic experiments. Edge parity
    implies effective parity **only because the role graph is unchanged**, which the artifact
    assumes and does not verify. Role membership does change effective access: a grant to a role
    the target's members no longer belong to confers nothing, and verification would still pass.
  * **RLS remains a separate verification responsibility.** Two databases can pass every check in
    the artifact and still differ in their row-level security state and policies.

### Operating the artifact

The audit found no runbook, and the gap is load-bearing rather than pedantic.

  * **Connect as `supabase_admin`.** Not `postgres`: `postgres` cannot `SET ROLE` to
    `supabase_admin`, which the default-privilege phase must act as, and preflight aborts.
  * **Confirm the target database yourself.** The preflight cannot detect which database it is
    connected to, and it would **pass against staging itself**, whose objects, owners and roles are
    by construction exactly the capture's. A production database carrying the same application
    schema would also pass and be overwritten. This is the artifact's most important limitation and
    the only control on it is the operator.
  * **Quiesce the target.** The advisory lock excludes other runs of this script, not concurrent
    DDL. Verification now catches an object created mid-run and rolls back, but the run is wasted.
  * **Expected notices**: preflight, reset objects, reset schema, reset complete, replay schema,
    replay objects, trim, replay defaults, and finally `verify ok`. Absent `verify ok` immediately
    before `COMMIT`, nothing was applied.
  * **A structurally drifted restore refuses outright.** One extra object in `public` — a target one
    migration ahead — aborts the whole run. There is no partial mode and no resume.
  * **After a failure, do nothing.** It rolls back completely; re-running is safe and converges.
  * **Verify afterwards** by re-running the capture and diffing against the source. The expected
    residual is 13 edge rows plus 5 ownership annotations, on the 2 routines and 3 sequences named
    above. Compare under the effective-security contract, not the provenance contract.

### Remaining gaps, not fixed here

  * ~~The capture query cannot represent a domain over an array type.~~ **CLOSED** — see "Closing
    the audit gaps". The capture query changed, so the pinned staging capture is superseded.
  * ~~The `SCOPE` block wrongly lists row types as derived.~~ **CLOSED** — corrected in the same
    change.
  * ~~A captured `empty` ACL cannot be restored onto a NULL target.~~ **CLOSED** — the replay now
    materialises `{}` explicitly.
  * **The synthetic evidence in earlier sections is not reproducible.** Those fixtures lived in
    containers that were destroyed; no fixture SQL, capture or transcript is committed or hashed.
    The source capture, generator, template and artifact **are** hash-pinned and were reproduced
    byte-for-byte during this audit; the experiment narratives are not.
  * The "Capture validation — local stack only" section is a historical snapshot (837 rows, E 58,
    F 96, no sections I or J) carrying the same date as current material. Its figures are internally
    consistent for the file it describes but do not match the current capture.

### Re-validation after the corrections

The corrected algorithm was re-proven on a fixture built specifically around the newly fixed cases:
a self-grant under a grant option, a column grant made under a table-level grant option, and a
routine whose ACL is a strict subset of the built-in default applied to a target where that ACL is
NULL. All three previously failed; all three now succeed.

| Check | Result |
|---|---|
| Apply | `reset objects: 4 passes, 28 revokes` · `replay objects: 30 grants` · `trim materialised defaults: 1 revoke` · `verify ok: 45 edges, 96 default rules, 0 residual` |
| Subset-of-default routine | restored to exactly `{own_r=X/own_r,rb=X/own_r}` — previously an unrecoverable abort |
| Self-grant and column-under-grant-option | both restored exactly; the reset no longer depends on row order |
| Capture parity | re-capture after apply **identical** to the source capture, zero differing lines |
| Fixed point | runs 2 and 3 identical; state after run 3 byte-identical to after run 1 |
| Rollback | injected mid-run failure; state byte-identical to before the run |
| New preflight guards | the `PUBLIC` role, domain-over-array and unscoped-target-only-rule guards each observed firing, and the domain guard observed *not* firing once the domain is dropped |
| LMS artifact | still aborts in preflight against a database it does not describe; regenerated byte-identically across runs |

## Closing the audit gaps — 2026-08-28

Everything the four-lens audit left open is now closed, with one consequence that must be read
before anything is applied: **the capture query changed, so the pinned staging capture, the
generated artifact and its manifest are superseded pending regeneration.** They are retained for
review and are marked as such in the artifact header and the manifest's `status` field. Nothing
was applied anywhere; staging was not contacted.

### Domains over arrays are now captured

An ACTUAL array type is the one PostgreSQL auto-created for some element type — it is that
element's `typarray`. The old predicate excluded by `typcategory = 'A'`, which also caught a
**domain over an array** (`typtype 'd'`, `typcategory 'A'`), a type that is independently grantable
and enforced. Proven in isolation on 17.6:

| Case | Result |
|---|---|
| actual array type | `GRANT` refused: `cannot set privileges of array types` |
| multirange type | `GRANT` refused: `cannot set privileges of multirange types` |
| domain over an array | `{own_r=U/own_r,rb=U*/own_r,third=U/rb}` — grant option **and** third-party grantor round-trip |
| enforcement | a role without USAGE gets `permission denied for type d_arr` declaring a column of it; a role with USAGE succeeds |
| new predicate over all 14 types in the fixture | 7 true arrays excluded, multirange excluded, domain-over-array **included**, everything else unchanged |

The predicate is now `not exists (select 1 from pg_type et where et.oid = t.typelem and et.typarray
= t.oid)`, applied identically in the capture and in the recovery's target enumeration — they must
mirror each other or the fail-closed "unknown object" guard has a hole matching the capture's. The
stale `SCOPE` block that called row types and arrays "derived, not independently grantable" is
corrected.

### Empty ACLs can now be restored

`{}` and NULL are different states: NULL means the built-in defaults apply, `{}` means nobody holds
anything, not even the owner. The replay had no edge to grant for an empty ACL, so an object
captured as empty whose target still held NULL was unreachable and verification refused.

Tested for schema, relation, sequence, routine and type. One sequence works for all five:

```
GRANT <one privilege> ON <class> <object> TO <owner>;
REVOKE ALL ON <class> <object> FROM <owner>, PUBLIC;
```

The grant forces the ACL into existence; the revoke empties it. `<owner>` and `PUBLIC` are the only
two principals `acldefault` ever names, so nothing else can survive. **Owner-effective rights are
preserved in the sense that matters**: ownership is not an ACL right, so after the ACL reaches `{}`
the owner still holds no *granted* privilege (correct — that is what `{}` means) but retains full
ownership authority and can still `ALTER` and re-`GRANT`, which was verified directly.

Schemas are materialised last, after the default-privilege phase, because emptying `public` removes
USAGE from everyone and would break any object work that followed. `ALTER DEFAULT PRIVILEGES … IN
SCHEMA` does not require USAGE, so the default phase is unaffected. Any object class outside those
five **fails closed** in preflight rather than being silently skipped.

### Role-context verification is implemented

The generator now consumes section H and stages the captured role closure: attributes for every
role, and every membership among those roles with its grantor, `admin_option`, `inherit_option` and
`set_option`. Preflight compares both **in both directions** — a captured membership that is
missing or altered, and a membership the target has that the capture does not record, are each a
refusal. Roles are never created, altered or dropped; a divergent role graph is a refusal, not a
repair.

This matters because ACL-edge parity implies effective-access parity **only while the role graph is
unchanged**: a privilege held by a group confers nothing on a principal that is no longer a member.
The capture's role closure is recursive and bidirectional, so a role that holds no direct grant but
belongs to a group that does is pulled in — verified in the harness by a `memb -> grp` edge where
`memb` holds nothing directly.

**Section G is derived, and is deliberately not replayed.** Its rows are counts of grantees observed
in sections A–D — an aggregate of the very edges the artifact already replays individually. A G row
cannot carry information that is not derivable from those edges, so replaying it would be replaying
the same facts twice, and verifying it would be verifying the artifact against its own output. The
G counts do move when the recovery removes excess, which is the expected consequence of fixing the
edges, not an independent fact to restore.

### Reproducible test harness

`scripts/test_phase_2k_acl_recovery.sh` builds a disposable PostgreSQL 17.6 database, populates it
with every supported class and ACL state, captures it with the committed capture query, generates a
real artifact with the real generator, diverges the target in both directions in every class,
applies, and asserts. `scripts/p2k_parity_check.py` does the capture comparison and classifies each
difference. **43 assertions, all passing**, covering:

  * every relation kind with a row type, sequences, columns including a **system column** (`ctid`),
    routines (function and procedure), and all five type classes including a **domain over an array**
  * NULL, empty and explicit ACL states, and a routine ACL that is a strict **subset** of the
    built-in default
  * third-party grant chains on both a relation and a row type, a self-grant, and a column grant
    made under a table-level grant option
  * scoped and global default-privilege rules, including a strict-subset rule and an empty rule
  * role-graph parity **and four deliberate mismatches** — a removed membership, a changed
    `admin_option`, an extra membership, and a changed role attribute — each refused before any
    mutation, with the privilege state proven untouched
  * rollback from an injected mid-run failure, and fixed-point convergence across three runs
  * twelve generator refusal cases, including the injected `privilege_type` and routine-argument
    payloads

One harness defect found while building it is worth recording, because it would silently corrupt
any future test: **`pg_isready` returns before the Supabase image finishes initialising**, and the
entrypoint alters `anon`/`authenticated`/`service_role` after that point. Capturing inside that
window records role attributes that then change underneath the run, which reads as a role-graph
divergence that never happened. The harness now waits for `pg_roles` to stop moving before it does
anything.

### Artifact provenance is now pinned to the capture query

The artifact header and manifest carry the SHA-256 of
`supabase/discovery/phase_2k_acl_capture.sql` alongside the source-capture hash. A capture produced
by a different query version may describe a different set of objects, and the artifact would then
be reasoning about facts the capture never recorded. The generator also accepts `--superseded`,
which stamps a `DO NOT APPLY` banner into the artifact and sets the manifest `status`.

### Target confirmation — read this before running anything

This procedure replaces the earlier note that the operator "must confirm the target".

  1. **The artifact is for a restored copy on this machine only.** It is not for staging, not for
     production, and not for any hosted database. The only sanctioned target is a local container
     holding a restore.
  2. **Connect as `supabase_admin`.** The default-privilege phase must `SET ROLE` to the rules'
     owners, and `postgres` **cannot** `SET ROLE` to `supabase_admin` — preflight aborts with
     `current_user cannot SET ROLE to supabase_admin`. `postgres` is insufficient; this is not a
     preference.
  3. **The preflight is not a project-identity guarantee.** It verifies structure — objects,
     owners, roles, schema classification — not *which database you are connected to*. Staging
     itself would satisfy every structural check, because the capture was taken from it. A
     production database carrying the same application schema would also pass.
  4. **Verify the connection yourself, immediately before running.** Confirm the container name and
     that it is a local restore, e.g. `docker ps` shows the expected local container and
     `psql -c "select current_database(), inet_server_addr(), inet_server_port()"` shows a local
     address — not a hosted endpoint. Confirm no `PGHOST`/`PGSERVICE`/`DATABASE_URL` in the
     environment points elsewhere. If any of that is unclear, stop.
  5. **Quiesce the target.** The advisory lock excludes other runs of this script, not concurrent
     DDL. Verification catches an object created mid-run and rolls back, but the run is wasted.
  6. **Expect `verify ok` immediately before `COMMIT`.** Without it, nothing was applied.

### Status of the pinned artifact

| Item | State |
|---|---|
| Fresh source capture `phase_2k_acl_capture_staging_2026-08-28_v2.csv` | **CAPTURED AND VERIFIED.** The amended query (`0a83294ad9abbdf37cd7ac49e306f4696d9eb9a0c132708e1545f651e0e669d6`) was run once against operator-confirmed staging `evhiixndiuwwodsouyhf`; it returned 544 rows. The owner-only CSV remains outside the repository and has SHA-256 `7c3164fda5ed8e534a2a6e2cdd6b82386a1a9ab53f397c2b31fb917819ce829c`. Its byte identity with the earlier CSV shows that the amended domain-over-array coverage found no additional staging rows; it does not make the earlier query version current. |
| Replacement artifact `phase_2k_acl_recovery_staging_7c3164fd_q0a83294a.sql` | **SUPERSEDED AFTER A SAFE PREFLIGHT REFUSAL — DO NOT APPLY.** Its first restored-local invocation exited before reset because it required the hosted temporary role `cli_login_postgres`. A capture immediately before and after the refusal was byte-identical, proving no mutation. Artifact SHA-256 before supersession: `38fd14377587f245067c242ecc687332c13bbb93ad623c65a5ed1d7ad2df6ac5`. |
| Replacement manifest | marked `SUPERSEDED - local preflight required hosted temporary role`; its prior `review pending, NOT applied` status is historical |
| Corrected `_r2` artifact | **APPLIED SUCCESSFULLY TO THE DISPOSABLE RESTORED-LOCAL COPY ONLY.** Exit 0 and `COMMIT`; in-transaction verification found 327 edges, 72 default rules and 5 approved provenance residuals. Independent post-run parity found 0 missing, 0 extra and 0 residual effective-security facts. Never applied to staging or production. |
| Superseded artifact and manifest without `_q0a83294a` | **SUPERSEDED — DO NOT APPLY.** Retained for review history only. |
| Next step | record and review the successful local evidence, then obtain explicit operator acceptance or rejection of recovery-envelope items 1 and 7. No hosted database is an authorized recovery target. |

### Restored-local preflight finding: hosted role context must be projected

The first invocation of the `_q0a83294a` artifact against the confirmed local container
`supabase_db_last_man_standing`, over a Unix-domain socket as `supabase_admin`, stopped in preflight:
the staging capture contains `cli_login_postgres`, while the restored copy does not. The role is a
temporary hosted Supabase CLI login, has no in-scope ACL edge, ownership or default-privilege rule,
and was already classified above as not required for recovery. Creating it locally would reproduce
hosted platform access state rather than application database security. The refusal occurred before
the reset; read-only captures taken immediately before and after were byte-identical (867 rows).

The capture remains deliberately forensic and follows membership in both directions. The generator
now projects Section H to the **access-relevant upward closure**:

1. Seed every non-`PUBLIC` role named by an in-scope ACL edge, object owner, default-rule owner or
   default-rule grantee.
2. Follow membership only from member to granted role, because those groups can add access to a
   seeded principal.
3. Include each retained membership's grantor, then repeat upward closure to a fixed point.
4. Verify attributes for every projected role and every membership whose two endpoints are in the
   projection, in both directions. Roles and memberships are still never mutated.
5. Record every captured but downward-only role in the manifest. Exclusion is fact-driven, not a
   role-name allowlist: if any such role is named by a future in-scope fact, it becomes a seed and
   cannot be excluded.

For the real 544-row staging capture this produces 15 projected roles and 15 membership edges, and
records five downward-only hosted roles: `cli_login_postgres`, `supabase_etl_admin`,
`supabase_read_only_user`, `supabase_realtime_admin`, and `supabase_storage_admin`. The six roles
directly named by ACL/ownership/default facts remain unchanged. This narrows the role-context claim:
recovery proves effective access for the in-scope database principals and their upward groups; it
does not attempt to reproduce which hosted control-plane principals may assume those roles.

## Audit corrections — 2026-08-28

An adversarial review (50 agents, 4 lenses) confirmed 18 findings after refutation. Classification
and disposition:

| # | Finding | Class | Disposition |
|---|---|---|---|
| 6 | `GRANT … GRANTED BY` rejected for object privileges | **substantive blocker** | verified independently; banner added; §6 mechanism void |
| 7 | Reset is grantor-blind and does not converge | **substantive blocker** | verified independently; banner added; §1/§4 claim false as written |
| 8 | Replay lacks grantor-dependency ordering | **substantive blocker** | banner added; capture's total order sorts dependents wrongly |
| 10 | Owner exemption bakes in the one-directional assumption | **substantive blocker** | recorded as an open defect in §1 |
| 9, 12 | Contract 2 self-contradictory — section E `acl_source` also changes | correctness | second pre-approved difference added |
| 1 | Section E schema row lacked the null/empty annotation | correctness | fixed in the capture |
| 2 | `pg_type.typacl` never captured | completeness gap | recorded in the capture's scope block and here |
| 3 | Empty `defaclacl` left no trace | completeness gap | unconditional existence row added to section F |
| 4 | `attnum > 0` excludes system columns on an unstated assumption | completeness gap | assumption now stated in the capture |
| 5 | Scope limits lived only in this note | completeness gap | scope block added to the capture itself |
| 11 | `PUBLIC` claimed present in section H | correctness | corrected — it is in G only, by construction |
| 13 | "byte-identical" container claim | correctness | corrected to "unchanged on every dimension checked" |
| 14, 15 | Coverage overclaimed as "validated for all A–H" | correctness | narrowed; union-across-two-databases stated |
| 16 | "public only" untrue — section F includes all-schemas rules | correctness | corrected |
| 17, 18 | Cross-references pointed at §6/§7 instead of §8 | correctness | fixed |

No finding was dismissed as a false positive. Findings 6 and 7 were re-verified by direct
execution on a disposable PostgreSQL 17.6 container rather than accepted on the reviewers' word,
because two review agents ran while the safety classifier was unavailable.

## Status

The **capture** is sound, its corrections are applied, and it now covers type privileges, system
columns and an explicit fail-closed schema-scope contract. The **recovery algorithm has been
proven in isolation** across all six supported classes — exact effective-security parity, exact
grantor graph, exact default-rule parity, complete removal of target-only excess, atomic rollback
and fixed-point convergence — after two further defects found during that cycle were corrected.

What is still blocked is **authorization**: the artifact exists but running it is not approved, and the
algorithm has never run against a Supabase-hosted database. Two limits remain, and neither is a
gap in what is claimed: object classes outside the scope contract are unimplemented and refuse
rather than pass, and row-level security is verified by separate artifacts rather than represented
as an ACL here. The relation-backed row-type gap is closed.

A real source capture now exists and has been compared against the restored target — see "Staging
vs restored-local comparison". The divergence is 322 target-only excess grants with **zero**
source-only grants, zero grantability, grantor and ownership differences, and no role or
schema-scope blockers. Every construct in it is a strict subset of what the algorithm has been
proven against.

The next step is review of this note, of the amended capture, and of the recovery specification.
Applying the artifact remains a separate decision that this note does not make.
