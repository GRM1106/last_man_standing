# Phase 2H — Governed Review

Review entry points audited: processed/completed fixture overrides, participant or gameweek mutation, provider reversal after an exceptional auto-win, late downstream buy-back revocation, collective-reinstatement progression failure, and any unresolved Phase 2G completion block. Existing correction, exceptional-resolution, buy-back and completion ledgers remain authoritative evidence.

`lms_review_cases` stores the structured issue, evidence, downstream-impact snapshot, source references and minimal `open/resolved/dismissed` lifecycle. `lms_review_resolution_events` is append-only and records actor, mandatory reason, action, and complete before/after snapshots. Preview tokens bind the case version, open-case count and completion state; stale confirmation fails and requires another preview.

Unsafe history is never rewound. Constrained actions can uphold state or set a prospective player status. Completed-pot winner changes are represented separately by immutable `pot_completion_adjudications` and penny-conserving `pot_adjudicated_winners`; original Phase 2G completions and winners remain untouched. A pot leaves review only after its final blocking case closes.

## Resolution preview (Phase 2K)

`preview_lms_review_resolution` is a read-only projection. It writes nothing — no status
change, no adjudication, no case or override mutation — and is safe to call repeatedly.

For `revise_winners` it uses the **same winner derivation as apply**:
`lms_revised_winner_projection` computes the revised winner set and its penny-conserving
split, preview serialises that projection, and `resolve_lms_review_case` persists exactly
it. There is one winner calculation, not two, so what an administrator approves is what
gets recorded. The preview returns the proposed winner ids, each share in pence and the
prize total, alongside `proposed_valid`/`proposed_problem` when a nomination cannot be
applied — an empty nomination, a repeated nominee, or a player who is not in the pot are
all refused identically by preview and by apply. Actions that do not revise winners
project the winners that remain.

Stale preview tokens remain invalid. The token still binds the case version, the pot's
open-case count and the completion state, so a resolution prepared against older state is
refused and must be previewed again.
