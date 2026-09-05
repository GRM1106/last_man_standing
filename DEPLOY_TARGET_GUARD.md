# Deploy Target Guard

This repository builds for two isolated environments. Each has its own Supabase project,
its own CSP and its own Vercel project:

| Target | Supabase ref | Vercel config | Deployment entry point | Plain build |
|---|---|---|---|---|
| `production` | `enzdvsppduyqtpdeseyh` | `vercel.json` | `npm run vercel-build:production` | `npm run build` |
| `staging` | `evhiixndiuwwodsouyhf` | `vercel.staging.json` | `npm run vercel-build:staging` | `npm run build:staging` |

A checkout linked with `vercel link` remembers **one** Vercel project in the gitignored
`.vercel/project.json`. Because `vercel.json` is the default config and builds
`production`, a plain `vercel deploy` from a checkout linked to the *staging* project
would have published a production-configured bundle — production Supabase ref, production
CSP — to the staging project. Nothing stopped that except operator discipline.

The guard makes that combination fail instead.

## The safe paths

Deployment validation is built into these commands. There is no separate checker to
remember.

**Staging.** Requires the staging publishable browser key, which never lives in the repo.

```sh
cp .env.staging.example .env.staging.local     # once, then paste the sb_publishable_ value
npm run deploy:staging
```

**Production.**

```sh
npm run deploy:production
```

Each validates the target against the linked Vercel project, then runs `vercel build`
with the matching config and deploys the prebuilt output. `vercel build` re-runs the same
gate through the config's `buildCommand`, so the check happens whether you use the script
or drive the CLI yourself.

`npm run check:deploy-target[:staging|:production]` still exists for a read-only check on
its own, but you no longer have to remember it.

`npm run dev`, `npm run preview`, `npm run build` and `npm run build:staging` are
unaffected — they are ordinary builds, not deployments.

## What the guard checks

All of it lives in [`scripts/lms-deploy-target.mjs`](scripts/lms-deploy-target.mjs), the
single source of truth for which Supabase project, Vercel config and Vercel project
belong to each target. `vite.config.js`, `scripts/check-deploy-target.mjs`,
`scripts/test-build-targets.mjs` and the test suite all import it.

0. **Two rules, not one.** An ordinary build (`npm run build`, CI, a scratch `--outDir`)
   uses the *build rule*: reject a contradiction, allow a checkout with no Vercel link.
   A deployment — anything reached through a Vercel config's `buildCommand`, or through
   `npm run deploy:*` — uses the *deployment rule*: the target must be **positively
   proven**. Absence of evidence is itself a failure there, because a deployment must
   identify where it is going.
1. **Explicit target.** `LMS_BUILD_TARGET` must be `production` or `staging`. A local
   build still defaults to `production` so existing workflows are unchanged, but a build
   running on Vercel (`VERCEL=1`) must state its target — there is no safe default on a
   deployment path.
2. **Supabase isolation.** Each target resolves to its own project URL, and a staging
   build still fails closed without `LMS_STAGING_SUPABASE_PUBLISHABLE_KEY`.
3. **Config/target agreement.** Each Vercel config must name its own build command and
   output directory, its CSP must allow its own Supabase project, and must not allow the
   other one. Neither config is accepted as the other target's policy.
4. **Linked-project agreement.** If `.vercel/project.json` is present, the project it
   names must accept the requested target. This covers `vercel build` and
   `vercel deploy --prebuilt`, which build on this machine.
5. **Vercel build-environment agreement.** When a build runs on Vercel, the documented
   build-time variables `VERCEL_PROJECT_ID` and `VERCEL_PROJECT_PRODUCTION_URL` must not
   identify a project belonging to a different target. This covers a plain
   `vercel deploy`, which builds remotely where `.vercel/project.json` does not exist.

Checks 4 and 5 apply to the deployable output directory (`dist/`) — the artifact a
deployment actually ships. A verification build sent elsewhere with `--outDir` is not
deployable on its own, which is how `npm run test:build-targets` can build both targets
from one checkout. A test pins `outputDirectory` in both configs so that distinction
cannot silently drift.

### Known projects, and what "unknown" means

`VERCEL_PROJECT_IDENTITIES` lists the projects known to belong to each target.

- A target with a **non-empty** list is closed: only a listed project may build it. The
  staging project is listed by id, name and production hostname.
- A target with an **empty** list is open *for ordinary builds*: any project may build it,
  unless another target claims that project. The production Vercel project is deliberately
  not recorded in this repository, so `production` is open in that sense — the staging
  project is still refused, because `staging` claims it. Under the deployment rule an
  empty list means nothing can prove the target, so production deployment is refused
  outright (see below).

When there is no evidence at all — a fresh clone, or CI with no `.vercel/project.json` —
an ordinary **build** proceeds: absence is not a contradiction. A **deployment** does not:
it is refused as unproven. Add a project's id or name to `VERCEL_PROJECT_IDENTITIES` to
close a target or to register a new one.

An unknown project can never prove `staging`, because `staging` is a closed set matched by
exact id, name or production hostname.

### Production deployment is blocked until its project is registered

`VERCEL_PROJECT_IDENTITIES.production` is empty, so **no production deployment can
currently be proven** and `npm run deploy:production` will refuse. This is deliberate: the
production Vercel project identity is not recorded in this repository, and inventing one
would be worse than failing. Discovering the production project's id or name and adding it
there is an explicit prerequisite for production deployment.

Ordinary production builds (`npm run build`, CI, fresh clones) are unaffected.

## The error an operator sees

Running `npm run build` in a checkout linked to the staging project:

```
Refusing to build: deployment target mismatch.

  Requested target     : production
  Conflicting evidence : linked Vercel project name (.vercel/project.json)
                         "last-man-standing-staging" is the staging Vercel project
  Why this is unsafe   : a production build embeds the production Supabase project and production
                         CSP, so deploying it to this project would point that project at
                         production data.

  Safe options:
    - build for the linked project : npm run build:staging   (to deploy: npm run deploy:staging)
    - or link this checkout to the intended production Vercel project first

  If this project is legitimately a new deployment target, add its id or name to
  VERCEL_PROJECT_IDENTITIES in scripts/lms-deploy-target.mjs.
```

And what a plain `vercel deploy` produces in the Vercel build log, where no project
identity is available:

```
Refusing to deploy: the production deployment target could not be proven.

  Requested target   : production
  Evidence found     : none
  Why this is unsafe : a deployment must positively identify the Vercel project it
                       is going to. Without proof, this bundle could be published to
                       a project belonging to another environment.

  A production deployment needs one of these:
    - this checkout linked to the production Vercel project, with that project's id or
      name listed in VERCEL_PROJECT_IDENTITIES (scripts/lms-deploy-target.mjs); or
    - a Vercel build with "Enable access to System Environment Variables" switched on,
      so VERCEL_PROJECT_ID is available, and that id listed there.

  No production Vercel project is recorded in this repository yet. Discovering and
  registering its id or name is a prerequisite for production deployment.
```

Both exit non-zero and write nothing, so `dist/` is left untouched. Guard errors never
contain a publishable key or any other secret; a test asserts this.

## What a raw `vercel deploy` does

Repository code cannot run between typing `vercel deploy` and the upload: that command
uploads the source and builds **on Vercel**, and runs no local package script first. So a
raw `vercel deploy` from a staging-linked checkout is *not* stopped before upload.

It is stopped at the build. Vercel runs `vercel.json`'s `buildCommand`, which is
`npm run vercel-build:production`, which applies the deployment rule and fails because
either `VERCEL_PROJECT_ID` identifies the staging project (a contradiction) or no identity
is available at all (unproven). The deployment errors and nothing is ever served. The
residual cost is a failed deployment in the Vercel dashboard rather than a clean refusal
in the terminal.

The same is true of `vercel deploy --local-config vercel.staging.json`: it is proven only
when system environment variables are enabled for the project. With them off, use
`npm run deploy:staging`, which builds locally where `.vercel/project.json` supplies the
proof — this is also the path the recorded Phase 2K staging deployments used.

## Limits

`.vercel/project.json` is gitignored and is never uploaded, so it cannot help a remote
build. Vercel's system environment variables only exist when *Enable access to System
Environment Variables* is on for the project; with them off, a remote build has no
identity to inspect and every deployment through it is refused as unproven. Turning that
setting on is what makes remote deployments provable.
