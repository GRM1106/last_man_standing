# Phase 2C — Team-Use Cycle Foundation

Every pot membership now owns a stable Cycle 1. Picks reference both their Phase 2B LMS round and the active per-player/per-pot team cycle. Database ownership foreign keys prevent cross-player or cross-pot linkage, and `unique(team_cycle_id, team_id)` permits one team use per cycle while structurally allowing the same team in a later cycle.

The server derives the single open cycle; clients cannot create, close, advance or edit cycles. Existing memberships and picks backfill deterministically into Cycle 1, and migration aborts if existing repeated team use would make that assumption unsafe. Manual selection, team availability and random assignment now scope used-team checks to the active cycle.

Team use is represented by the valid pick itself and is independent of outcome. Processing, corrections and future exceptional results therefore cannot release a team. Supported draft-test reset deletes test picks, so those deleted selections cease consuming teams while the membership's Cycle 1 remains intact.

No collective reinstatement, exceptional-fixture outcome, GW38 handling, buy-back redesign, adjudication or automation is included.

## Cycle rollover (Phase 2K)

Team usage is cycle-scoped, and a cycle closes as soon as its pool is exhausted — when the
player has used every team appearing in a fixture of the pot's season, which is twenty in a
normal Premier League season but is always read from the season rather than assumed. The
next numbered cycle opens at that moment and all teams become eligible again within it.
Prior cycles and the picks attached to them remain immutable, so history still shows which
team was used when.

Cycles are per player and per pot: one player exhausting their pool never resets another's.
`ensure_current_team_cycle` is the only function that closes or opens a cycle. Both pick
paths reach it through the `player_picks` insert triggers, so a manual selection and a
random missed-pick assignment roll over identically. Read paths resolve eligibility through
`active_team_cycle_id`, which reports no active cycle while the open one is exhausted, so
availability can never be computed against a full pool.

Buy-back re-entry still does not create or reset a cycle, and collective reinstatement
leaves cycle history untouched. Clients remain unable to create, close, advance or edit
cycles; every rollover happens inside the server's own domain path.
