# Phase 2C — Team-Use Cycle Foundation

Every pot membership now owns a stable Cycle 1. Picks reference both their Phase 2B LMS round and the active per-player/per-pot team cycle. Database ownership foreign keys prevent cross-player or cross-pot linkage, and `unique(team_cycle_id, team_id)` permits one team use per cycle while structurally allowing the same team in a later cycle.

The server derives the single open cycle; clients cannot create, close, advance or edit cycles. Existing memberships and picks backfill deterministically into Cycle 1, and migration aborts if existing repeated team use would make that assumption unsafe. Manual selection, team availability and random assignment now scope used-team checks to the active cycle.

Team use is represented by the valid pick itself and is independent of outcome. Processing, corrections and future exceptional results therefore cannot release a team. Supported draft-test reset deletes test picks, so those deleted selections cease consuming teams while the membership's Cycle 1 remains intact.

No automatic Cycle 2 transition, exhaustion detection, collective reinstatement, exceptional-fixture outcome, GW38 handling, buy-back redesign, adjudication or automation is included.
