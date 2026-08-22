# Last Man Standing

A registration page for a private Last Man Standing football tournament.

## Local development

Requires Node.js 22 or newer.

```sh
npm install
npm run dev
```

Useful checks:

```sh
npm test          # XSS and deployment-policy regression tests
npm run build     # production bundle in dist/
npm run check     # tests followed by a production build
npm run preview   # preview the production build locally
npm run audit     # dependency security audit
```

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

Module 23 is the forward-only Phase P1 foundation. Module 24 is the forward-only
Phase P2 controlled-correction layer. Read [`DOMAIN_PHASE_P1.md`](DOMAIN_PHASE_P1.md)
and [`DOMAIN_PHASE_P2.md`](DOMAIN_PHASE_P2.md) before using them. P2 is currently
local-only and is explicitly prohibited from production application. Its
`supabase/result_corrections_verification.sql` companion is rollback-only and is
intended only for a disposable/local Supabase database.

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

### FPL synchronization

FPL synchronization is safe for new or historical seasons only after the final
P1 migration is installed. On an existing deployment, apply only the new forward
P1 migration and verify it before the next sync. On a clean P2 test install, finish all 24
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
4. Select **Deploy**.

Dependencies are pinned in `package.json` and `package-lock.json`. No private environment variables are required; `config.js` contains only the public Supabase project URL and publishable key.
