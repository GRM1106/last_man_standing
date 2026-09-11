# Phase 2E — Collective Reinstatement

After processing a pre-GW38 round, the engine counts winners against the immutable Phase 2B cohort. If none survived, it appends one round-level reinstatement event, restores exactly that cohort from eliminated to active, and adds them to the existing next-gameweek round with entry reason `collective_reinstatement`.

Failed picks and outcomes remain unchanged, Phase 2C team usage remains consumed, and buy-back state is untouched. The operation executes in the processing transaction and is protected by the existing round lock plus unique source-round event constraint. Missing next gameweek or withdrawn cohort members place the pot into review rather than inventing a rule. GW38 is explicitly excluded.
