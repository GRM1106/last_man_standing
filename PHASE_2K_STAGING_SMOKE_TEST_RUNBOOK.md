# Phase 2K — Staging Application Smoke-Test Runbook

Status: **CHECKPOINT A LOCALLY PROVEN — CHECKPOINTS B–D NOT APPROVED**

Target: staging Supabase project `evhiixndiuwwodsouyhf` only.

Production project `enzdvsppduyqtpdeseyh` is out of scope. This runbook authorizes no database
change, application deployment, function deployment, secret configuration, cron operation,
automation enablement or git push.

## 1. Purpose

This runbook defines the smallest honest browser-level demonstration that the application can use
the completed Phase 2K staging schema without weakening its authorization boundaries. It separates:

1. checks that are static or read-only;
2. creation of isolated staging identities and fixtures;
3. application deployment to a staging-only origin; and
4. sporting workflows that cannot be tested while staging contains no football data.

Each boundary requires its own explicit approval. Designing the plan does not approve execution.

## 2. Current blockers

The smoke test is **NOT READY** for three independent reasons.

### 2.1 The browser bundle targets production

`config.js` currently contains the production Supabase URL and production publishable key.
`vercel.json` permits only the production Supabase HTTPS and WebSocket origins in `connect-src`.
Building or serving the repository unchanged would therefore exercise production, not staging.

Do not work around this in browser developer tools, by editing the generated `dist/` files, or by
temporarily replacing committed production values without a reviewed staging-build mechanism.

### 2.2 No staging application origin is recorded

The repository records no staging Vercel project, preview URL or other staging-only application
origin. A future deployment plan must name the exact origin, bind it only to staging's public
browser configuration, and add that exact origin to staging Auth redirect allow-lists. It must not
alter the production deployment or production Auth configuration.

### 2.3 Staging is intentionally empty

Post-migration evidence shows zero `auth.users`, zero profiles, zero football teams and fixtures,
and zero rows in every core player/competition table. Authentication, admin, pot and player smoke
cases therefore require controlled test data. Player picks, result processing and standings also
require football facts that do not exist. No disposable database seed or verification script may
be run against staging.

## 3. Required approvals and checkpoints

### Checkpoint A — static/local preparation

Requires approval to design and locally validate a staging-specific configuration mechanism. It
may run tests and builds locally but may not contact any Supabase project or deploy anything.

Required outcome:

- production remains the default committed deployment target;
- a staging build receives only staging's public URL and publishable key through an explicit,
  reviewable mechanism;
- the staging CSP permits only the staging Supabase HTTPS/WebSocket origins;
- a production build still contains only production origins;
- `npm test`, `npm run build` and the security-config tests pass for both variants; and
- neither build contains a database password, service-role key or scheduler secret.

Checkpoint A was completed locally on 2026-08-30. `vite.config.js` injects one selected target at
compile time; production remains the default, while staging requires `LMS_BUILD_TARGET=staging`
and a supplied `LMS_STAGING_SUPABASE_PUBLISHABLE_KEY`. The target validator proved that each bundle
contains its own project ref and not the other, the two CSP policies have the same isolation, and a
staging build without its publishable key refuses. The existing 75 tests and one new deployment
policy test passed. No bundle was deployed and no real staging key was written to the repository.

### Checkpoint B — staging application deployment

Requires separate authority to create or update one named staging-only application deployment and
staging Auth redirect configuration. The operator must confirm both the application origin and
Supabase ref immediately before deployment. Production remains untouched.

Required outcome:

- the deployed bundle's network configuration names only `evhiixndiuwwodsouyhf`;
- its CSP names only the staging Supabase origin;
- the staging deployment is visibly labelled as staging;
- no Edge Function, secret, cron job or automation flag is changed; and
- unauthenticated page loads make no request to production.

The exact project/origin and Auth sequencing for this checkpoint is defined in
`PHASE_2K_STAGING_APP_DEPLOYMENT_RUNBOOK.md`. Checkpoint B is complete for the isolated Vercel
project `last-man-standing-staging`: the stable origin is
`https://last-man-standing-staging.vercel.app`, signed-out Wave 0 passed, and the staging Auth Site
URL and two exact redirect entries were saved and read back. This does not authorize an
authenticated test or any further deployment.

### Checkpoint C — identity and fixture mutation

Requires a fresh backup/RPO confirmation and explicit approval for the exact staging rows to be
created. The plan must name the test identities, administrator-provisioning method, fixture rows,
cleanup owner and retention decision before the first write.

Minimum identities:

- one administrator;
- player A; and
- player B, used to prove cross-player privacy.

Use purpose-created test addresses, never real player accounts. Record identifiers privately, not
in the repository. Creating Auth users must create exactly one corresponding profile through the
`create_profile_after_signup` trigger. Administrator promotion needs its own reviewed mechanism;
the public signup path must not be able to grant admin status.

### Checkpoint D — sporting fixture data

Player picks and result workflows remain blocked until a separately reviewed plan provides safe
staging football teams and fixtures. Do not click **Sync football data now**, deploy the scheduler
function, call a provider ingestion path, or copy local/disposable seed SQL into staging under this
runbook.

## 4. Smoke matrix

Every case records timestamp, staging application origin, browser, account role, expected result,
actual result and a sanitized screenshot or note. Network inspection must show no request to the
production Supabase ref.

### Wave 0 — no database writes

| Case | Expected result |
|---|---|
| Registration page | Loads without console error; email and Google controls render |
| Protected player route while signed out | Redirects to `/` |
| Protected admin route while signed out | Redirects to `/` |
| Browser target inspection | Every Supabase request names staging ref only |
| Security headers | CSP blocks unapproved remote origins and framing |
| Accessibility basics | Forms have labels; status messages announce; keyboard focus is visible |
| Responsive shell | Registration, waiting, dashboard and admin layouts do not overflow at phone and desktop widths |

Wave 0 may proceed only after Checkpoints A and B. It creates no database row.

### Wave 1 — authentication and profile trigger

| Case | Expected result |
|---|---|
| Register player A by email | Auth user created; exactly one matching profile created |
| Registration validation | Weak/invalid input fails safely without exposing internals |
| Confirm/sign in | Session established and user reaches waiting page |
| Sign out | Session cleared and protected pages redirect |
| Repeat sign-in | No duplicate profile is created |
| Player opens `/admin.html` | Access denied; no player list or admin data returned |

Wave 1 requires Checkpoint C. Do not use Google OAuth until its staging provider and redirect
configuration have been separately reviewed; email authentication is the minimum smoke path.

### Wave 2 — administrator and empty-state authorization

| Case | Expected result |
|---|---|
| Admin sign-in | Admin link appears and admin page loads |
| Player list | Shows only the three approved test identities |
| Player A dashboard | Shows registered/no-pot empty state without an error |
| Player B dashboard | Shows registered/no-pot empty state without an error |
| Cross-player access | Player A cannot read player B's profile or private state |
| Operations health | Flags remain disabled; no scheduler expectation is shown as enabled |

Direct catalogue/API evidence must accompany UI observations for the cross-player denial. A blank
screen alone is not authorization evidence.

### Wave 3 — draft pot and membership

| Case | Expected result |
|---|---|
| Admin creates one clearly named draft smoke pot | One pot and its planned gameweeks are created |
| Admin assigns players A and B | Two memberships, no duplicate membership |
| Both player dashboards | Each shows the same assigned draft pot |
| Player privacy | Each player sees only their own pick/payment/buy-back details |
| Non-admin mutation attempt | Refused by the database, not merely hidden by the UI |
| Admin deletes the draft pot during cleanup | Pot-owned smoke rows are removed according to reviewed cleanup rules |

Do not activate the pot, take payment decisions, or test picks in Wave 3. The UI currently requires
at least one assigned player and builds the full gameweek schedule through GW38; expected row counts
must be calculated before approval.

### Wave 4 — blocked until football data is approved

The following are not executable while staging remains empty:

- team availability and pick confirmation;
- deadline closure and random missing picks;
- normal, postponed, abandoned or corrected fixture results;
- round processing, elimination and progression;
- collective reinstatement and buy-back lifecycle;
- GW38 completion and winner allocation;
- governed-review creation/resolution;
- manual provider synchronization;
- Phase 2I automation; and
- scheduler overlap, retry, stale-data and kill-switch demonstrations.

These are covered by local transactional/concurrency tests but still require a later staging data,
function and secret plan before they can become staging application evidence.

## 5. Stop rules

Stop immediately if:

- the production ref or production Supabase hostname appears anywhere in the staging build,
  browser URL, network log or Auth redirect;
- the staging application origin is not exact and operator-confirmed;
- an unapproved database row would be created or changed;
- any real player identity or data appears;
- signup does not create exactly one profile;
- a non-admin receives admin data or a player receives another player's private state;
- a test expects football data that staging does not contain;
- an automation/provider button would run, a flag is enabled, or scheduler state changes;
- a console/network/database error is waived rather than explained; or
- cleanup would delete anything not created by the approved smoke run.

Do not compensate for a failed smoke check by weakening RLS, granting broader privileges, editing
staging data manually, enabling automation, or switching the browser build to production.

## 6. Evidence and cleanup

Keep raw screenshots, browser logs and exported counts outside the repository in an owner-only
directory. Evidence committed to the repository must be sanitized: no tokens, session contents,
public keys, email addresses, Auth user IDs, connection URLs or raw internal errors.

Before cleanup, record exact counts and IDs privately. Cleanup must be separately approved and must
target only the named smoke identities and pot. Prefer deleting the draft pot through its reviewed
admin workflow. Auth-user deletion and any residual profile cleanup need explicit targets and an
after-state check. Never use broad predicates, globs or inferred identifiers.

After cleanup require:

- zero smoke Auth users and profiles, unless retention was explicitly approved;
- zero smoke pots, memberships and schedules;
- the two Phase 2J singleton rows still present with all automation flags false;
- all 38 migration versions unchanged;
- no unexpected application rows; and
- a fresh read-only security/ACL postcheck.

## 7. Completion boundary

The staging application smoke test is complete only when all approved waves pass, every mutation is
accounted for, and cleanup or intentional retention is verified. Passing Waves 0–3 does not imply
that picks, match processing, automation, scheduler operation or production deployment work.

This runbook does not approve the visual redesign requested by the operator. UI redesign should be
a separate local branch of work after the staging-target mechanism is safe, with accessibility,
responsive and regression testing before any staging deployment.

## 8. Exact Wave 1A plan — one disposable email player

This section is a design only. It does not authorize signup, email confirmation, sign-in, Auth-user
deletion or any other write. Each mutation phase requires a new explicit approval.

### 8.1 Scope and private identity record

Wave 1A uses exactly one purpose-created email address controlled by the operator. Before signup,
record the exact email address, intended first and last names, cleanup owner and retention decision
in an owner-only evidence file outside every Git work tree. Do not put the address, password, Auth
user ID, confirmation link, access token or session contents in this repository or chat.

Use a unique password generated for this staging account and stored in the operator's password
manager. Do not reuse a real-player or production password. Leave the optional phone field empty.
The identity must not be promoted, approved, assigned to a pot or retained by default: the selected
disposition for Wave 1A is deletion after the approved checks.

Immediately before signup, confirm all of the following:

- the Git work tree is clean at the reviewed commit;
- the browser origin is exactly `https://last-man-standing-staging.vercel.app/`;
- the page configuration and any Supabase request name only staging ref `evhiixndiuwwodsouyhf`;
- production ref `enzdvsppduyqtpdeseyh` is absent;
- a fresh read-only check finds zero `auth.users` and zero `public.profiles`; and
- the fresh pre-Wave-1 backup RPO `2026-08-30T15:56:54Z` is recorded and still applicable.

Any failure stops the run before a form is submitted.

### 8.2 Approved-path test sequence

After a separate execution approval naming the privately recorded identity:

1. Open the stable staging origin in a clean browser context and verify it starts signed out.
2. Select email registration. Enter the recorded first name, last name, email and unique password;
   leave phone empty. Submit exactly once. Do not click Google.
3. Record the sanitized user-facing result. If Supabase returns an immediate session, continue at
   step 5. If the page says confirmation is required, continue at step 4. Any other outcome stops.
4. Open only the confirmation message for this disposable address. Before following its link,
   verify the destination belongs to the staging Supabase project and returns to the exact stable
   staging origin. Do not paste or record the link. Follow it once.
5. Confirm the authenticated browser reaches `/waiting.html`, displays the supplied first name,
   shows no Admin link, and makes no request to production.
6. Run the approved read-only verification. Require exactly one matching `auth.users` row and one
   matching `public.profiles` row sharing the same UUID. Require `approved=false`,
   `is_admin=false`, the supplied names, the disposable email, and `mobile_number is null`.
7. Open `/admin.html` directly. Require the access-denied state and no player list or admin data.
8. Sign out. Require return to `/`, then directly open `/waiting.html` and `/admin.html`; both must
   return to `/` without exposing protected content.
9. Sign in once with the same email and password. Require `/waiting.html` again and re-run the
   read-only check: still exactly one Auth user and one profile, with no duplicate profile.
10. Sign out again and stop. Do not approve the player, create an administrator, create a pot or
    proceed to Wave 2.

This Wave deliberately does not test an invalid or weak-password submission: that would be another
Auth request with rate-limit and account-enumeration implications. It may be designed separately
after the basic path succeeds.

### 8.3 Stop conditions

In addition to section 5, stop immediately if the form would be submitted more than once, an email
or redirect names an unexpected origin, signup produces no profile or more than one profile, the
profile values differ from the submitted non-sensitive fields, the account becomes approved or
admin, `/admin.html` exposes protected content, sign-out leaves a usable session, or repeat sign-in
changes either row count.

Do not repair a failed run manually. Preserve sanitized evidence, leave the exact identity in place,
and obtain a diagnosis/cleanup decision.

### 8.4 Cleanup plan — separately approved

Cleanup is performed only after a distinct approval naming the privately recorded Auth user UUID
and email. First prove that the UUID owns no row outside `public.profiles`. Then delete that exact
user through the staging Supabase Authentication user-management UI. The foreign key
`public.profiles.id references auth.users(id) on delete cascade` is expected to remove the matching
profile; no direct profile delete is planned.

After deletion, require read-only proof that the exact UUID and email are absent from both
`auth.users` and `public.profiles`, total counts for both tables have returned to zero, no other
application row changed, the Phase 2J automation rows remain disabled, migration history is
unchanged, and the security/ACL postcheck still passes. If the profile remains, stop: do not issue a
manual delete without a new diagnosis and approval.

### 8.5 Evidence boundary and approvals still required

The owner-only evidence bundle should contain timestamps, reviewed commit, origin, sanitized
screenshots, request-origin summary, pre/post counts and private identity/UUID record. Repository
evidence may state only pass/fail facts and counts.

Two future approvals remain mandatory:

1. execute signup and the read-only Wave 1A checks for the exact privately recorded identity; and
2. delete that exact Auth user and verify cleanup.

Neither approval permits Google OAuth, administrator provisioning, additional identities, database
editing, production contact, deployment, provider/secret/cron changes or Git push.
