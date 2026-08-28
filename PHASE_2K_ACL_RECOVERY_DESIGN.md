# Phase 2K — ACL Recovery Mechanism: Design Note

**Design only. No executable repair SQL exists, and none is authorized by this note.**

> ## ⛔ THIS DESIGN IS NOT SAFE TO BUILD ON — three mechanisms are empirically disproven
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
> The blocker is retained because the tested algorithm is **incomplete**: it covers relation,
> column and routine privileges only. **Schema privileges and default-privilege rules were
> neither reset nor replayed**, and both are required. An algorithm that silently leaves the
> target's own default-privilege rules in place would re-introduce excess on every object created
> after recovery — the exact defect this work exists to fix.
>
> **Consequence:** the *capture* format is sound and validated; the *recovery mechanism* is not.
> Generating an executable artifact from this note would produce a repair that silently fails to
> remove third-party grants while reporting success. The sections below are retained as the
> starting point for a corrected design, **not** as an approved specification. Every claim they
> make about reset, grantor preservation and convergence must be re-derived against the behaviour
> above.
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
| Capture query | written; executed and deterministic on the local stack **and** in a synthetic container. Section C field-asserted; A, B, D–H structurally validated only |
| Output format | proposed, **awaiting review** |
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

The **capture** is sound and its corrections are applied. The **recovery mechanism is not safe to
build on** — see the banner at the top. The next step is not generating repair SQL; it is
redesigning reset, grantor preservation and replay ordering against the demonstrated PostgreSQL
behaviour, then re-reviewing.
