# Last Man Standing

A registration page for a private Last Man Standing football tournament.

## Supabase setup

1. Run `supabase/setup.sql` in the Supabase SQL Editor.
2. Run `supabase/fix_google_names.sql`, `supabase/admin_setup.sql`, then `supabase/pot_setup.sql` in that order.
3. Enable Google under **Authentication → Sign In / Providers**.
4. Add the production Vercel URL to the Supabase redirect URLs.
5. Add the project URL and publishable key to `config.js`.

Never add the database password or service-role key to this repository.

## Deploy to Vercel

1. Import this GitHub repository in Vercel.
2. Leave **Framework Preset** set to `Other`.
3. Leave the build command and output directory empty.
4. Select **Deploy**.

No dependencies or environment variables are required.
