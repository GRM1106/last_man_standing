# Phase 2H — Governed Review

Review entry points audited: processed/completed fixture overrides, participant or gameweek mutation, provider reversal after an exceptional auto-win, late downstream buy-back revocation, collective-reinstatement progression failure, and any unresolved Phase 2G completion block. Existing correction, exceptional-resolution, buy-back and completion ledgers remain authoritative evidence.

`lms_review_cases` stores the structured issue, evidence, downstream-impact snapshot, source references and minimal `open/resolved/dismissed` lifecycle. `lms_review_resolution_events` is append-only and records actor, mandatory reason, action, and complete before/after snapshots. Preview tokens bind the case version, open-case count and completion state; stale confirmation fails and requires another preview.

Unsafe history is never rewound. Constrained actions can uphold state or set a prospective player status. Completed-pot winner changes are represented separately by immutable `pot_completion_adjudications` and penny-conserving `pot_adjudicated_winners`; original Phase 2G completions and winners remain untouched. A pot leaves review only after its final blocking case closes.
