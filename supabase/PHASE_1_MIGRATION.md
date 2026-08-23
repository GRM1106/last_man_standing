# LMS Integrity Phase 1 migration

`migrations/20260823000100_lms_integrity_phase_1.sql` is a forward-only migration
whose required baseline is the complete modules 1–22 plus P1 and P2 schema at
repository commit `d09613e`.

Do not apply it to an environment identified only by its URL. First positively
identify the project and compare its function definitions, columns, constraints,
triggers, RLS policies, and ACLs with the repository. Production parity is not
established by this repository.

The migration is intentionally single-application and transactional. It refuses
to run without P2 and refuses to run after its private P2 base functions exist.
It does not modify historical setup modules. Never re-run a superseded module to
repair an existing database; doing so can replace current functions with older
definitions.

Verification is performed by `verification/lms_integrity_phase_1_verification.sql`
in a disposable Supabase-compatible database only. Never run verification seeds
against staging or production.

Run the complete disposable harness with `npm run test:db`. It starts an unlinked
local Supabase stack, installs the historical baseline in the documented order,
adds one synthetic local administrator, applies P1, P2 and Phase 1, executes the
rollback-only verification, and destroys the local stack. Docker must be running;
the Supabase CLI is obtained through `npx`.
