# Security Phase 1 preview verification

Date: 2026-08-21

## Deployment

- Branch: `security/phase-1-preview`
- Original Phase 1 commit: `db7fe4c95e64c58a780a90500a2268fc63002e24`
- ESM proxy fix commit: `5b7150f922231e224a3ac206cdc26a09f1d7fa4d`
- Environment: Vercel Preview (`production_environment: false`)
- Fix preview URL: `https://last-man-standing-qtwb1hkfi-grm1106s-projects.vercel.app`
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

## Authenticated checks still required

Use designated test accounts only. Do not enter credentials into an automated handoff or alter real player data.

- Complete email/password sign-in on the preview origin.
- Complete the Google OAuth round-trip and confirm return to the preview origin.
- Verify the waiting/approval screen with a designated unapproved test account.
- Verify the player dashboard, pick rendering, standings rendering, and Premier League badges.
- Verify the admin dashboard with a designated admin test account.
- Confirm Supabase Auth, RPC, and PostgREST HTTPS traffic succeeds without CSP violations.
- Confirm whether the application initiates any required Supabase WebSocket traffic; none was observed unauthenticated.
- Verify Admin FPL synchronization with an explicitly authorized test pot. The proxy is repaired, but synchronization was not invoked because it writes to Supabase.
- Run the stored-XSS check only with a designated test account and an inert payload, with explicit approval before changing test profile data.

## Status

- LMS-06 is **not yet fully preview-verified** because authenticated email/password, Google OAuth, player, waiting, and admin journeys remain incomplete.
- The automated unauthenticated preview checks pass, but the preview is **not yet safe to promote** until the authenticated checklist is completed.
- Production has not been modified or verified.
