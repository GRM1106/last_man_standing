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

1. Run `supabase/setup.sql` in the Supabase SQL Editor.
2. Run `supabase/fix_google_names.sql`, `supabase/admin_setup.sql`, `supabase/pot_setup.sql`, `supabase/player_dashboard_setup.sql`, `supabase/pot_gameweek_schedule.sql`, `supabase/fix_multiple_player_pots.sql`, `supabase/fpl_fixture_setup.sql`, then `supabase/player_pick_setup.sql` in that order.
3. Enable Google under **Authentication → Sign In / Providers**.
4. Add the production Vercel URL to the Supabase redirect URLs.
5. Add the project URL and publishable key to `config.js`.

Never add the database password or service-role key to this repository.

### Browser configuration

Vite bundles `config.js` into the browser assets during each production build. Changing the Supabase project URL or publishable key therefore requires a rebuild and redeployment. The publishable key is intentionally safe for browser use, but it must never be replaced with a service-role key or any secret. Do not put live secrets in client-side Vite variables, `config.js`, or any other file included in the browser bundle.

## Deploy to Vercel

1. Import this GitHub repository in Vercel.
2. Leave **Framework Preset** set to `Other`.
3. Vercel reads the build command and `dist` output directory from `vercel.json`.
4. Select **Deploy**.

Dependencies are pinned in `package.json` and `package-lock.json`. No private environment variables are required; `config.js` contains only the public Supabase project URL and publishable key.
