# Last Man Standing — Canonical Rules Specification

Version: `2026-08-23-draft-1`  
Status: review candidate; unresolved clauses are explicitly marked  
Authority: product-owner decisions supplied 23 August 2026

## 1. Purpose and authority

This is the canonical behavioural contract for Last Man Standing (LMS). Database rules MUST be authoritative; UI text MUST reflect them. A pot MUST retain the rules version that governed entry. Core rules are global, not per-pot options. Operational pot fields may include name, starting/included gameweeks, fees and entrants.

## 2. Terminology

- **Pot:** one LMS competition.
- **LMS round:** one decision cycle for a pot. It normally references a Premier League gameweek, but MUST have its own identity so a replay or moved fixture cannot corrupt history.
- **Provider fixture:** the external football fixture identified by the provider.
- **Valid locked pick:** a server-accepted selection made while the player, team and fixture were eligible.
- **Team-use cycle:** the numbered set in which a player may use each of the 20 teams at most once.
- **Eligible player:** a participating player who has not finally been eliminated, or whose buy-back status preserves eligibility under an explicit rule.
- **Round-entry cohort:** the immutable set of eligible players entering an LMS round.
- **Automatic win:** an LMS outcome awarded by an exceptional-fixture rule, not the later sporting result.
- **Review:** a fail-safe state requiring governed admin resolution.
- **Final gameweek:** GW38.

## 3. Pot lifecycle

The persisted lifecycle SHOULD be `setup`, `open`, `in_progress`, `review`, `complete`.

- `setup`: admin configures the pot and adds entrants; selections are unavailable.
- `open`: selections are available; entrants may still be added until the first deadline.
- `in_progress`: derived/transitioned automatically when the first permanent deadline closes; membership is permanently locked.
- `review`: gameplay cannot safely advance. It preserves the underlying lifecycle position and records a reason. Admin resolution MUST be explicit and audited.
- `complete`: winner set and shares are final under the applicable correction-finality rule; gameplay is read-only.

Opening a pot may be an explicit setup action. Starting play MUST NOT require a separate admin “start” action. No entrant may be added at or after the first stored deadline. A closed membership window MUST never reopen after rescheduling.

## 4. Entrant lifecycle

An account may access its dashboard immediately after registration. Assignment to a pot, not account approval, determines whether pot content exists. An unassigned account sees an explanatory empty state.

Entrant gameplay states are participating, eliminated and winner. Buy-back entitlement/claim is orthogonal state. Account access control MUST NOT silently alter tournament membership. The existing `approved` field MAY remain temporarily for admin workflow, but MUST NOT gate dashboard access, selection, membership or football eligibility; deletion requires a separate usage/data migration review.

## 5. Payment lifecycle

Entry and buy-back payment are administrative accounting facts. They MUST NOT gate joining, selection, random assignment, processing, progression or winning. Default entry and buy-back fees are each £10 (1,000 pence), stored as money fields on the pot.

Admin MUST be able to see and update individual payment state. Players MUST NOT see another entrant's payment state. Prize value equals configured entry charges plus approved/charged buy-backs under the accounting policy; payment receipt and charge liability SHOULD be distinct facts.

## 6. Selection rules

A participating entrant MUST have exactly one effective pick per LMS round. A manual pick MUST be rejected unless the round is open, its deadline has not passed, the fixture is eligible/unstarted, the selected team participates, and the team is unused in the player's current cycle. Duplicate round picks and team reuse MUST be rejected transactionally.

A locked pick and its selection-time fixture snapshot MUST remain auditable. Provider fixture identity and LMS round identity MUST be separable.

## 7. Deadline rules

The deadline is the kickoff of the first provider fixture belonging to that gameweek. It MUST be stored. Once reached, the round and (for the first round) membership permanently close. Later provider rescheduling MUST NOT reopen either. Manual picks are rejected at `now >= deadline`.

## 8. Team-use cycles

A selected team becomes used when a valid pick locks, regardless of win, draw, loss, postponement, abandonment or void. History MUST NOT be deleted to restore availability.

When continuation requires a reset because the 20-team pool/season structure is exhausted, every surviving player starts the next numbered team-use cycle with all 20 teams available. Prior cycles remain immutable. The reset MUST occur at a round boundary and be recorded. It MUST NOT make a team available within a partially completed round.

## 9. Missed-pick rules

At/after deadline, an idempotent automated action MUST assign a random pick to each participating player without one. Candidates are unused teams in the current cycle whose eligible fixture has not started and whose outcome is not known. Used teams and unavailable/started fixtures MUST be excluded.

At the exact first kickoff, teams in that fixture are ineligible; later unstarted fixtures remain candidates. The committed candidate identity and audit reason MUST be recorded. Duplicate jobs MUST yield one pick.

If no safe candidate exists, the system MUST enter review and MUST NOT invent a pick, win or elimination.

## 10. Fixture exception rules

A fixture already officially postponed, abandoned, void or otherwise reliably unavailable MUST NOT be selectable. Existing provider status is authoritative; no rumours scraper is required. A future trusted admin availability flag MAY supplement provider status and MUST be attributable/timestamped.

Eligibility evidence MUST include pick lock time, provider fixture status observed at selection, observation/sync time, fixture participants/gameweek/kickoff, and any admin availability flag/version.

If a valid pick locked while playable and the fixture subsequently becomes officially postponed, abandoned or void, that pick receives an automatic win in its original LMS round and consumes the team. The decision MUST snapshot the exceptional status/effective time and MUST not depend on the fixture's later identity or result.

If evidence shows the fixture was unavailable before the pick, no automatic win is allowed; the pot enters review because the invalid pick bypassed protection. If temporal ordering cannot be established, enter review.

A postponed fixture later assigned/played in another gameweek is a normal candidate in that later gameweek for otherwise eligible players. It MUST NOT reprocess or replace the original automatic win.

A material participant/gameweek mutation after lock MUST be reviewed. Where it represents official postponement/movement after a valid pick, apply the automatic-win rule; otherwise do not guess.

## 11. Result processing

Normal rule: the selected team MUST win for the player to progress. A draw or loss eliminates, subject to buy-back/endgame rules. Only authoritative final results or explicit exceptional decisions are processable. Processing MUST be idempotent, transactional and based on immutable round-entry/pick/result snapshots.

Provider incompleteness MUST delay or escalate; it MUST NOT eliminate a player. Normal rounds SHOULD process automatically once every cohort member has a final or governed exceptional outcome.

## 12. Elimination and progression

Each round records outcomes without rewriting prior provenance. Winners progress. Drawers/losers are eliminated unless a buy-back or the explicit zero-survivor/GW38 rule applies. Progression creates the next round-entry cohort only after the prior round is resolved.

## 13. Everyone-eliminated replay before GW38

If every member of the round-entry cohort is eliminated in the same pre-GW38 round, all cohort members are reinstated and the competition continues; nobody wins merely because everyone lost.

The failed attempt MUST remain immutable. A new LMS round/attempt identity MUST be created and linked to the failed attempt; it MUST NOT delete picks, outcomes or provenance. Previously eliminated players outside that cohort do not return.

The failed attempt's teams remain consumed. The reinstated cohort proceeds to the next Premier League gameweek, never other fixtures in the failed gameweek. Collective reinstatement is not a buy-back: unused entitlements remain unused and used entitlements are not restored.

## 14. Buy-back

Each player has at most one buy-back life per pot. After elimination, the player may request it; admin approval is currently required. Approval MUST be separable from the engine so it can later be automated. A second approved/used buy-back MUST be rejected transactionally.

Buy-back payment does not control football eligibility. A request made before the applicable next-round deadline provisionally restores/retains eligibility; later admin approval is not required before that deadline. Admin may subsequently confirm or revoke it for non-payment. State MUST distinguish requested, confirmed, revoked and used/consumed, and delayed review MUST NOT retroactively invalidate a timely request.

An unused buy-back remains relevant in GW38 exactly as §15 specifies.

## 15. GW38/end-of-season rules

GW38 is terminal; there is no GW39 replay. If one or more players win normally, those progressing players are winners, subject to unresolved buy-back eligibility. If all remaining players lose:

- nobody has an unused buy-back: everyone in the cohort wins;
- everybody has one: everyone in the cohort wins without performing identical buy-backs;
- only some have one: only those holders win;
- exactly one has one: that player is sole winner.

This uses buy-back entitlement at the GW38 resolution boundary; it does not mark an unused buy-back as “used” unless accounting explicitly requires it.

## 16. Multiple winners and prize split

The winner set is first-class and may contain one or many players. Multiple winners receive equal shares. The system MUST store winner membership and a deterministic share using integer pence. Any indivisible remainder MUST be allocated by a documented deterministic ordering and recorded; no payout may silently lose or create value.

Players see total current prize value, not individual payment status. Admin sees entry count/value, approved/charged buy-back count/value, total, receipts and exceptions.

## 17. Corrections and admin authority

P2 append-only overrides, audit attribution, timestamps and review flags MUST be preserved. Admin may correct authoritative fixture facts and resolve exceptional review, but MUST provide a reason; actions are reviewable.

A correction before downstream state exists MAY use safe deterministic append-only recalculation. Once later picks/progression exist, the pot/round MUST enter review: no automatic rewind, all history is preserved, and admin adjudication requires an attributable timestamped reason. A completed pot MUST NOT reopen automatically; it is flagged for the same governed review and any explicit reopen/correction preserves original completion history.

## 18. Automation expectations

Automation SHOULD synchronize fixtures approximately every two hours as a baseline, with more frequent scheduled checks near deadlines/live matches only if provider limits permit. Provider constraints have not yet been evidenced; final cadence is an operational decision, not a gameplay rule.

Automation MUST cover closure, missed picks, synchronization, result readiness, processing, progression, deterministic completion and review escalation. Every job MUST be idempotent, retryable and safe under duplication/races. Admin primarily handles corrections, payments, buy-back approval and genuine exceptions.

## 19. Rules versioning and acknowledgement

Every pot MUST reference an immutable rules version. Every entrant record MUST establish that applicable version even when admin-added. Player acknowledgement SHOULD be captured before the first manual pick (or first authenticated pot interaction) with timestamp, user and version. Admin assignment establishes applicability, not fake consent; UI must distinguish “rules applied” from “player acknowledged.” Unacknowledged status MUST be visible and handled before play according to a future UX policy, but MUST NOT be misrepresented as legal consent.

## 20. Explicit invariants

1. Draw and loss eliminate unless an explicit rule overrides.
2. Payment never controls gameplay.
3. Membership locks permanently at the first deadline.
4. A closed deadline never reopens.
5. Used-team history is append-only and cycle-scoped.
6. One effective pick per player/round; one team use per player/cycle.
7. A valid pre-exception pick gets one automatic win and never replays later.
8. An already unavailable fixture cannot be selected.
9. Uncertain temporal eligibility enters review.
10. Provider and LMS round identities are separate.
11. Historical provenance is never silently rewritten.
12. Multiple winners are first-class and split equally.
13. One buy-back maximum per player/pot.
14. Automation is idempotent and fails safe.
15. Core rules are global.

## 21. Remaining product decisions

No unresolved product decision blocks Phase 2A. Later adjudication UI details and the precise deterministic penny ordering are engineering/product-detail decisions for their scheduled subphases; the governing behaviour above is settled.

## 22. Worked examples

- **A — Normal:** Arsenal is validly selected, wins, and becomes used. The player progresses.
- **B — Draw:** Arsenal draws and becomes used. The player is eliminated unless a buy-back later restores eligibility.
- **C — Postponement:** Arsenal is validly locked in GW4, then postponed. The player receives an immutable GW4 automatic win and Arsenal is used. The later GW10 fixture is independent; others may select it, but the original player cannot reuse Arsenal in that cycle and the GW4 decision is never reprocessed.
- **D — Missed deadline:** Arsenal and Liverpool are used. At closure, the job randomly selects only among the other 18 teams with unstarted eligible fixtures. It cannot select Arsenal or Liverpool.
- **E — Everyone loses:** Four players enter GW10 and all lose. GW10 and its picks remain recorded, every selected team remains used, and all four proceed to GW11. Unused buy-backs remain unused; used buy-backs are not restored. Players eliminated before the GW10 cohort do not return.
- **F — GW38 mixed:** Grant/Jade have unused buy-backs; Mark/Amy do not; all lose. Grant and Jade are winners and split equally.
- **G — GW38 none:** All lose and nobody has a buy-back. All cohort members win and split equally.
- **H — GW38 all:** All lose and all have unused buy-backs. All cohort members win and split equally without redundant buy-back actions.
