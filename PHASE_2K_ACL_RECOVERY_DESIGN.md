# Phase 2K — ACL Recovery Mechanism: Design Note

**Design only. No executable repair SQL exists, and none is authorized by this note.**

> ## ⛔ NOT AUTHORIZED TO BUILD — proven in isolated containers only
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
> 1. **No executable artifact is authorized.** None exists, and this note does not approve one.
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
inspects that object's current ACL on the target and revokes every non-owner grantee it finds —
including grantees that appear nowhere in the source capture.

> **Open defect (audit finding 10):** exempting the owner makes the target's floor the owner's
> full default rights, so a source object with an empty ACL — a real, deliberate state produced
> by revoking the owner's own privileges — can never be reproduced. That silently bakes in the
> one-directional assumption this note elsewhere warns against. The capture already distinguishes
> `acl empty: no privileges` from `acl null: defaults apply` in section E; the reset must honour
> that distinction rather than assume the owner always retains everything.

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
| Output format | proposed, **awaiting review** |
| Recovery algorithm | proven in isolated containers across all six supported classes — seven properties, one atomic transaction. **Still not generated as an executable artifact, and not authorized to be** |
| Recovery artifact | **not designed in executable form, not generated, not applied** |
| Gate | `NOT READY` — unchanged by this note |

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
holds **0** columns with a non-NULL `attacl` and **0** grantable-class types. The two new sections
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

What is still blocked is **authorization**: no executable artifact exists or is approved, and the
algorithm has never run against a Supabase-hosted database. Two limits remain, and neither is a
gap in what is claimed: object classes outside the scope contract are unimplemented and refuse
rather than pass, and row-level security is verified by separate artifacts rather than represented
as an ACL here. The relation-backed row-type gap is closed.

The next step is review of this note and of the amended capture. Generating repair SQL remains a
separate decision that this note does not make.
