# Last Man Standing — Phase 2 Preparation Report

Date: 2026-08-23  
Repository branch: `feature/lms-integrity-phase-1`  
Repository commit: `ef226e66e96449b84539c41f8acb7062e899b76d`

This report records read-only remote inspection and product-rule analysis. No remote project was linked, no data was read or changed, no migrations were applied, and no application code or Phase 2 migration was created.

## 1. Repository baseline

The working tree was clean at the requested Phase 1 ending commit. Phase 1 is represented by the forward-only migration `20260823000100_lms_integrity_phase_1.sql`; it has not been deployed remotely. `origin/main` remains at `d09613e4b4b34917be12126399eb7be52395b61f`.

Expected database order is Modules 1–22, P1 result provenance, P2 result corrections, then Phase 1 integrity. The repository contains the source modules, P1/P2 SQL and verification material, and the Phase 1 migration. Prior local Phase 1 evidence records 60 passing tests, a passing production build, zero audit vulnerabilities, and a passing disposable PostgreSQL/Supabase regression run.

## 2. Remote environment identity

Identity was established from the authenticated Supabase account's read-only project list and corroborated by application configuration/documentation.

| Environment | Project ref | Region | Evidence | Confidence |
|---|---|---|---|---|
| Production | `enzdvsppduyqtpdeseyh` | `eu-west-3` | Authenticated project named `GRM1106's LMS`; ref matches the browser client/CSP | High |
| Staging | `evhiixndiuwwodsouyhf` | `eu-west-1` | Authenticated project named `last-man-standing-staging`; matches P2 deployment record | High |
| Preview/test database | None identified | — | Authenticated account returned only the two projects above; Vercel previews use the production Supabase ref unless separately configured | High for “none in this account”; external projects remain unknowable |

Both projects were `ACTIVE_HEALTHY` when listed. A Vercel preview deployment is not an independent database environment.

## 3. Production schema parity

Production has no rows in the remotely visible Supabase migration history. A schema-only dump nevertheless shows the Modules 1–22-era application objects, including the baseline versions of `sync_fpl_data`, `process_pot_gameweek`, `get_pot_selection`, `confirm_team_pick`, `assign_random_missing_picks`, and `get_pot_standings`, with the expected baseline RLS policies and function ACL pattern.

Production does **not** contain P1 provenance columns/constraints, the P1 snapshot immutability trigger, P1 audit/history tables, P2 override/audit objects, `pots.review_status`, or the P2 functions `get_admin_fixture_results`, `get_effective_fixture_result`, `preview_fixture_result_override`, `create_fixture_result_override`, `fixture_override_impact`, and `fixture_effective_version`. Phase 1 is also absent.

Classification: **REQUIRES CONTROLLED CATCH-UP**. The schema is behind, not proven drifted. Because its modules were apparently installed outside recorded migration history, a reviewed preflight and definition comparison are mandatory before calling it an exact Modules 1–22 baseline.

## 4. Staging schema parity

Staging migration history contains exactly `20260821000100` through `20260821002300` and `20260822002400`; Phase 1 `20260823000100` is local-only. Its schema-only dump contains all required P1/P2 provenance, immutability, override, audit, review, function, constraint, trigger, RLS, and ACL objects. The listed critical functions are all present with the expected hardened exposure: client RPCs are revoked from `PUBLIC` and granted to `authenticated`; internal helper functions are not client-granted.

Classification: **READY FOR PHASE 1**, subject to the backup/operator gate and an approved deployment runbook. This is readiness evidence, not deployment approval.

| Environment | 1–22 | P1 | P2 | Function parity | ACL parity | Safe Phase 1 prerequisite? |
|---|---:|---:|---:|---|---|---|
| Production | Present in schema; history absent | No | No | Behind | Baseline ACLs present; P1/P2 ACLs absent | No |
| Staging | Yes | Yes | Yes | Yes for expected baseline | Yes for expected baseline | Yes, conditional |

## 5. Phase 1 deployment readiness

- **Staging:** prerequisite schema is confirmed. A later, separately approved deployment may apply only `20260823000100_lms_integrity_phase_1.sql`, then run the safe verification path. Do not run destructive/failure seed scripts remotely.
- **Production:** blocked. The sequence requiring later review is: (1) establish/approve a restorable backup; (2) execute P1 preflight; (3) reconcile untracked Modules 1–22 schema with the P1 preconditions; (4) apply P1 `result_provenance_foundation.sql`; (5) verify P1; (6) apply P2 `result_corrections.sql`; (7) verify P2 with production-safe schema/security checks only; (8) apply Phase 1; (9) verify Phase 1. Each step needs a stop/go checkpoint. Do not mark historical migrations as applied merely to make history look complete.

Overall status: `REMOTE DEPLOYMENT BLOCKED — PRODUCTION REQUIRES CONTROLLED CATCH-UP AND RECOVERY READINESS`.

## 6. External checks still required

The Supabase backup API reported `walg_enabled: true`, `pitr_enabled: false`, and no returned backups for both projects. This does not prove that an operator-restorable backup is available.

- Backup availability and retention: **UNVERIFIED — OPERATOR CHECK REQUIRED**.
- Point-in-time recovery: disabled on both projects.
- A fresh, tested logical backup immediately before production catch-up: **OPERATOR ACTION REQUIRED**.
- Restore target, restore credentials, recovery time objective, and named rollback owner: **UNVERIFIED — OPERATOR CHECK REQUIRED**.
- Migration rollback is forward recovery: P1/P2/Phase 1 have no approved down migration. A failed transactional migration rolls back automatically; a successful but faulty deployment requires restoring the backup or an independently reviewed compensating migration.
- Supabase plan limits, dashboard backup policy, Auth settings, Vercel environment-variable separation, and any project outside the authenticated account remain unverified.

## 7. Rule decision matrix

Every recommendation below is advisory. Every row remains `PRODUCT OWNER DECISION REQUIRED`.

| Rule | Current behavior | Recommended default | Decision status |
|---|---|---|---|
| Draws | Draw eliminates | Keep draw = elimination | UNDECIDED |
| Zero survivors | Everyone is eliminated; no resolver | Reinstate players active at round start and replay the round | UNDECIDED |
| Multiple survivors after GW38 | No terminal rule | Split prize equally | UNDECIDED |
| Postponed fixture | Non-final result blocks processing | Void that pick for the round; player survives; team remains used | UNDECIDED |
| Abandoned fixture | Can be recorded, but blocks processing | Await official disposition, then treat as finished or void | UNDECIDED |
| Void/cancelled fixture | Can be recorded, but blocks processing | Player survives; team remains used | UNDECIDED |
| No unused team | Random assignment/round cannot proceed | One full team-pool reset, then normal no-reuse resumes | UNDECIDED |
| Missed selection | Admin-triggered eligible random pick | Keep random among eligible unused teams | UNDECIDED |
| Late joining | Admin can add in draft/open, even after play may have begun | No joining after the first pot deadline | UNDECIDED |
| Unpaid entrant | Blocks processing while active | Auto-withdraw/exclude at first deadline unless paid | UNDECIDED |
| Approval revocation | Blocks new picks/dashboard but does not remove membership | Separate account access from tournament membership | UNDECIDED |
| Pot lifecycle | Partly enforced, semantics incomplete | Adopt the lifecycle contract below | UNDECIDED |
| Result corrections | Review flag; no historical rewrite | Corrections inside a short window may trigger adjudication; otherwise freeze | UNDECIDED |
| Downstream correction | No replay | Hybrid correction window plus controlled manual adjudication | UNDECIDED |
| Fixture moved GW | Phase 1 flags/blocks | Original-round re-pick if time permits; otherwise void-survive | UNDECIDED |
| Participants changed | Phase 1 flags/blocks | Void original pick and allow re-pick; otherwise survive | UNDECIDED |
| Deadline | Stored first kickoff, permanently closes once passed | Configurable per pot, default official FPL deadline; never reopen | UNDECIDED |
| Buy-back | One-time, claim before next kickoff, admin decision | One per pot; next round only; approval before its deadline | UNDECIDED |
| Winner | Manual admin crown with one active player and no pending claim | Automatic eligibility, explicit admin confirmation | UNDECIDED |
| Prize model | Fees/status only | Track pot ledger and payouts, not payment execution | UNDECIDED |
| Rule visibility | Material rules not fully shown/versioned | Versioned rules accepted before joining | UNDECIDED |

## 8. Detailed rule analysis

## Rule: B1 — Draws

### Current behaviour
Processing maps a draw to `lost`, eliminating the player.

### Why a decision is required
It is a defining LMS rule and is not adequately disclosed to players.

### Option A — Draw eliminates
Simple, conventional “team must win” rule; keeps attrition predictable. It can produce a zero-survivor round.

### Option B — Draw survives
More forgiving and reduces mass elimination, but changes the product from “pick a winner” to “avoid defeat.”

### Option C — Per-pot setting
Supports house rules but fragments expectations and requires prominent rule/version display.

### Recommendation
Option A as a global default; permit configurability only if different competition formats are genuinely required.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B2 — Everyone remaining loses/draws

### Current behaviour
All active losers are eliminated; zero active players remain and no automatic recovery exists.

### Why a decision is required
The pot becomes terminal without a winner. Buy-backs make “who returns” ambiguous.

### Option A — Reinstate round-start active players and replay
Restores the exact cohort that entered the round; earlier eliminations stay out. Clear and auditable, but consumes another round and needs pick/team-use rollback rules.

### Option B — Split the pot
Fast and final, but rewards losing selections and requires payout support.

### Option C — Roll back to previous survivors / sudden death
Preserves competition, but is effectively Option A unless a new tie-break source is defined; unsupported retrospective criteria are unfair.

### Option D — Include eligible buy-backs
Commercially flexible but unfair unless published in advance; claims pending at the round boundary complicate the cohort.

### Recommendation
Option A: reinstate only players active at round start, restore their team-use state for that round, and replay under a defined next-round mapping. Do not reinstate previously eliminated players; resolve already-valid buy-backs according to their recorded effective time.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B3 — Multiple survivors after GW38

### Current behaviour
No automatic end-of-season resolution exists; winner control requires exactly one active player.

### Why a decision is required
The football data ends and no supported tie-break data exists.

### Option A — Equal split
Transparent and uses no invented data; requires split-winner/payout records.

### Option B — Continue into another competition/season
Keeps a sole-winner goal but creates scheduling, team reset, and consent problems.

### Option C — Published tie-break
Can produce one winner, but only if its data, ordering, and tie handling are defined before entry.

### Recommendation
Option A. Never introduce a retroactive criterion.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B4 — Postponed fixture

### Current behaviour
P2 can represent postponement, but a non-final picked fixture prevents processing; no survival/carry rule exists.

### Why a decision is required
Waiting may block the whole pot for weeks, while transferring the pick changes gameweek and team-use semantics.

### Option A — Void-survive, team remains used
Lets the round finish and avoids a free reuse advantage; the player survives without needing a win.

### Option B — Carry the pick to rearrangement
Preserves the selection but creates overlapping picks and potentially months-long unresolved rounds.

### Option C — Re-pick before the original deadline
Most sporting, but only viable with sufficient notice; needs a fallback after deadline.

### Option D — Whole round waits
Uniform treatment but operationally fragile.

### Recommendation
Option C before deadline; Option A after deadline. Never reopen a passed deadline.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B5 — Abandoned fixture

### Current behaviour
An administrator can record `abandoned`; it remains non-processable and blocks affected processing.

### Why a decision is required
An abandoned match may later resume, replay, be awarded, or be voided.

### Option A — Wait for official disposition
Uses the authoritative result and avoids speculation, but may delay the pot.

### Option B — Immediate void-survive
Keeps play moving, but could conflict with a result later declared official.

### Option C — Admin adjudication
Flexible but inconsistent without strict evidence and audit requirements.

### Recommendation
Option A with a published maximum wait; at expiry, use the void rule through an audited admin decision.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B6 — Void/cancelled fixture

### Current behaviour
`void` can be recorded but has no LMS outcome and blocks processing.

### Why a decision is required
The player cannot obtain the selected win through no fault of their own.

### Option A — Survive; team remains used
Simple and avoids both elimination and a reusable-team windfall.

### Option B — Survive; release team
Compensates the player but gives an advantage over players whose fixtures completed.

### Option C — Re-pick if time permits, else survive
Most competitive, but needs exact cutoff and notification rules.

### Recommendation
Option C before deadline; otherwise Option A.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B7 — No unused team available

### Current behaviour
Manual selection rejects reused teams; random assignment reports no eligible team and processing remains blocked by the missing pick.

### Why a decision is required
Long competitions or narrow fixture rounds can exhaust availability.

### Option A — Automatic survival
Unblocks play but rewards exhaustion and creates strategic distortion.

### Option B — Elimination
Strict but can eliminate a player without a football result.

### Option C — Reset the team pool
Keeps selection meaningful; reset timing must be deterministic.

### Option D — Free choice of any used team
Easy but weakens no-reuse and can repeatedly favour strong teams.

### Recommendation
Option C: one full per-player pool reset when no eligible team exists, recorded visibly; normal no-reuse then resumes.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B8 — Missed selection

### Current behaviour
After the deadline, an administrator can randomly assign one eligible unused team from an unstarted fixture. This is not automatic.

### Why a decision is required
It materially affects survival and administrator discretion.

### Option A — Keep eligible random assignment
Forgiving and already modelled; randomness and admin timing must be auditable.

### Option B — Automatic elimination
Simple and common, but harsh and reduces engagement.

### Option C — Per-pot setting
Supports different stakes, but must be locked and accepted before play.

### Recommendation
Option A, executed automatically at closure with recorded candidate set/seed or equivalent audit evidence; allow Option B only as a predeclared per-pot rule.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B9 — Late joining

### Current behaviour
Admins can add approved players in `draft` or `open`; no first-deadline guard exists.

### Why a decision is required
Late entrants have consumed fewer teams and avoided earlier risk.

### Option A — Close at first deadline
Fair and simple.

### Option B — Allow with historical restrictions
Can grow the pot, but requires assigning used teams/outcomes and a defensible handicap.

### Option C — Admin discretion
Operationally easy but unsuitable for money competitions without a published formula.

### Recommendation
Option A. “Open” must never override the first-deadline cutoff.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B10 — Unpaid entrant

### Current behaviour
An active unpaid/claimed entrant cannot pick and blocks gameweek processing.

### Why a decision is required
One unpaid membership can halt the competition.

### Option A — Exclude/withdraw at first deadline
Deterministic and unblocks play; requires clear notice and audit.

### Option B — Grace period
Friendly but delays or creates conditional participation.

### Option C — Admin override
Handles payment exceptions but risks inconsistent treatment.

### Recommendation
Option A, with an optional published pre-deadline grace period and no retroactive admission.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B11 — Approval revocation

### Current behaviour
An unapproved account loses normal dashboard/pick capability, but existing pot membership/status is not automatically withdrawn.

### Why a decision is required
Account trust/access and contractual tournament membership are different concerns.

### Option A — Separate them
Revocation blocks access while membership remains for explicit adjudication; safest audit model.

### Option B — Automatic tournament withdrawal
Simple but can improperly alter a live competition.

### Option C — Suspension state
Allows temporary access restriction while preserving membership; adds lifecycle complexity.

### Recommendation
Option A, plus an explicit audited tournament withdrawal/disqualification action governed by separate rules.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B12 — Pot lifecycle

### Current behaviour
Statuses are `draft`, `open`, `active`, `complete`. Draft permits test mode, deletion and membership edits; open permits adding but not removing players; active cannot return to another status; complete requires manual winner control. Assigned players can see pots of any status. Payment edits are not status-limited. Pick functions do not currently express a complete lifecycle contract.

### Why a decision is required
Status must be the authoritative gate for visibility and mutation.

### Option A — Strict lifecycle
Draft: admin-only, configure/test/edit. Open: player-visible, join/pay, no test, configuration locked except safe metadata. Active: play/pay reconciliation only, no joining or rule edits. Complete: read-only history/payout administration. Clear, but needs transition validation.

### Option B — Flexible admin lifecycle
Allows exceptions but weakens auditability and fairness.

### Recommendation
Option A. Picks only in open before the first deadline and active thereafter; payment claims in open, confirmation/reconciliation in open/active; no gameplay edits in complete.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B13 — Result corrections

### Current behaviour
P2 appends an official override. Corrections affecting processed/completed pots set `needs_review`; they do not rewrite picks, membership, downstream rounds, or winners. Phase 1 also detects fixture-context mutation and blocks processing.

### Why a decision is required
Correctness can conflict with finality and downstream reliance.

### Option A — Always recalculate
Maximum factual accuracy, but potentially rewrites many rounds and payouts.

### Option B — Historical freeze
Strong finality, but knowingly preserves wrong outcomes.

### Option C — Correction window/hybrid
Corrections before a published cutoff may affect LMS outcomes; later corrections are recorded without competitive rewrite.

### Recommendation
Option C, with two-person approval for consequential changes. Winner/payout revocation requires a separately defined finality boundary.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B14 — Downstream rounds after correction

### Current behaviour
No replay or adjudication engine exists; review blocks further unsafe processing.

### Why a decision is required
An incorrectly eliminated player lacks picks for later rounds, so simple recalculation cannot reconstruct history fairly.

### Option A — Replay chain
Most internally consistent, but technically complex and disruptive; later selections may already be known.

### Option B — Manual adjudication
Handles facts case by case but requires strict powers, evidence, audit and appeal policy.

### Option C — Historical freeze
Simple and final, but tolerates acknowledged error.

### Option D — Hybrid window
Replay only before the next deadline/round; after that, controlled adjudication or freeze.

### Recommendation
Option D: automatic replay only while no dependent round is locked; otherwise a documented two-person adjudication with predefined remedies. Never silently synthesize missing picks.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B15 — Fixture moves to another gameweek

### Current behaviour
Phase 1 detects mismatch against the locked selection snapshot, flags review and blocks processing; it does not choose an outcome.

### Why a decision is required
The original round may lose the match while the destination round may already require another team.

### Option A — Keep the pick with the match
Preserves intent but creates cross-round unresolved state.

### Option B — Void-survive in original round
Operationally clean; team-use treatment must be stated.

### Option C — Re-pick in original round
Competitive if notice arrives before deadline; impossible after closure.

### Recommendation
Option C before deadline; after deadline Option B with the team remaining used. Do not transfer it as the destination-round pick.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B16 — Fixture participant changes

### Current behaviour
Phase 1 detects changed home/away participants and requires review.

### Why a decision is required
The selected team may no longer participate or the matchup risk may materially differ.

### Option A — Void and re-pick before deadline
Restores player choice; needs notification and fallback.

### Option B — Automatic survival
Protects the player but grants a free pass.

### Option C — Preserve pick if selected team still participates
Minimizes disruption, but the opponent change still alters the bargain.

### Recommendation
Option A before deadline; automatic void-survival afterward, with original team marked used.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B17 — Deadline semantics

### Current behaviour
Phase 1 stores the earliest fixture kickoff for that pot/gameweek and permanently closes once it passes. Pre-closure sync may change the derived deadline; closure never reopens.

### Why a decision is required
Official FPL deadlines and first kickoff can differ; rescheduling affects notice and fairness.

### Option A — First kickoff
Data is already available and prevents picks after play starts, but can move unexpectedly.

### Option B — Official FPL deadline
Matches player expectations, but requires a reliable additional source.

### Option C — Admin-defined/per-pot
Supports house rules, but needs lock/freeze controls and audit.

### Recommendation
Hybrid per-pot setting, default official FPL deadline with first kickoff as a hard upper bound. Pre-deadline movement may only make the deadline earlier with adequate notice or later before it has closed; a closed round never reopens.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B18 — Buy-back

### Current behaviour
Each membership starts `available`; after a recorded loss, one claim may be submitted before the next gameweek's first kickoff. Admin approval restores `active` and marks it `used`; rejection resets it to `available`, permitting resubmission. Pending claims block winner completion. Payment for the buy-back is not separately modelled.

### Why a decision is required
Claim count, payment, timing, zero-survivor interaction and final-round behavior are incomplete.

### Option A — One per pot, next round only
Clear and close to current behavior; require paid/approved before the next deadline and prohibit after the final scheduled round.

### Option B — One per elimination
Increases retention/revenue but undermines LMS attrition.

### Option C — No buy-backs
Simplest sporting model but changes the existing product.

### Recommendation
Option A. A rejection may be resubmitted only before the same deadline if the reason is curable. Buy-backs effective before a zero-survivor round starts count in its round-start cohort; later claims do not resurrect that round.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B19 — Winner determination

### Current behaviour
An admin manually crowns when exactly one active player remains, at least one round was processed, and no buy-back claim is pending. Phase 1 prevents test/draft pots from being crowned and review status prevents unsafe completion.

### Why a decision is required
The precise finality point controls correction, buy-back and payout exposure.

### Option A — Fully automatic completion
Fast and consistent, but could finalize before corrections/claims settle.

### Option B — Manual confirmation
Provides a control gate but can be delayed or misused.

### Option C — Automatic eligibility, manual confirmation
System proves all conditions; admin attests finality.

### Recommendation
Option C: one active player, current round fully processed, no unresolved review, no pending/eligible-in-window buy-back, then explicit audited confirmation. Automation may follow later once operational confidence exists.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B20 — Prize model

### Current behaviour
Entry/buy-back fee amounts and entry payment status are tracked; there is no pot calculation, buy-back payment ledger, payout, split-winner or disbursement model.

### Why a decision is required
Displaying a “prize” without a reconciled ledger risks financial error and regulatory implications.

### Option A — Participation/payment status only
Lowest scope; calculations remain external.

### Option B — Internal ledger and payout records
Calculates expected/received pot and supports splits without executing payments; requires immutable adjustments and reconciliation.

### Option C — Payment execution
Best UX but materially expands security, compliance and operational scope.

### Recommendation
Option B eventually, explicitly excluding payment execution. Until then label values as fees, not guaranteed prize money.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## Rule: B21 — Rule visibility

### Current behaviour
Core outcomes are encoded in SQL/UI behavior but the full competition contract is not shown or version-accepted.

### Why a decision is required
Material rules affect money, elimination and dispute resolution.

### Option A — Static rules page
Easy, but cannot prove which version a player accepted.

### Option B — Versioned per-pot rules acceptance
Strong consent/audit trail; requires immutable versions and re-acceptance policy.

### Option C — Admin-provided free text
Flexible but inconsistent and hard to validate.

### Recommendation
Option B. Before joining/first pick, show and record acceptance of draw, missed pick, team reuse/reset, deadline, postponement/abandonment/void, buy-back, zero-survivor, corrections, and end-of-season rules. Material changes after first acceptance should create a new competition or require unanimous explicit consent; they must never be silent.

### Product owner decision
`UNDECIDED — PRODUCT OWNER DECISION REQUIRED`

## 9. Suggested global/per-pot rules model

Use a **hybrid** model.

Global integrity rules should be non-configurable: immutable rule versions after activation, permanent deadline closure, authoritative/audited result sources, no silent historical rewrites, role/approval separation, deterministic transition validation, and review blocking.

Per-pot rules should be selected from validated enums before `open`: draw outcome, missed-pick policy, zero-survivor policy, postponed/abandoned/void policies, team-use effect of voids, pool-reset policy, late-join cutoff, deadline source/offset, correction window, buy-back count/window, end-of-season resolution, winner confirmation, and prize-accounting mode. Store a canonical rule-set version plus the resolved values accepted by each entrant; never rely on mutable global defaults for an active pot.

## 10. Phase 2 development decomposition

1. **Phase 2A — Core lifecycle rules:** lifecycle state machine, immutable rule-set version, join/payment/pick gates, missed-pick and no-team policy, round-start cohort.
2. **Phase 2B — Exceptional fixtures:** postponed, abandoned, void, moved-gameweek and participant-change adjudication using Phase 1 snapshots.
3. **Phase 2C — Corrections/replay:** correction window, dependency graph, replay eligibility, manual adjudication/audit, finality boundaries.
4. **Phase 2D — Buy-back and entry lifecycle:** one-time entitlement, payment/approval deadline, resubmission, late join, unpaid withdrawal, account-vs-membership separation.
5. **Phase 2E — Winner/endgame:** zero-survivor recovery, GW38 ties, winner eligibility/confirmation, split winners and optional ledger/payout records.
6. **Phase 2F — Player-visible rules:** rules summary, full contract, version acceptance, change notices and historical display.

Recommended order: 2A → 2F foundation → 2D → 2B → 2C → 2E → finish 2F for every implemented rule. P2C should not be built before exceptional-fixture outcomes and lifecycle snapshots are settled.

## 11. Technical dependencies between rules

- Deadline source controls late join, manual picks, random assignment, buy-back claims, re-picks and correction windows.
- The round-start cohort controls zero-survivor reinstatement, buy-back eligibility and replay.
- Team-use accounting depends on postponed/void/moved/participant-change decisions and pool resets.
- Result correction depends on immutable pick/fixture snapshots, authoritative results, adjudication status and downstream dependency tracking.
- Winner finality depends on correction windows, review state, zero-survivor policy, buy-back closure and GW38 resolution.
- Prize/payout records depend on winner multiplicity and correction finality.
- Versioned player acceptance depends on every configurable rule having a stable canonical representation.

## 12. Highest-risk decisions

1. Downstream corrections/replay: greatest fairness and implementation risk.
2. Zero survivors: can invalidate the basic winner state and interacts with buy-backs.
3. Deadline semantics: affects nearly every eligibility boundary.
4. Postponed/moved fixtures: can block rounds or create cross-round contradictions.
5. Buy-back effective timing: can alter winner and zero-survivor cohorts.
6. Winner/payout finality: mistakes may be financially irreversible.

## 13. Questions requiring product-owner answer

The product owner must explicitly answer B1–B21. The minimum implementation-unblocking set is:

1. Is a draw an elimination?
2. Who returns when a round has zero survivors, and is that round's team use undone?
3. How are multiple GW38 survivors resolved?
4. What are the before/after-deadline outcomes for postponed, abandoned, void, moved and participant-changed fixtures?
5. What happens when no unused team exists?
6. Is a missed pick random or elimination?
7. What exact instant closes joining and excludes unpaid entrants?
8. What are the authoritative pot lifecycle gates?
9. What correction window and downstream remedy apply?
10. What is the deadline source and rescheduling rule?
11. What are the buy-back count, payment, decision and final-round rules?
12. Is winner completion manual or automatic, and when is it final?
13. Is prize accounting in scope, including split winners?
14. Must every entrant accept an immutable rules version?

## 14. Safe work that can continue before those answers

- Review this report and turn decisions into one signed-off canonical rules specification.
- Prepare, but do not execute, staging Phase 1 deployment and verification runbooks.
- Prepare production P1/P2/Phase 1 catch-up preflight, backup and stop/go runbooks.
- Design rule-set JSON/enums and state-transition diagrams without creating schema.
- Design acceptance, adjudication and audit event contracts.
- Add no-behavior-change documentation/test inventories and map each future rule to required tests.

## 15. Work that must remain blocked

- Any production migration or schema-history repair.
- Phase 1 deployment until recovery readiness and the relevant runbook are approved.
- Any Phase 2 application code or migration.
- Historical replay, winner rewrite, payout calculation, exceptional-fixture automation, late-entry handicap or team-pool reset implementation.
- Player-facing promises about rules that remain undecided.

## 16. Final recommendation

Approve staging as the first Phase 1 deployment candidate only after an operator confirms a restorable backup and approves the staging runbook. Keep production blocked while it receives a separate controlled P1 → P2 → Phase 1 catch-up plan; its empty migration history must not be papered over.

In parallel, the product owner should answer the 14 consolidated questions above and explicitly resolve every B1–B21 decision. Convert those answers into one immutable, versioned Last Man Standing rules contract before Phase 2 schema or application development begins.
