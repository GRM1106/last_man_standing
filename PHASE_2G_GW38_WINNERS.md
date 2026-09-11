# Phase 2G — GW38 Winner Sets

GW38 is terminal. Its finalized round cohort and immutable pick outcomes determine winners. If any normal survivor exists, only normal survivors win. If none survives, the entire cohort wins when zero or all entrants retain an available buy-back; otherwise only entrants with an available entitlement win. This decision never consumes an entitlement and never creates GW39 or a collective reinstatement.

`pot_completions` snapshots the terminal round, resolution rule, paid entry contributions, received buy-back contributions, integer-pence total, winner count, actor and time. `pot_winners` stores each first-class winner, reason, stable share order and exact share. Winners are ordered by pot join time then UUID; base division is followed by one extra penny for the first remainder winners, conserving the snapshot exactly.

Unresolved review blocks finalization. Duplicate processing returns the existing snapshot. Winner data is client read-only and immutable outside supported draft test reset. The legacy manual crown RPC is constrained so it cannot bypass deterministic GW38 completion.
