# Last Man Standing

A registration page for a private Last Man Standing football tournament.

## Local development

Requires Node.js 22 or newer and Docker. The pinned Supabase CLI is installed with the project.

```sh
npm install
npm run local:start       # separate local project; applies repository migrations
npm run local:setup       # writes ignored local public/function configuration
npm run local:functions   # keep running in a separate terminal
npm run dev               # http://127.0.0.1:5173
```

Ordinary development is local-only and fails clearly if configuration is missing. It never
falls back to a hosted project. Local Supabase uses `http://127.0.0.1:55321`, Studio uses
`http://127.0.0.1:55323`, and test email uses `http://127.0.0.1:55324`. The separate project
`last_man_standing_local` does not reuse the older `last_man_standing` containers/volumes.
No production data is copied or seeded. Existing automation switches remain disabled.

`local:setup` obtains keys from CLI status, validates local URL/key claims and writes only the
anonymous key to `.env.development.local`. Privileged keys stay in the local Supabase runtime.
It does not overwrite hand-written private configuration. Do not put secrets in `VITE_*`
variables; Vite automatic environment exposure is disabled. The local browser connection policy
permits only this app and local Supabase. Remote team badge images are intentionally blocked locally.
Email/password registration is available locally; Google OAuth needs separate local provider setup
and is not required for startup. Use the local email UI for mail checks.

```sh
npm run local:migrate     # pending migrations, explicitly --local; never resets data
npm test
npm run test:db           # separate disposable database; leaves the running stack alone
npm run test:build-targets
npm run build:local
npm run preview           # local bundle only, http://127.0.0.1:4173
```

A compatibility `/api/fpl` handler is available through Vite. It reads the public official FPL
feed, not production LMS infrastructure. Admin scheduler requests go to local Edge Functions.
The local scheduler rejects hosted database URLs/keys before any authentication or RPC request;
no polling schedule starts automatically. A deployed Edge Function retains platform-injected
configuration. `local:functions` strips ambient hosted credentials and uses its generated local
environment file. Normal local commands never invoke remote deployment commands.

Production and genuine staging remain explicit hosted paths:

```sh
npm run build             # explicit production bundle, existing Vercel identity guard
cp .env.staging.example .env.staging.local
# Set the staging PUBLIC publishable key in that ignored file.
npm run build:staging
npm run dev:staging       # explicitly opts into hosted staging
npm run preview:production  # only a production-labelled bundle
npm run preview:staging     # only a staging-labelled bundle
```

`vercel.json` and `vercel.staging.json` keep their separate deployment policies. The existing
`deploy:production` and `deploy:staging` commands still prove the linked project's identity.
Creating a build does not deploy it. See [DEPLOY_TARGET_GUARD.md](DEPLOY_TARGET_GUARD.md) and
[SUPABASE_TARGET_GUARD.md](SUPABASE_TARGET_GUARD.md) for hosted operation protections. Do not
use a hosted deployment or database-reset command as a local startup step.

## Registration

Registration is open. Email/password signup and restored sessions go straight to the
player dashboard after any email verification required by Supabase Auth. An account
without a pot gets an explanatory empty dashboard; organisers still control pot membership.
The old `waiting.html` URL redirects to the dashboard or sign-in page.

Apply the complete ordered `supabase/migrations/` chain, including
`20260926000200_open_registration.sql` (`npm run local:migrate` locally). That migration
retires the account-approval RPC and defaults/backfills the deprecated `profiles.approved`
compatibility field to true. This field no longer grants or restricts access. Authentication,
profile RLS, administrator roles, deadlines, payments and buy-back decisions are unchanged.

## RPC authorisation

Registration is public through Supabase Auth; application RPCs require authentication.
`20260926000300_rpc_authorisation_boundary.sql` removes inherited anonymous execution
from the remaining legacy functions, makes correction helpers private to their checked
entry points, and authorises the retired manual-winner RPC before inspecting pot state.
Player membership checks and administrator attribution remain in the database.
`20260926000400_member_name_privacy.sql` prevents contact emails from being used as
member-facing fallback names in standings and original/adjudicated winners. Real
names and nicknames are retained; missing names display as “Player”.

Supabase grants `anon` and `authenticated` function execution by default. New migrations
must explicitly revoke `PUBLIC`, `anon` and, for internal helpers, `authenticated`;
revoking `PUBLIC` alone is insufficient. The disposable bootstrap reproduces these
platform defaults. `npm run test:db` verifies the complete anonymous RPC surface,
reviewed authenticated entry points, registration and cross-user/cross-pot boundaries.
Platform-wide defaults are deliberately unchanged; new RPCs need an explicit grant review.

## Supabase setup

> **Phase P1 synchronization safety:** Do not run a second-season, new-season, or
> historical FPL synchronization before `result_provenance_foundation.sql` has
> completed. Before P1, provider IDs are globally unique and a historical sync can
> overwrite a prior season's stored team or fixture. Existing deployments must
> apply P1 only as the final forward migration. Clean installations must apply all
> modules below, including P1, before their first FPL sync. Never synchronize after
> the historical FPL setup module (`fpl_fixture_setup.sql`, step 8 below) but
> before the final P1 module.

Apply the SQL modules in this exact order:

1. `supabase/setup.sql`
2. `supabase/fix_google_names.sql`
3. `supabase/admin_setup.sql`
4. `supabase/pot_setup.sql`
5. `supabase/player_dashboard_setup.sql`
6. `supabase/pot_gameweek_schedule.sql`
7. `supabase/fix_multiple_player_pots.sql`
8. `supabase/fpl_fixture_setup.sql`
9. `supabase/player_pick_setup.sql`
10. `supabase/admin_pick_overview.sql`
11. `supabase/test_result_setup.sql`
12. `supabase/gameweek_processing.sql`
13. `supabase/buy_back_setup.sql`
14. `supabase/pot_management.sql`
15. `supabase/random_pick_setup.sql`
16. `supabase/round_progression.sql`
17. `supabase/tournament_operations.sql`
18. `supabase/pot_standings.sql`
19. `supabase/pick_deadlines.sql`
20. `supabase/player_standings.sql`
21. `supabase/standings_window.sql`
22. `supabase/player_team_availability.sql`
23. `supabase/result_provenance_foundation.sql`
24. `supabase/result_corrections.sql`
25. `supabase/migrations/20260823000100_lms_integrity_phase_1.sql`

Module 23 is the forward-only Phase P1 foundation. Module 24 is the forward-only
Phase P2 controlled-correction layer. Read [`DOMAIN_PHASE_P1.md`](DOMAIN_PHASE_P1.md)
and [`DOMAIN_PHASE_P2.md`](DOMAIN_PHASE_P2.md) before using them. P2 is merged into
`main` through commit `d09613e` and was deployed and schema/security verified on
isolated staging. Production deployment remains unverified and was not approved
by the recorded P2 work. Its
`supabase/result_corrections_verification.sql` companion is rollback-only and is
intended only for a disposable/local Supabase database.

The staging deployment used project `last-man-standing-staging`
(`evhiixndiuwwodsouyhf`, `eu-west-1`), migration
`20260822002400_result_corrections.sql`, source commit
`24b183091ec27d9f426c58ab2f1eab787ae7dbe2`, and SHA-256
`7b4af55bf5f3e585fdd2f681cc645339694a7a82cef1e6da2d68d2596a38eccf`.
Staging contains exactly 24 migrations, no application rows were introduced,
and schema/security verification passed. The `pg_dump` self-referencing
override-chain foreign-key warning was expected. The administrator UI was not
live-tested against staging.

Staging proves deployment, migration history, schema shape and security
configuration. Disposable local testing proves functional behavior, finality,
authorization, rollback, idempotency and all three concurrency races. Production
evidence does not establish production deployment or approval.

Module 25 is the forward-only LMS Integrity Phase 1 migration. It requires the
effective P1 and P2 schema and deliberately refuses a second application. Verify
the target catalog before applying it. Never re-run an older setup module to
install a fix: historical modules contain function definitions superseded by
later modules and can silently restore obsolete game or security behaviour.

P1 database testing requires a real disposable Supabase-compatible PostgreSQL
instance with the Supabase Auth schema, `auth.uid()`, the `anon`, `authenticated`,
and `service_role` roles, an administrator profile, and modules 1–22 already
installed. Vanilla PostgreSQL is not sufficient. The reproducible sequence is:

1. Apply modules 1–22 to an empty disposable Supabase project.
2. Apply `supabase/result_provenance_pre_migration_seed.sql`; it intentionally commits its legacy fixture.
3. Optionally run the read-only `supabase/result_provenance_preflight.sql` and retain its sanitized counts.
4. Apply `supabase/result_provenance_foundation.sql`; this forward migration commits normally.
5. Run `supabase/result_provenance_foundation_verification.sql`; its assertions execute in a transaction that always rolls back.

For the intentional ambiguity test, start from a separate freshly reset disposable
database, apply modules 1–22, apply
`supabase/result_provenance_failure_seed.sql`, attempt P1 (which must fail), then
run `supabase/result_provenance_failure_verification.sql`. Never run any seed or
verification script against production.

P2 disposable verification starts only after the complete P1 disposable path:
apply `supabase/result_corrections.sql`, then run
`supabase/result_corrections_verification.sql`. The latter rolls back every
synthetic row and verifies cleanup. Do not use either P1 seed to manufacture
legacy state after P1 has already been applied.

P2 concurrency verification additionally uses the eight
`supabase/result_corrections_concurrency_*.sql` assets in two independent local
database sessions, exactly as documented in [`DOMAIN_PHASE_P2.md`](DOMAIN_PHASE_P2.md).
They are disposable-only, commit synthetic rows, and require destruction of the
entire local stack afterward. They are not migrations and must never be applied
to staging or production.

No disposable seed, rollback-verification, concurrency, preflight or
failure-test script may run against staging or production.

### FPL synchronization

FPL synchronization is safe for new or historical seasons only after the final
P1 migration is installed. On an existing deployment, apply only reviewed forward
migrations from its verified schema state. On a clean test install, finish all 25
modules before the first sync. Do not use the administrator sync control while
the database is between `fpl_fixture_setup.sql` and
`result_provenance_foundation.sql`; the legacy global provider IDs can overwrite
an earlier season.

After applying the SQL modules:

1. Enable Google under **Authentication → Sign In / Providers**.
2. Add the production Vercel URL to the Supabase redirect URLs.
3. Add the project URL and publishable key to `config.js`.

Never add the database password or service-role key to this repository.

### Browser configuration

Vite bundles `config.js` into the browser assets during each production build. Changing the Supabase project URL or publishable key therefore requires a rebuild and redeployment. The publishable key is intentionally safe for browser use, but it must never be replaced with a service-role key or any secret. Do not put live secrets in client-side Vite variables, `config.js`, or any other file included in the browser bundle.

## Deploy to Vercel

1. Import this GitHub repository in Vercel.
2. Leave **Framework Preset** set to `Other`.
3. Vercel reads the build command and `dist` output directory from `vercel.json`.
4. Deploy with `npm run deploy:production` rather than a raw `vercel deploy`, so the
   target is validated locally before anything is uploaded.
5. Select **Deploy**.

Staging deploys use `vercel.staging.json` and are described in
[`DEPLOY_TARGET_GUARD.md`](DEPLOY_TARGET_GUARD.md).

Dependencies are pinned in `package.json` and `package-lock.json`. No private environment variables are required; `config.js` contains only the public Supabase project URL and publishable key.

## Critical remediation verification

`npm run test:db` creates a uniquely named, guarded disposable PostgreSQL container;
it never stops or resets the normal Supabase development stack. Docker and the cached
`public.ecr.aws/supabase/postgres:17.6.1.165` image are required. The suite applies the
complete migration history and runs SQL business-rule, concurrency, scheduler actor
and member/admin authorization regressions. See [CRITICAL_REMEDIATION.md](CRITICAL_REMEDIATION.md)
for isolation guarantees, the read-only round diagnostic, repair planning and hosted
verification requirements.
