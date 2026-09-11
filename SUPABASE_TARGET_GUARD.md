# Supabase Target Guard

Companion to [`DEPLOY_TARGET_GUARD.md`](DEPLOY_TARGET_GUARD.md), which does the same job
for Vercel. This one covers **remote Supabase operations**: Edge Function deployment,
Edge Function deletion, function secrets, and database migrations.

| Environment | Project ref | Remote operations from this repo |
|---|---|---|
| `staging` | `evhiixndiuwwodsouyhf` | **Permitted** |
| `production` | `enzdvsppduyqtpdeseyh` | **Blocked** — see below |
| anything else | — | Unknown; fails closed |

## The risk

The Supabase CLI remembers a linked project in the gitignored
`supabase/.temp/linked-project.json`, and `functions deploy`, `functions delete`,
`secrets set`, `secrets unset` and `db push` all silently inherit it when no target is
given. This checkout is linked to staging, so a mistyped or copy-pasted command could
operate on the wrong project without ever naming it.

The guarded commands remove the ambiguity: they prove the environment first, then pass
`--project-ref` explicitly so the target never depends on the ambient link.

## Supported commands

```sh
npm run supabase:check:staging                  # read-only: prove the target, run nothing
npm run supabase:deploy:staging                 # deploy lms-scheduler to staging
npm run supabase:delete:staging                 # rollback: remove lms-scheduler from staging
npm run supabase:secrets:set:staging   -- --env-file <path>
npm run supabase:secrets:unset:staging -- --secret LMS_SCHEDULER_SECRET
npm run supabase:db:plan:staging                # read-only: which migrations would apply
npm run supabase:db:push:staging                # apply pending migrations to staging
```

Add `-- --dry-run` to any of them to validate the target and print the exact command
without contacting Supabase:

```sh
npm run supabase:deploy:staging -- --dry-run
# command: npx supabase functions deploy lms-scheduler --project-ref evhiixndiuwwodsouyhf
```

Validation runs **inside** these commands, before the Supabase CLI is invoked. There is
no separate checker to remember.

### Migrations

Always review the pending set before applying it. `supabase:db:plan:staging` runs the
CLI's own `--dry-run`, which connects read-only and prints exactly what would apply:

```sh
npm run supabase:db:plan:staging
# Would push these migrations:
#  • 20260824000700_lms_phase_2k_persist_failed_automation_runs.sql
npm run supabase:db:push:staging
```

`supabase db push` accepts `--project-ref` directly, so the push is targeted explicitly
by the registered ref rather than by the ambient link — the same mechanism as every other
guarded operation. The wrapper builds the argument list itself, so `--include-all`,
`--include-roles`, `--include-seed`, `--db-url` and `--linked` cannot be injected to widen
what gets applied or to retarget the push; a test asserts each is rejected. `--plan` is
accepted only for this operation.

## How the target is proven

The environment mapping lives in
[`scripts/lms-supabase-target.mjs`](scripts/lms-supabase-target.mjs), which imports
`SUPABASE_REF` from `scripts/lms-deploy-target.mjs` so the repository keeps **one**
project-ref mapping shared with the Vercel guard. The wrapper is
[`scripts/supabase-remote.mjs`](scripts/supabase-remote.mjs).

1. **Operation policy.** The environment must be permitted. Production is refused here,
   before anything else is considered.
2. **Registered ref.** The environment must have a project ref in the registry.
3. **Link contradiction.** If `supabase/.temp/linked-project.json` exists, the project it
   names must be the requested one.
4. **Explicit targeting.** The command is built with `--project-ref <registered ref>`.
   The CLI arguments are constructed by the wrapper, not accepted from the caller, so no
   extra flag can be injected.

| Requested | Link says | Result |
|---|---|---|
| staging | staging | **Allowed** — link corroborates |
| staging | *(no link file)* | **Allowed** — the explicit registered ref is positive proof |
| staging | production | **Refused** — wrong checkout or context |
| staging | an unrecognised project | **Refused** — cannot rule out a third project |
| production | anything, including production | **Refused** — operations not permitted |

A contradictory link refuses even though `--project-ref` would have targeted correctly.
A link pointing elsewhere is strong evidence the shell is in the wrong context, and that
is worth stopping for. If you legitimately have no link, the commands still work —
running `npx supabase unlink` is a reasonable hardening step, because it also removes the
ambient target that makes a raw command dangerous.

## Why production is blocked

Both project refs are known; production's appears in `vercel.json`'s CSP and in the Vite
production build. Knowing the ref is deliberately **not** the same as being allowed to use
it. No production Supabase operation has ever been authorised in this repository, and the
Phase 2K evidence records throughout that production was not contacted.

Unblocking production is a deliberate act requiring an explicit operator decision, a
production backup/restore gate, and an edit to `REMOTE_OPERATIONS` in
`scripts/lms-supabase-target.mjs`. There is no flag or environment variable that lifts it,
and an unknown project can never be treated as production.

## Secrets

Values never appear in `package.json`, in any committed script, in a command line, or in
this document. `supabase secrets set` is always invoked with `--env-file`, so the values
come from a file you control:

```sh
# Keep it outside the repository, or gitignored inside it.
printf 'LMS_SCHEDULER_SECRET=…\nLMS_SEASON=2026/27\n' > ../lms-staging-secrets.env
chmod 600 ../lms-staging-secrets.env
npm run supabase:secrets:set:staging -- --env-file ../lms-staging-secrets.env
```

The wrapper refuses an env file that sits inside the repository and is not gitignored,
because such a file can be committed. It prints the file *path* and never its contents,
and it reads no values itself.

Managed secrets — the only names this repository will set or unset — are
`LMS_SCHEDULER_SECRET`, `LMS_SEASON`, `LMS_PROVIDER_TIMEOUT_MS` and
`LMS_PROVIDER_RETRIES`. `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY` are injected by Supabase and are deliberately rejected, so a
platform value cannot be overwritten from here. Only `LMS_SCHEDULER_SECRET` is a secret;
the other three are tuning values with safe in-code defaults.

## Rollback

The first staging deployment has no earlier version to roll back to, so the rollback **is
deletion**:

```sh
npm run supabase:delete:staging -- --dry-run    # confirm the target first
npm run supabase:delete:staging
```

This runs `supabase functions delete lms-scheduler --project-ref evhiixndiuwwodsouyhf`
under exactly the same environment proof as deploy. Do not use a raw
`supabase functions delete` — it inherits the ambient link and names no project.

## Local development is unaffected

These commands are local-only and are deliberately **not** wrapped. They never contact a
remote project and never need a link or a registered environment:

```sh
npx supabase start
npx supabase stop
npx supabase db reset --local
npx supabase functions serve --env-file <local env file>
```

Never pass `--linked` or `--project-ref` to `db reset`: those target a remote project.
Remote migrations do have a guarded command — `supabase:db:push:staging` above — so a raw
`supabase db push` should not be used.

## What this guard is, and is not

**It is a safety control, not an authorization boundary.** It makes the supported path
provably correct and fail-closed, and it makes an accident substantially harder. It does
**not** stop someone typing `supabase functions deploy lms-scheduler` directly — that
invokes the CLI outside this repository's code, which cannot intercept it. Nor does it
grant permission: deploying to staging still requires the separate operator authorization
described in [`PHASE_2J_DEPLOYMENT_RUNBOOK.md`](PHASE_2J_DEPLOYMENT_RUNBOOK.md).

Treat the guarded commands as the only supported way to run a remote Supabase operation
from this repository, and treat a raw CLI invocation as an unreviewed action.
