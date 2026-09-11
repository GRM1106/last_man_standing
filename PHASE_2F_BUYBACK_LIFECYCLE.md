# Phase 2F — Buy-Back Lifecycle

## Legacy audit

The previous summary state was `available → claimed → used`; rejecting a claim returned it to `available`. `claim_buy_back` stored the claim time but did not reactivate the entrant. `set_buy_back_decision` made admin approval both the payment decision and the football eligibility gate. `expired` was produced by the dashboard query and had no persisted transition. The dashboard told a claimant to wait for reactivation, admin exposed confirm/reject only for `claimed`, and the standings projected the same overloaded flag.

## Canonical model

`pot_players` remains the current summary while `pot_player_buyback_events` is the append-only explanation. The entitlement summary is `available`, `requested`, `confirmed`, or `revoked`; payment is separately `not_due`, `pending`, `received`, or `revoked`. A unique partial index permits one consumption event per player/pot.

A timely server-validated request consumes the entitlement, records its permanent deadline and source/destination rounds, restores `active`, and immediately inserts the next-round cohort entry with `entry_reason='buy_back'`. Confirmation records manual payment only and is idempotent. It is not an eligibility gate.

Revocation requires an administrator, a reason and an audit event. Before participation it removes provisional entry and eliminates the entrant. After a pick or finalized cohort it preserves downstream history and moves the pot to governed review.

Legacy `claimed` rows become `requested`; `used` becomes `confirmed`; display-only `expired` becomes `available`. Existing timestamps are retained where present. When old data has no lifecycle timestamp, the event explicitly records the fallback provenance rather than presenting it as known history.

Collective reinstatement never writes buy-back events or changes entitlement. Buy-back re-entry does not create a team-use cycle, so used teams remain unavailable. With no next playable round, no GW39 is invented and the unused entitlement remains queryable for Phase 2G.
