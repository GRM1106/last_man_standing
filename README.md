# Last Man Standing

A registration page for a private Last Man Standing football tournament.

## Supabase setup

1. Run `supabase/setup.sql` in the Supabase SQL Editor.
2. Enable Google under **Authentication → Sign In / Providers**.
3. Add the production Vercel URL to the Supabase redirect URLs.
4. Add the project URL and publishable key to `config.js`.

Never add the database password or service-role key to this repository.

## Deploy to Vercel

1. Import this GitHub repository in Vercel.
2. Leave **Framework Preset** set to `Other`.
3. Leave the build command and output directory empty.
4. Select **Deploy**.

No dependencies or environment variables are required.
