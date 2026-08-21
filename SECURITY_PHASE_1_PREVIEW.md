# Security Phase 1 preview verification

Date: 2026-08-21

## Deployment

- Branch: `security/phase-1-preview`
- Original Phase 1 commit: `db7fe4c95e64c58a780a90500a2268fc63002e24`
- ESM proxy fix commit: `5b7150f922231e224a3ac206cdc26a09f1d7fa4d`
- Environment: Vercel Preview (`production_environment: false`)
- Fix preview URL: `https://last-man-standing-qtwb1hkfi-grm1106s-projects.vercel.app`
- Authenticated validation URL: `https://last-man-standing-gq57dvqz0-grm1106s-projects.vercel.app`
- Production promotion: not performed

## Automated results

- `/`: direct navigation and hard refresh returned `200` with the registration entry and its bundled assets.
- `/waiting`: direct navigation returned `200` with the waiting entry and bundled assets, then redirected to `/` because no Supabase application session existed on the preview origin.
- `/dashboard`: direct navigation returned `200` with the dashboard entry and bundled assets, then redirected to `/` because no Supabase application session existed on the preview origin.
- `/admin`: direct navigation returned `200` with the admin entry and bundled assets, then redirected to `/` because no Supabase application session existed on the preview origin.
- All observed first-party JavaScript and CSS assets returned `200` with appropriate MIME types.
- A representative Premier League badge returned `200 image/png` from `resources.premierleague.com`.
- No application runtime exception was observed during the unauthenticated route checks.
- Vercel's optional preview feedback script was blocked by `script-src 'self'`. This widget is not required by the application, so the CSP should not be weakened for it.
- `/api/fpl` failed with `500 text/html`. Local reproduction confirms that `package.json` declares `type: module` while `api/fpl.js` uses CommonJS `module.exports`, causing `ReferenceError: module is not defined in ES module scope` before the handler runs.
- After redeploying the ESM fix, `/api/fpl` returned `200 application/json` with the expected `teams` and `fixtures` arrays (20 teams and 380 fixtures), with no `error` or internal `detail` field.

## Local remediation and preview redeployment

- Converted `api/fpl.js` from CommonJS `module.exports` to an ESM default function export compatible with the repository's `type: module` runtime.
- Preserved the upstream FPL URLs, request headers, success mapping, cache policy, HTTP status behavior, and JSON success structure.
- Removed internal exception detail from the public fallback error response; callers still receive the existing safe error message and `502` status.
- Added direct tests of the real serverless module covering ESM import, callable default export, successful upstream responses, upstream HTTP failure, thrown upstream errors, cache headers, JSON mapping, and the existing method-agnostic behavior.
- Added a configuration regression test rejecting CommonJS globals in JavaScript files under `api/`.
- Local verification passed: `npm test` (29/29), `npm run check`, `npm run build`, `git diff --check`, direct ESM import of `api/fpl.js`, and the complete runtime-JavaScript CommonJS-global search. The Vercel CLI is not installed locally, so no additional local Vercel emulator was available.
- Vercel deployed the exact fix commit as a non-production Preview. Repeated direct-navigation, hard-refresh, asset, header, console, and network checks passed on that deployment.

## Response headers

Each application route returned exactly one effective `Content-Security-Policy` header containing:

- `default-src 'self'`
- `script-src 'self'`
- `style-src 'self'`
- `connect-src 'self' https://enzdvsppduyqtpdeseyh.supabase.co wss://enzdvsppduyqtpdeseyh.supabase.co`
- `img-src 'self' https://resources.premierleague.com`
- `font-src 'self'`
- `object-src 'none'`
- `base-uri 'self'`
- `form-action 'self'`
- `frame-ancestors 'none'`

Each application route also returned:

- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()`

## Authenticated read-only results

- Authentication persisted on the exact Vercel preview origin.
- A designated administrator-capable test account was used. No identity, credentials, session data, or player PII was recorded.
- `/dashboard` loaded successfully through direct navigation and hard refresh.
- `/waiting` correctly redirected the already-approved account to `/dashboard`.
- `/admin` loaded successfully with the account's existing authorization. No admin action was invoked.
- Ordinary calls to the dashboard, selection, history, team-availability, standings, deadline, and admin-check RPCs returned `200`.
- Existing picks, fixtures, and standings rendered, and all 47 observed Premier League badge images loaded successfully.
- No application runtime exception or unexpected network failure was observed.
- No WebSocket connection was initiated during ordinary page loading. The application did not demonstrate a dependency on realtime traffic in this journey.
- The only CSP block was Vercel's nonessential preview-feedback script. The application did not require it, and the CSP was not weakened.
- Logout cleared the preview-origin session. After logout, direct navigation and hard refresh of `/dashboard`, `/waiting`, and `/admin` redirected to `/`, and protected content was no longer visible.
- The production-origin session was untouched: no production-origin tab was claimed, inspected, navigated, or signed out.
- No picks, FPL syncs, payments, buy-backs, gameweek processing, admin actions, or other application-data mutations were performed.

### Authentication-method coverage

- Existing authenticated session on the preview origin: **passed**.
- Email/password sign-in flow: **unknown / not independently evidenced**. The validation did not identify the method used to create the session.
- Google OAuth round-trip: **unknown / not independently evidenced**. The validation did not identify the method used to create the session.
- Already-approved account routing: **passed**.
- Waiting/approval behavior for an unapproved account: **untested** because no designated unapproved account was used.

## Supabase Auth preview redirect configuration

- Supabase Auth's additional redirect allowlist was updated by the project owner to permit the account-scoped preview pattern `https://*-grm1106s-projects.vercel.app/**`.
- The production Site URL remains `https://www.grm-lms.co.uk`.
- The allowlist pattern is scoped to previews under the named Vercel account; a completely broad `https://*.vercel.app/**` entry was not used.
- The preview entry should be removed or narrowed after preview testing unless ongoing preview OAuth is intentionally supported.
- This record documents the externally applied setting. No Supabase setting was changed during this validation.

## Data-changing checks still requiring separate authorization

Use designated test accounts only. Do not enter credentials into an automated handoff or alter real player data.

- Verify the waiting/approval screen with a designated unapproved test account.
- Verify Admin FPL synchronization with an explicitly authorized test pot. The proxy is repaired, but synchronization was not invoked because it writes to Supabase.
- Run the stored-XSS check only with a designated test account and an inert payload, with explicit approval before changing test profile data.
- Exercise pick, payment, buy-back, gameweek-processing, and other mutating workflows only with explicit authorization and isolated test data.
- If release policy requires authentication-method-specific evidence, separately complete email/password and Google OAuth journeys without inferring either from the existing session.

## Status

- LMS-06 is **preview-verified for automated and read-only authenticated behavior**. Effective headers, required application resources, Supabase HTTPS RPC traffic, routing, protected-route behavior, and authenticated rendering were verified on Vercel Preview.
- Email/password and Google OAuth remain method-specific unknowns rather than claimed passes. Data-changing workflows remain outside this read-only verification scope.
- Based on the automated and read-only authenticated evidence, the preview is safe to promote from the LMS-06 perspective. This record does not approve production deployment or resolve the separate launch-blocking findings in the repository audit.
- Production has not been modified or verified.
