# Phase 2K — Staging Application Deployment and Auth Redirect Runbook

Status: **CHECKPOINT E COMPLETE — AUTHENTICATED SMOKE TESTING NOT APPROVED**

Original build-isolation commit: `cd0d5ac9708a9ce693d8cfa4712055b44133016d`

Deployed source commit: `976ff0fb38b0d8ea69eff360e67defa0e4d483e0`

Supabase target: staging `evhiixndiuwwodsouyhf` only.

Production Supabase `enzdvsppduyqtpdeseyh`, the production application deployment, Edge Functions,
secrets other than the staging public browser key, cron, automation flags and git pushes are out of
scope.

## 1. Purpose and current state

This runbook defines how a future operator can create one isolated staging application origin,
deploy the staging build policy, and configure exact staging Auth redirects without touching the
production application.

Read-only discovery confirmed Vercel user `grm1106` and scope `grm1106s-projects`. The only existing
project was `last-man-standing`, whose latest production URL was `https://www.grm-lms.co.uk`.
No dedicated staging project existed.

Under separate operator approval, the empty project `last-man-standing-staging` was created and this
checkout was linked to it. The ignored local `.vercel/project.json` was inspected immediately and
matched the recorded staging project and scope IDs below. No Git repository was linked, no
deployment or domain was created, and the production project was not opened or changed. Vercel CLI
also created a local `.env.local` containing a temporary OIDC token as an
unrequested side effect; that new file was removed immediately without displaying its value. The
CLI-added broad `.env*` ignore was rejected because it would hide the tracked example files; only
`.vercel` was added to `.gitignore`, committed at
`425a87c3abc412bf53d512ac82bf20aeb7562d51`.

The implementation at the pinned commit provides:

- production-default `npm run build` and `vercel.json`;
- fail-closed `npm run build:staging` and `vercel.staging.json`;
- compile-time removal of the non-selected Supabase project ref;
- a staging-only CSP and visible `X-LMS-Environment: staging` response header; and
- a target validator that proves bundle/CSP isolation and missing-key refusal.

Creating a bundle does not deploy it. Subsequent approvals authorized the recorded prebuild and the
staging-only Checkpoint D deployment; Auth configuration remains unauthorized.

## 2. Selected topology

Use a **separate Vercel project** whose sole purpose is LMS staging. Do not use a preview deployment
inside the production Vercel project: project-level settings, environment variables, aliases and
operator selection would remain coupled to production.

Selected Vercel project name: `last-man-standing-staging`.

The confirmed identity is:

| Field | Required value |
|---|---|
| Vercel user | `grm1106` |
| Vercel team/scope slug | `grm1106s-projects` |
| Vercel scope ID | `team_I4aliqhGtzdQ2j0U5RqB8ROI` |
| Vercel project name | `last-man-standing-staging` |
| Vercel project ID | `prj_7e9MI9tYTLrSlSrdmaXWu2oIs6ZV` |
| Stable staging origin | `https://last-man-standing-staging.vercel.app` |
| Supabase project ref | must equal `evhiixndiuwwodsouyhf` |
| Source commit | must equal the pinned commit or a separately reviewed successor |
| Staging build policy | `vercel.staging.json` SHA-256 at execution time |

Use the **Production environment of the staging-only Vercel project** for its stable staging domain.
In Vercel terminology `--prod` selects that project's Production environment; it does not make the
application the real LMS production deployment. The project ID and scope are therefore load-bearing
guards.

## 3. Required public configuration

The only application build variable is:

`LMS_STAGING_SUPABASE_PUBLISHABLE_KEY`

It must be the staging project's `sb_publishable_` browser key. It is intentionally usable in a
browser, but keep it outside the repository and logs so it cannot be confused with other targets.
Never substitute a database password, service-role key, JWT secret or scheduler secret.

Configure the variable only on the staging Vercel project and only for the environment used by the
stable staging deployment. A missing or malformed value must make the build fail. Do not link a
team-shared variable also used by production.

This variable is now configured as type `Config` in the Production environment of the staging-only
Vercel project. Its value is not recorded. No other remote variable was added.

## 4. Checkpoint A — local identity and artifact proof

Run before contacting Vercel:

1. require a clean tree at the approved commit;
2. recompute hashes for `vercel.staging.json`, `vite.config.js`, `config.js`, `package.json` and the
   lock file;
3. run `npm run check`;
4. run one staging build with the separately supplied public key into a private temporary directory;
5. scan the complete output for the staging ref and require the production ref to be absent;
6. parse `vercel.staging.json` and require the staging HTTPS and WebSocket origins, with production
   absent; and
7. scan the output for secret-shaped or service-role values and stop on any hit.

Record counts and hashes only. Do not commit the staging key or built bundle.

## 5. Checkpoint B — Vercel project identification

Read-only discovery, empty-project creation, local linking and the single public-key configuration
were separately approved and completed. Deployment remains unapproved.

The operator must:

1. confirm the Vercel team/scope in the dashboard or CLI;
2. prove that the selected project is not the production application project;
3. create or select the dedicated staging project;
4. record its exact project ID, project name and scope privately;
5. configure the staging public-key variable only on that project — **complete**: Production
   environment, type `Config`, value not recorded;
6. leave Git auto-deployment disabled unless separately approved; and
7. confirm that no domain assigned to the production application is attached.

If the local directory becomes linked, inspect `.vercel/project.json` immediately and refuse unless
its project ID and scope equal the recorded staging values. Never repair a mismatch by relinking
without a new approval.

## 6. Checkpoint C — exact deployment preview

Vercel documents `--local-config` (`-A`) as the way to select a non-default configuration file.
Every staging build/deploy command must therefore name `vercel.staging.json` explicitly. A command
that would fall back to root `vercel.json` is prohibited.

Before the mutation command, obtain a dry/prebuilt artifact using the recorded staging project and
environment. Verify:

- build command is `npm run build:staging`;
- output directory is `dist`;
- build log identifies the approved commit;
- bundle contains staging ref and not production ref;
- response policy contains `X-LMS-Environment: staging`;
- CSP `connect-src` contains staging HTTPS/WebSocket and not production;
- no serverless function other than the separately reviewed `api/fpl` is packaged, and no cron
  definition is introduced; and
- the final command names the recorded Vercel project ID/name, scope and `-A vercel.staging.json`.

Stop and obtain a new explicit mutation approval containing the exact project ID/name, scope,
stable-domain expectation, source commit and configuration hash.

The approved non-deploying prebuild ran at clean commit
`9316d76838cc756449966571798f0cc2cef2cfe1` with Vercel CLI `59.10.0`, the confirmed staging project
ID and scope, its Production environment, and explicit `vercel.staging.json`. It exited `0` after
invoking `build:staging`. The private output contained 25 files / 413,300 bytes; its path-sorted
file-hash digest was `952bd72c997750e3eabe6ac47ff6f1db617d4ffee1dc66e82f8b9797d424c02a`,
and generated `config.json` SHA-256 was
`056244fcdaf7deceb0879e162290edaf042b82a32f3ea8f290983f4ea10603dd`.

Target-isolation checks passed: four staging-ref occurrences, zero production-ref occurrences,
staging response header present, staging HTTPS and WebSocket CSP origins present, and production ref
absent from policy. Build logs contained zero secret-value patterns. One literal `sb_secret_` marker
was traced to the official Supabase client's key-type detector rather than any credential value.

The checkpoint nevertheless **failed closed** because the artifact packages one Vercel serverless
function, `api/fpl`, as four files under `functions/api/fpl.func`. The runbook requires no function
to be introduced without separate approval. That route is an existing unauthenticated, cached,
read-only compatibility proxy for fixed Fantasy Premier League upstream URLs; its presence is not a
new source-code change, but deploying the empty staging project would create a remote function and
therefore exceed the current authorization. No cron definition was present. Deployment is blocked
until the operator separately chooses and approves either including this reviewed compatibility
function or a validated static-only staging treatment.

Vercel temporarily downloaded `.vercel/.env.production.local` and generated two package manifests
for this local build. All three were removed after validation; only the ignored project link and
Vercel README remain. The private build output is temporary evidence and was not deployed.

### Superseding `api/fpl` review and clean-commit prebuild

The preceding function blocker is resolved technically but not an authorization to deploy. A
read-only review confirmed that `api/fpl` reads no environment value or database, derives no URL
from the request, and calls only two paths beneath the fixed
`https://fantasy.premierleague.com/api` origin. It validates and projects the upstream response,
uses bounded timeout/retry behavior, returns sanitized errors and adds an explicit cache policy.
The review found one avoidable exposure: non-GET methods previously initiated the same upstream
fetch, while such requests need not receive normal GET caching.

Commit `880bc75fc6af2757786fac479eec4b97e2eb80b3` now permits GET only. Every other method returns
`405`, sets `Allow: GET`, and exits before calling the provider. Eleven focused mocked tests and the
full 76-test/build suite passed without live FPL contact.

The final non-deploying Vercel prebuild ran from that exact clean commit with the confirmed staging
project/scope, its Production environment and explicit `vercel.staging.json`. Pull and build both
exited `0`. The private output contained 25 files / 413,450 bytes; its path-sorted file-hash digest
was `2c4769151c14d7cc38673645a0bcb779276fd93ecf8484c33079c576796628ea`.
Generated `config.json` retained SHA-256
`056244fcdaf7deceb0879e162290edaf042b82a32f3ea8f290983f4ea10603dd`.

The packaged function contained exactly one GET guard, one `Allow: GET` and one `405` marker. Target
isolation remained unchanged: staging ref occurrences `4`, production ref occurrences `0`, staging
header and HTTPS/WebSocket CSP origins present, production ref absent from policy, secret-value
patterns in logs `0`, and cron definitions `0`. The downloaded local environment file, generated
manifests and private output were removed after validation. Deployment remains separately gated and
must explicitly authorize creation of this reviewed function in the isolated staging Vercel project.

## 7. Checkpoint D — staging-only deployment

This checkpoint was separately approved and completed. The deployment used only the dedicated
staging project with:

- the recorded project selector and team scope;
- `--local-config vercel.staging.json`;
- the staging project's stable environment; and
- no Git push or production-project alias operation.

The command used the confirmed values returned by Vercel; none was invented.

Immediately after deployment, before Auth configuration:

1. record the exact HTTPS origin Vercel assigned;
2. require the `X-LMS-Environment: staging` header;
3. require the staging-only CSP;
4. inspect the downloaded JavaScript for staging ref present/production ref absent;
5. load only the signed-out registration page;
6. confirm all Supabase network requests target staging; and
7. stop without submitting either registration form or Google OAuth.

This is Wave 0 only and must create no database row.

The exact approved source was clean commit
`976ff0fb38b0d8ea69eff360e67defa0e4d483e0`; `vercel.staging.json` SHA-256 was
`13165abd7c7ef54a3954938f181eacfc4d519d920339ad614299192d17ad1150`. Two
independent prebuilds differed only in Vercel's per-run `builds.json` and
`diagnostics/cli_traces.json`. The remaining 23 stable/deployable relative-path/hash rows were
byte-identical, with manifest SHA-256
`9dca2ab2bf768b8ebf0b94cbf68deaee7c8649f27d7a4977456d86bc387420b0`.
This corrects the earlier aggregate-digest method, which included each output directory's path and
therefore could not be compared across directories.

The prebuilt deployment exited `0`, reached `READY`, and created deployment
`dpl_Fjh9vjEXaPY8RuXWiDTL1UnH2orR`. Vercel assigned the immutable deployment URL
`https://last-man-standing-staging-3bdqaixi5-grm1106s-projects.vercel.app` and stable alias
`https://last-man-standing-staging.vercel.app`. No Git repository was linked.

Signed-out Wave 0 against the stable alias passed without form submission:

| Check | Result |
|---|---|
| Root response | `200` |
| `X-LMS-Environment` | `staging` |
| CSP staging HTTPS / WebSocket origins | present / present |
| Production ref in headers or HTML | 0 |
| Rendered title | `Last Man Standing — Register` |
| Browser requests | 5; all same-origin |
| Production / Supabase / FPL requests | 0 / 0 / 0 |
| Browser warnings/errors | 0 |
| Forms submitted | 0 |

The local prebuilt output, downloaded Vercel environment file, generated manifests and private
audit artifact were removed after verification. The ignored project link remains.

## 8. Checkpoint E — Supabase staging Auth URL configuration

This cloud Auth-setting change was separately approved and completed against the Supabase dashboard
URL containing `/project/evhiixndiuwwodsouyhf/`.

After the stable Vercel origin is known, set on the staging Supabase project only:

| Setting | Exact planned value |
|---|---|
| Site URL | `https://last-man-standing-staging.vercel.app/` |
| Additional redirect | `https://last-man-standing-staging.vercel.app` |
| Additional redirect | `https://last-man-standing-staging.vercel.app/**` |

These values use the exact stable origin recorded after deployment. Do not add a broad
`*.vercel.app` or account-wide wildcard. Supabase recommends exact redirect URLs for stable
environments; wildcards are appropriate only where preview-domain variability is intentionally
accepted.

The current email signup code supplies no `emailRedirectTo`, so confirmation uses the staging
project's Site URL. The current Google flow supplies `window.location.origin`; the exact origin must
therefore be allowed. Google OAuth remains deferred until the staging provider configuration and
email template behavior are reviewed separately.

After saving, the operator refreshed and read back the complete configuration. The Site URL matched
exactly, the redirect list contained exactly the two entries above, and the dashboard reported
`Total URLs: 2`. No production origin was present or changed, and no wildcard covers another Vercel
project. Providers, email templates and every database setting remained unchanged.

## 9. Checkpoint F — signed-out smoke and handoff

Repeat the signed-out Wave 0 checks from `PHASE_2K_STAGING_SMOKE_TEST_RUNBOOK.md`. Do not create test
users under this deployment authorization. Record:

- staging origin and response-header snapshot;
- bundle/config hashes;
- network host inventory;
- console errors;
- desktop and phone screenshots; and
- confirmation that staging row counts remain unchanged.

Only after Wave 0 passes may the operator request Checkpoint C identity/fixture authority from the
smoke-test runbook.

## 10. Stop rules

Stop immediately if:

- the Vercel project/scope is unknown or matches the production application;
- `.vercel/project.json` names an unapproved project;
- `vercel.staging.json` is not explicitly selected;
- the production Supabase ref appears in the staging bundle, CSP or browser network log;
- the staging ref appears in the production bundle or policy;
- the staging public key is missing, malformed, logged or committed;
- a production alias/domain would be attached, replaced or removed;
- Auth configuration is attempted before the stable origin is exact;
- a wildcard would cover unrelated Vercel projects;
- a registration/OAuth form would be submitted without identity-fixture approval; or
- any function, secret, cron, automation flag, database row or production setting would change.

## 11. Completion boundary

This deployment phase is complete only when a staging-only origin serves the staging-isolated
bundle, exact Auth redirects are verified, signed-out Wave 0 passes, and the database remains at the
recorded post-migration counts. It does not authorize test identities, sporting fixtures, admin
promotion, UI redesign, Edge Functions, automation, scheduler work, production deployment or push.

## 12. Source basis

Design verified 2026-08-30 against official documentation:

- [Vercel CLI global options](https://vercel.com/docs/cli/global-options): `--local-config` selects
  an alternate `vercel.json`; `--project` and `--scope` select project identity.
- [Vercel environment variables](https://vercel.com/docs/environment-variables): variables are
  project/environment scoped and apply to new deployments.
- [Supabase Auth redirect URLs](https://supabase.com/docs/guides/auth/redirect-urls): Site URL is
  the default redirect; explicit `redirectTo` values must be allow-listed; exact URLs are
  recommended for stable environments.

No Vercel or Supabase setting was read or changed while designing this runbook.
