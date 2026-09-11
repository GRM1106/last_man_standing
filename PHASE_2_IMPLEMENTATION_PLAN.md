# Last Man Standing — Phase 2 Implementation Plan

Date: 2026-08-23  
Baseline: `feature/lms-integrity-phase-1` at `ef226e66e96449b84539c41f8acb7062e899b76d`  
Authority: [LMS_RULES_SPECIFICATION.md](LMS_RULES_SPECIFICATION.md)

## 1. Executive summary

Current code supports basic win/draw/loss, one-use teams, manual random picks, fee fields, one buy-back and P1/P2 integrity foundations, but conflicts with the canonical rules on payment gating, approval gating, automation, multiple winners and fixture exceptions. The safest first implementation remains lifecycle/membership/payment/approval decoupling. Final decisions now settle replay, buy-back timing, correction review and prize remainders without expanding Phase 2A.

## 2. Product decisions captured and remaining ambiguities

All supplied rules and the six final decisions are incorporated. No product ambiguity blocks Phase 2A.

## 3. Current implementation gap matrix

| Canonical area | Classification | Current → required | Principal impact | Risk |
|---|---|---|---|---|
| Win/draw/loss | SUPPORTED | Draw/loss eliminate; retain | processing/tests/rules UI | Low |
| Independent LMS round identity | NOT SUPPORTED | gameweek is identity → round/attempt entity | schema, all round RPCs/UI | High |
| Zero-survivor reinstatement | NOT SUPPORTED | zero active dead-end → append-only linked replay | processing/progression | Critical; decision-blocked |
| Multiple winners/equal shares | CONFLICTS WITH RULE | exactly-one crown → winner set/shares | `complete_pot_with_winner`, standings | High |
| Team-use cycles | NOT SUPPORTED | lifetime per-pot uniqueness → cycle-scoped use | picks/availability | High |
| Postponed/abandoned/void | CONFLICTS WITH RULE | block processing → valid pre-change auto-win | sync/P2/processing | High |
| Pre-selection unavailable block | PARTIALLY SUPPORTED | Phase 1 excludes unstarted candidates; manual status evidence incomplete → temporal eligibility snapshot | pick RPCs/sync | High |
| Permanent first-kickoff deadline | SUPPORTED | Phase 1 stores/fixes closure | preserve across new round model | High invariant |
| Automatic missed pick | PARTIALLY SUPPORTED | admin-triggered RPC → idempotent job | scheduler/RPC/audit/UI | Medium |
| Safe random candidates | SUPPORTED | Phase 1 unused + unstarted → retain cycle scope | `assign_random_missing_picks` | Medium |
| Membership lock | NOT SUPPORTED | add in draft/open → reject at first stored deadline | membership/lifecycle/admin | High |
| Payment decoupling | CONFLICTS WITH RULE | paid gates pick/random/process → accounting only | three RPCs/dashboard/admin | High |
| Dashboard without approval | CONFLICTS WITH RULE | approval gates dashboard/pick/add → open dashboard/empty state | dashboard RPC/UI/RLS review | High |
| Simplified lifecycle | CONFLICTS WITH RULE | manual draft/open/active → setup/open/in_progress/review/complete | pots/RPC/admin UI | High |
| One buy-back | PARTIALLY SUPPORTED | one-use exists; timing/accounting/endgame incomplete | buy-back RPCs/endgame | High |
| GW38 buy-back resolution | NOT SUPPORTED | exactly-one manual crown → four canonical cases | processing/winners | High |
| Automated sync/process | NOT SUPPORTED | admin/manual → idempotent orchestration | jobs/RPC/admin status | High |
| P2 corrections | PARTIALLY SUPPORTED | append-only override/review exists; replay absent | preserve/extend | Critical; decision-blocked |
| Admin review authority | PARTIALLY SUPPORTED | P2/Phase 1 flags → governed resolution records | schema/RPC/admin UI | High |
| Prize counter/ledger | NOT SUPPORTED | fee fields only → charge ledger/aggregate/private receipt | schema/dashboard/admin | Medium |
| Rules version/ack | NOT SUPPORTED | none → immutable version/applicability/ack | schema/UI/RPC | Medium |

Functions needing focused replacement/extension: `confirm_team_pick`, `get_pot_selection`, `assign_random_missing_picks`, `process_pot_gameweek`, `complete_pot_with_winner`, `set_pot_status`, `set_pot_test_mode`, `reset_test_gameweek`, `claim_buy_back`, `set_buy_back_decision`, `sync_fpl_data`, P2 correction functions, dashboard/admin/payment RPCs.

### Rule-by-rule classification

| Rule | Status | Required delta / tests / migration impact |
|---:|---|---|
| 1 Winning | SUPPORTED | Preserve draw/loss elimination; regression win/loss/draw; no schema delta alone. |
| 2 Everyone eliminated | NOT SUPPORTED | New round/cohort/replay records; next gameweek, teams remain used, buy-backs unchanged. Critical, later phase. |
| 3 Multiple winners | CONFLICTS WITH RULE | Winner-set/share schema, completion/standings/UI; multi-winner tests. High. |
| 4 Team reset | NOT SUPPORTED | Cycle-scoped use and availability UI; reset/history/concurrency tests. High. |
| 5 Postponed | CONFLICTS WITH RULE | Temporal snapshot plus exceptional decision; pick/process/history UI; before/after/later-play tests. High. |
| 6 Abandoned | CONFLICTS WITH RULE | Same exception engine; abandoned temporal tests. High. |
| 7 Void | CONFLICTS WITH RULE | Same exception engine; void temporal tests. High. |
| 8 At-risk fixture | PARTIALLY SUPPORTED | Harden manual and random eligibility; status observations/admin flag/review; bypass/uncertainty tests. High. |
| 9 Deadline | SUPPORTED | Preserve Phase 1 stored permanent closure through round migration; boundary/reschedule tests. High invariant. |
| 10 Missed assignment | PARTIALLY SUPPORTED | Remove paid filter, cycle-scope unused teams, automate call; distribution membership tests. Medium. |
| 11 Assignment timing | PARTIALLY SUPPORTED | Idempotent closure orchestration and explicit no-candidate review; exact-kickoff/started tests. High. |
| 12 Joining | NOT SUPPORTED | Immutable pot first-deadline membership lock in add/create RPC/admin UI; before/after tests. High. |
| 13 Payment | CONFLICTS WITH RULE | Remove payment predicates from pick/random/process; private accounting UI/RLS; unpaid-play tests. High. |
| 14 Approval | CONFLICTS WITH RULE | Remove approval gates from dashboard/pick/add; empty-state UI; unapproved access/RLS tests. High. |
| 15 Lifecycle | CONFLICTS WITH RULE | Forward status mapping/new review semantics; status RPC/admin/player UI; transition tests. High. |
| 16 Pot start | NOT SUPPORTED | Automatic first-deadline transition; duplicate job/race tests. Medium. |
| 17 One buy-back | PARTIALLY SUPPORTED | Existing state mostly enforces; add entitlement invariant/concurrency test. Medium. |
| 18 Buy-back approval | SUPPORTED | Preserve admin approval but isolate transition for future automation; auth tests. Low/medium. |
| 19 Final eligibility | NOT SUPPORTED | Endgame reads unused entitlement; GW38 tests. High. |
| 20 GW38 all-lost | NOT SUPPORTED | Endgame winner-set logic; four cases and exact cohort tests. High. |
| 21 Synchronization | PARTIALLY SUPPORTED | Sync RPC exists; add scheduler/run ledger/observations/health UI; retry/outage tests. High. |
| 22 Correction authority | PARTIALLY SUPPORTED | Preserve P2, connect facts to adjudication without rewrite; correction race tests. Critical. |
| 23 Admin control | PARTIALLY SUPPORTED | Add governed review resolution and evidence UI; ACL/audit tests. High. |
| 24 Automation | NOT SUPPORTED | Orchestration pipeline/run ledger; duplicate/retry/race tests. High. |
| 25 Fee values | SUPPORTED | Existing pence fields/defaults; avoid hardcoded UI; validation tests. Low. |
| 26 Prize counter | NOT SUPPORTED | Charge ledger/aggregate RPC, public total/private detail; arithmetic/RLS tests. Medium. |
| 27 Rule visibility | NOT SUPPORTED | Summary/full rules UI linked to version; rendering tests. Medium. |
| 28 Acknowledgement | NOT SUPPORTED | Applicability and acknowledgement records/RPC/UI; immutable/version tests. Medium. |
| 29 Global rules | PARTIALLY SUPPORTED | Encode global rules/version, restrict per-pot operational fields; invariant tests. Medium. |

## 4. Recommended state model

- Persist pot lifecycle: `setup|open|in_progress|review|complete`, plus review reason/time and prior lifecycle context. Derive membership lock from stored first deadline, but persist `membership_locked_at` as immutable evidence.
- Persist LMS rounds/attempts: pot, ordinal, provider gameweek, attempt number, predecessor/replay link, deadline, state (`selection_open|closed|awaiting_results|review|complete|superseded_by_replay`) and cohort snapshot. `upcoming` and `processing` can normally be derived/transaction-local.
- Persist entrant state: `participating|eliminated|winner`; keep buy-back entitlement/claim separate. Do not encode every conceptual combination in one enum.
- Persist team cycle and append-only team use. Picks reference round and cycle.
- Persist winner rows and shares; do not overload one `player_status` as the winner model.

## 5. Database/data model changes

Forward migrations will likely add `rules_versions`, pot rules reference, entrant applicability/acknowledgement, `pot_rounds`, `pot_round_players`, `team_use_cycles`/cycle on picks, exceptional LMS decisions, governed reviews/resolutions, winner rows, charge/ledger records, automation runs and immutable membership lock. Existing provenance remains immutable; legacy rows receive explicit backfill source/version. Constraints enforce one pick per entrant/round, one team use per cycle, one buy-back, immutable deadlines and non-overlapping terminal state.

Avoid deleting `approved` initially. Stop using it as a gameplay gate, inventory external uses, then decide later whether removal is safe.

## 6. RPC/backend and frontend/admin changes

Backend MUST centralize eligibility and locks. Pick/random/process RPCs take/resolve LMS round identity, ignore payment, snapshot eligibility, and lock in a consistent order. Lifecycle transitions derive from deadlines. Winner resolution accepts a set. Review resolution is a separate audited command.

Player UI gains immediate dashboard/empty state, lifecycle/deadline, rules summary/full view/acknowledgement, prize total, cycle-aware availability, automatic-pick/result/review status and multiple winners. Admin gains membership-lock clarity, payment-only controls, charge breakdown, automation health, buy-back approval, review evidence/resolution and correction impact. Individual payment state remains private.

## 7. Fixture exception and everyone-eliminated design

At selection, store provider status and observed-at/version. Sync appends status observations. An exception resolver compares effective-status time to locked-at; valid-before-change produces a round-local automatic win with consumed team. The later provider fixture never drives that decision. Invalid/uncertain ordering enters review.

For zero survivors, keep the completed failed attempt and append a replay attempt with the same cohort. Never reset old pick outcomes or delete process rows. Execution remains blocked until replay gameweek, team consumption and buy-back timing are answered.

## 8. Buy-back, GW38 and corrections

Model buy-back entitlement, request, approval and use as audited transitions, capped by a unique player/pot entitlement. GW38 processing computes the winner set from normal winners or, only when all lose, the four specified entitlement cases. It does not require redundant claims.

Corrections before downstream locks may append recalculation transitions. Later corrections stay in review until the product owner selects remedies/finality. P2 overrides remain factual inputs; adjudication records LMS consequences separately. Never mutate snapshots/winners through the correction function itself.

## 9. Automation architecture

Use an external scheduler/worker calling narrow service-role orchestration RPCs; exact hosting is a deployment choice. Baseline sync every two hours, with provider-limit validation and targeted checks around deadlines/live fixtures. One idempotency key per job type/pot/round/window; database advisory/row locks provide correctness.

Pipeline: sync → record observations/mutations → close due deadlines → assign missing picks → assess fixture finality/exceptions → process ready rounds → progress/replay/endgame → escalate review. Retries resume safely. Provider outage leaves awaiting-data, never eliminates. Duplicate/concurrent jobs return the existing result. Admin override and sync share P2 lock order. Multi-day fixtures remain awaiting results until every cohort pick is final/exceptionally resolved.

## 10. Executable database test matrix

| Scenario | Required assertion | Phase/blocker |
|---|---|---|
| Win/loss/draw | progress/eliminate/eliminate; immutable snapshot | Core |
| Duplicate pick/concurrent picks | exactly one effective pick | Core |
| Team reuse | rejected within cycle; allowed after reset | Cycles |
| Missed pick | job assigns once at closure | Automation |
| Random exclusions | no used team; no started/unavailable fixture | Core |
| Deadline/reschedule | manual closes at boundary and never reopens | Core |
| Postponed after valid pick | one original-round auto-win; team used | Exceptions |
| Postponed before pick | selection rejected | Exceptions |
| Abandoned/void | same valid-lock temporal rule | Exceptions |
| Fixture moved/later played | historical decision unchanged; later fixture independent | Exceptions |
| Everyone eliminated/replay | cohort reinstated; append-only linked attempt | Blocked by three decisions |
| Buy-back request/approval | audited transition; restores eligibility | Buy-back |
| Second buy-back | rejected under concurrency | Buy-back |
| Unpaid selection | succeeds; processing includes player | Lifecycle |
| Join before/after first deadline | succeeds/rejected permanently | Lifecycle |
| GW38 none/all/mixed/sole entitlement | exact canonical winner set | Endgame |
| Multiple winners/prize split | all winner rows; shares sum exactly | Penny rounding blocks currency allocation only |
| Correction before next lock | factual override + append-only recalculation | Corrections |
| Correction after progression/complete | review; no silent rewrite | Final remedy decision-blocked |
| RLS/grants | public denied; player privacy; admin/service least privilege | Every migration |
| Concurrent processing | one process/outcome set | Core |
| Duplicate automation | same result, no duplicate side effects | Automation |
| Provider outage/incomplete data | awaiting/review, never elimination | Automation |
| Approval absent | dashboard and valid gameplay work | Lifecycle |
| Payment privacy | other players cannot read receipt/status | Accounting |
| Rules versions | immutable applicability; timestamped acknowledgement | Presentation |

Every migration needs success, authorization failure, invariant failure, rollback-on-error, idempotency and concurrency cases in the disposable Supabase harness.

## 11. Safe implementation sequence

### 2A — Rules/lifecycle foundation
Add rule version/applicability, new lifecycle mapping, immutable first membership lock; decouple payment and approval; dashboard empty state. Update membership, pick/random/process gates and admin UI. Stop if legacy-state backfill is ambiguous or any payment/approval gate remains. This phase avoids replay/correction decisions.

### 2B — LMS round identity and cohort snapshots
Add round/attempt identity and cohort; adapt selection, deadlines, test reset and progression without changing exceptional outcomes. Stop on provenance loss or non-idempotent backfill.

### 2C — Team-use cycles
Cycle-scope availability/uniqueness and preserve legacy use. Reset trigger requires only the settled “pool exhausted” boundary; test concurrency.

### 2D — Fixture temporal eligibility/exceptions
Add observations and exceptional decisions; extend sync/P2/Phase 1 mutation review; implement postponed/abandoned/void auto-win and later-fixture independence.

### 2E — Buy-back state engine
Harden one entitlement/request/approval/use and payment separation. Do not finalize next-round cutoff until answered.

### 2F — Endgame/multiple winners
Winner rows, GW38 cases, shares and completion. Currency remainder awaits rounding decision.

### 2G — Zero-survivor replay
Implement only after its three product answers. Append linked attempt/cohort; never rewrite failed history.

### 2H — Correction adjudication
Implement early deterministic recalculation and later governed remedies only after correction-finality answers.

### 2I — Automation readiness
Idempotent orchestration RPCs, run ledger, retry/status surfaces, duplicate/race tests. Scheduler deployment is separate.

### 2J — Prize accounting and rules UX
Charge ledger/aggregates, private receipts, player counter, full rules/version acknowledgement and all worked-example copy.

Each subphase is a small forward-only migration plus backend/frontend/test commit(s). Rollback is transactional failure or reviewed compensating migration/restore; never edit old modules.

## 12. Deployment dependencies and risks

Staging must receive and verify Phase 1 before any Phase 2 migration. Production must complete the separately approved P1 → P2 → Phase 1 catch-up first. Both require operator-confirmed restorable backups/runbooks; PITR is disabled and backup readiness is unverified. No Phase 2 branch may imply remote readiness.

Highest risks: replay fairness, downstream correction finality, temporal fixture evidence, lifecycle backfill, concurrent automation, multiple-winner accounting and accidental weakening of P1 immutability/RLS.

## 13. Files/functions likely to change

Future work will add forward migrations and tests, and likely update `admin.js`, `dashboard.js`, `gameweek-processing.js`, `deadline-ui.js`, relevant HTML/CSS, README/domain docs, and the named RPCs in the gap matrix. Existing P1/P2/module SQL files MUST remain unchanged.

## 14. Recommended next Codex prompt

> Implement Last Man Standing Phase 2A only on a new branch from `feature/lms-integrity-phase-1` at `ef226e66e96449b84539c41f8acb7062e899b76d`. Treat `LMS_RULES_SPECIFICATION.md` and `PHASE_2_IMPLEMENTATION_PLAN.md` as authoritative. Create a forward-only migration and application/test changes for: immutable rules-version applicability; the `setup/open/in_progress/review/complete` lifecycle foundation; permanent first-deadline membership lock; removal of payment and account-approval from football eligibility; immediate dashboard access with an unassigned-player empty state; and private admin-only payment status. Do not implement LMS round replay, team-use cycles, exceptional-fixture automatic wins, correction replay, multiple winners, GW38 endgame, scheduler deployment, or prize allocation. Preserve P1/P2 provenance, RLS and ACL hardening. Use the unlinked disposable Supabase harness with synthetic data; add boundary, authorization, rollback, idempotency and concurrency tests. Do not access or change staging/production, push, merge, or rewrite history. Stop and report if legacy lifecycle backfill cannot be deterministic. Return commits, migration order, tests and remaining blockers.

## 15. Completion status

`PHASE 2 SPECIFICATION COMPLETE — IMPLEMENTATION NOT STARTED`

“Complete” means precise except for the six explicitly decision-blocked mechanics; those subfeatures must not be implemented until answered.

## 16. Required final-report cross-reference

1. Executive Summary — §1.
2. Rules Specification Produced — `LMS_RULES_SPECIFICATION.md`.
3. Product Decisions Captured — specification §§3–20 and plan §2.
4. Remaining Ambiguities — specification §21.
5. Current Implementation Gap Matrix — §3, including Rules 1–29.
6. Recommended State Model — §4.
7. Database/Data Model Changes — §5.
8. RPC/Backend Changes — §6.
9. Frontend/Admin Changes — §6.
10. Fixture Exception Design — §7.
11. Everyone-Eliminated Replay Design — §7.
12. Buy-Back and GW38 Design — §8.
13. Correction/Replay Design — §8.
14. Automation Architecture — §9.
15. Executable Test Matrix — §10.
16. Phase 2A–2J Implementation Sequence — §11.
17. Deployment Dependencies — §12.
18. Risks — §12.
19. Files/Functions Likely to Change — §13.
20. Questions for Product Owner — specification §21.
21. Recommended Next Codex Prompt — §14.
