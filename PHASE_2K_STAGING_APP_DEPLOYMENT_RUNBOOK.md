# Phase 2K — Staging Application Deployment and Auth Redirect Runbook

Status: **DESIGNED — NOT APPROVED FOR EXECUTION**

Pinned source commit: `cd0d5ac9708a9ce693d8cfa4712055b44133016d`

Supabase target: staging `evhiixndiuwwodsouyhf` only.

Production Supabase `enzdvsppduyqtpdeseyh`, the production application deployment, Edge Functions,
secrets other than the staging public browser key, cron, automation flags and git pushes are out of
scope.

## 1. Purpose and current state

This runbook defines how a future operator can create one isolated staging application origin,
deploy the staging build policy, and configure exact staging Auth redirects without touching the
production application.

The repository is not linked to any Vercel project: `.vercel/project.json` is absent. No staging
Vercel project, team/scope, project ID or stable staging origin is recorded. Those values must be
obtained from Vercel and operator-confirmed; they must not be guessed.

The implementation at the pinned commit provides:

- production-default `npm run build` and `vercel.json`;
- fail-closed `npm run build:staging` and `vercel.staging.json`;
- compile-time removal of the non-selected Supabase project ref;
- a staging-only CSP and visible `X-LMS-Environment: staging` response header; and
- a target validator that proves bundle/CSP isolation and missing-key refusal.

Creating a bundle does not deploy it. This document authorizes neither action.

## 2. Selected topology

Use a **separate Vercel project** whose sole purpose is LMS staging. Do not use a preview deployment
inside the production Vercel project: project-level settings, environment variables, aliases and
operator selection would remain coupled to production.

Proposed Vercel project name: `last-man-standing-staging`.

This is a proposal, not an asserted existing resource. Before any remote action the operator must
record:

| Field | Required value |
|---|---|
| Vercel team/scope | exact operator-selected slug |
| Vercel project name | exact available name; proposed value above |
| Vercel project ID | ID returned by Vercel after creation/linking |
| Stable staging origin | exact HTTPS project domain |
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

Requires separate remote-read/create authorization. Do not proceed from this design approval.

The operator must:

1. confirm the Vercel team/scope in the dashboard or CLI;
2. prove that the selected project is not the production application project;
3. create or select the dedicated staging project;
4. record its exact project ID, project name and scope privately;
5. configure the staging public-key variable only on that project;
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
- no serverless function or cron definition is introduced; and
- the final command names the recorded Vercel project ID/name, scope and `-A vercel.staging.json`.

Stop and obtain a new explicit mutation approval containing the exact project ID/name, scope,
stable-domain expectation, source commit and configuration hash.

## 7. Checkpoint D — staging-only deployment

Not approved by this runbook design. When separately approved, deploy only to the dedicated staging
project with:

- the recorded project selector and team scope;
- `--local-config vercel.staging.json`;
- the staging project's stable environment; and
- no Git push or production-project alias operation.

The CLI command must be assembled from values returned by Vercel; this document deliberately does
not invent the scope, project ID or final domain.

Immediately after deployment, before Auth configuration:

1. record the exact HTTPS origin Vercel assigned;
2. require the `X-LMS-Environment: staging` header;
3. require the staging-only CSP;
4. inspect the downloaded JavaScript for staging ref present/production ref absent;
5. load only the signed-out registration page;
6. confirm all Supabase network requests target staging; and
7. stop without submitting either registration form or Google OAuth.

This is Wave 0 only and must create no database row.

## 8. Checkpoint E — Supabase staging Auth URL configuration

Requires a separate, action-time approval because it changes cloud Auth settings. It must target
the Supabase dashboard URL containing `/project/evhiixndiuwwodsouyhf/`.

After the stable Vercel origin is known, set on the staging Supabase project only:

| Setting | Exact planned value |
|---|---|
| Site URL | `https://<operator-confirmed-staging-domain>/` |
| Additional redirect | `https://<operator-confirmed-staging-domain>` |
| Additional redirect | `https://<operator-confirmed-staging-domain>/**` |

Replace the placeholder only with the exact origin recorded after deployment. Do not add a broad
`*.vercel.app` or account-wide wildcard. Supabase recommends exact redirect URLs for stable
environments; wildcards are appropriate only where preview-domain variability is intentionally
accepted.

The current email signup code supplies no `emailRedirectTo`, so confirmation uses the staging
project's Site URL. The current Google flow supplies `window.location.origin`; the exact origin must
therefore be allowed. Google OAuth remains deferred until the staging provider configuration and
email template behavior are reviewed separately.

After saving, read back the complete Site URL and redirect list. Refuse if production's application
origin was removed, copied into staging unnecessarily, or if any wildcard authorizes unrelated
Vercel projects.

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
