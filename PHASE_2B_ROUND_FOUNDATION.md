# Phase 2B — LMS Round and Cohort Foundation

Phase 2B introduces `pot_rounds` as the stable LMS identity distinct from a Premier League gameweek, and `pot_round_players` as the historical entry cohort. Normal schedules create one sequence-numbered round per included gameweek. Picks and process records now reference that round while retaining their existing pot/gameweek fields and provenance.

Cohort rows are created when a legitimate pick locks. Processing finalizes the cohort; finalized membership cannot be updated or deleted by ordinary flows. First-round entrants may still join until the Phase 2A permanent deadline lock, and every entrant who obtains a pick becomes part of the cohort. Later payment, approval and player-status changes cannot rewrite it.

Backfill creates rounds deterministically in gameweek order, maps historical picks and processes by the existing `(pot_id, gameweek_number)` identity, and aborts if either refers outside the pot schedule. Existing uniqueness and team-reuse constraints remain in force. New composite foreign keys prevent cross-pot or non-cohort pick links.

This phase does not implement collective reinstatement, buy-back entry, team-use cycles, exceptional fixtures, GW38, multiple winners, correction adjudication or automation. The `entry_reason` vocabulary is deliberately limited to `normal` and `legacy_pick`; later phases must extend it through a forward migration when behaviour is defined.
