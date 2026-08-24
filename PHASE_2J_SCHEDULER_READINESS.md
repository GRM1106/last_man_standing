# Phase 2J — Scheduler Integration & Deployment Readiness

Status: local implementation only. No Supabase project, Vercel deployment, secret, cron job, or remote schema was accessed or changed.

## Architecture decision

The production path is:

`Supabase Cron → lms-scheduler Edge Function → direct uncached FPL fetch → complete_lms_provider_run → sync_fpl_data → Phase 2I scan`

Supabase was selected over Vercel Cron because the durable lock, ingestion transaction, freshness state, kill switches, and automation runner already belong in Postgres. It provides one environment-local operational boundary and avoids making Vercel a second orchestration authority. The Edge Function is a small fetch/authentication adapter; it contains no LMS rules.

Vercel remains the static web host. `/api/fpl` remains temporarily as a cached, read-only compatibility endpoint and imports the same provider module. Scheduled and manual authoritative ingestion do not call it, because its 15-minute CDN cache plus one-hour stale-while-revalidate policy is inappropriate for authoritative result ingestion. Remove it after all consumers have moved to the Edge Function.

## Provider boundary

`server/fpl-provider.js` owns the fixed upstream URLs, allow-list projection, validation, ten-second default timeout, two bounded retries, retry classification, and deliberately uncached requests. Teams and fixtures are fetched together and both must validate before database ingestion begins. A non-2xx response, timeout, malformed JSON, missing collection, invalid identifier, unknown team, invalid gameweek/date/boolean, or duplicate identifier aborts the run. Previous valid database facts remain unchanged.

The FPL feed exposes `started`, `finished`, `finished_provisional`, scores, event/gameweek, kickoff and `provisional_start_time`. It does not provide authoritative LMS-ready classifications for postponed, abandoned, or void fixtures. It can also reassign a fixture's event. Existing Phase 2D selection blocks and governed admin corrections remain the fallback; the scheduler does not infer exceptional sporting outcomes.

## Database operations model

- `lms_provider_runs` records every scheduled, admin, and local-simulation attempt separately from per-pot Phase 2I history.
- A partial unique index permits only one `running` provider run. Overlaps become explicit `skipped/overlap` attempts. Runs older than the configurable stuck threshold are failed safely before a new claim.
- `complete_lms_provider_run` is service-role-only and transactionally performs ingestion, provider-state update, Phase 2I scan, and terminal run update.
- `lms_provider_state` records last attempt, success, ingestion, counts, and safe failure state. Freshness never depends on one fixture row.
- `lms_operations_config` separates provider fetch automation, competition scanning, and platform scheduler expectation. All default off.
- Manual sync uses the same Edge Function, provider validation, lock and ingestion path as scheduling.

The database service role is treated as an internal operator by `is_current_user_admin`; it is never available in browser code. Public scheduler claim/completion/failure RPCs are revoked from `anon` and `authenticated`. Admin health is RLS/RPC gated. Players receive only a safe delayed-updates message.

## Freshness and cadence

The operational defaults are warning after three hours and critical after six hours. They can vary by environment without changing product rules. Applying a non-test result after kickoff is blocked when provider ingestion is critically stale; waiting and pre-match selection activity are not described as a sporting outcome.

Recommended initial production cadence is every two hours continuously. This is periodic updating, not live scores. A later evidence-led change may poll hourly during likely match windows, but should not add a complex adaptive scheduler until platform usage and provider reliability justify it.

## Retry, timeout, and recovery

Network errors, timeouts, HTTP 429, and provider 5xx responses are retried twice with short bounded backoff. Malformed JSON and schema validation failures are not retried. On terminal failure the attempt is recorded, ingestion and automation are skipped, and the previous good provider facts remain intact. A later successful run clears the current provider error and refreshes freshness.

## Authentication and secrets

Scheduled requests require `LMS_SCHEDULER_SECRET`. Manual requests require a valid user JWT whose profile is an administrator. The Edge Function alone receives `SUPABASE_SERVICE_ROLE_KEY`. Environment placeholders are documented in `.env.example`; `.env` variants are ignored. Hosted secrets must be configured separately in each Supabase project. Never place scheduler, database, or service-role credentials in Vite/client configuration.

## Local simulation and verification

`npm run test:db` builds a disposable local database through Phase 2J. The Phase 2J verification claims a local run, sends deterministic provider fixtures through the transactional ingestion-and-scan entry point, checks health, and rolls back. The same suite starts two genuine database sessions concurrently and requires one running import plus one recorded overlap. `tests/scheduler-pipeline.test.js` covers fetch/validate/ingest/scan sequencing, partial/malformed rejection, failure isolation, bounded retry, and pre-fetch overlap skipping without the live FPL API.

For an optional local Edge Function smoke test, start Supabase with functions enabled, set only local secrets, serve `lms-scheduler`, and POST `{ "source": "local_simulation", "season": "2026/27" }` with an authenticated local admin token. The deterministic regression suite remains the required test; a live provider response is not required for ordinary CI.

## Monitoring and alerts

The admin Fixtures view shows last success, data age/freshness, last safe error, automation counts, and the distinction between `not deployed`, `disabled`, and an enabled target flag. Candidate external alert conditions for a later phase are: no success beyond critical freshness, repeated failures, a stuck run, elevated per-pot failures, and scheduler expectation/configuration drift. Phase 2J sends no notifications.

## Remaining limitations

- No remote scheduler exists and `scheduler_expected` remains false.
- External alert delivery is not implemented.
- Edge Function integration is locally shaped but remote runtime validation belongs to controlled staging.
- Backup/restore capability and the actual staging/production migration state remain unverified operator gates.
- The public cached `/api/fpl` compatibility route remains until consumers are confirmed migrated.

See `PHASE_2J_DEPLOYMENT_RUNBOOK.md` before any remote work.
