export const FPL_BASE_URL = "https://fantasy.premierleague.com/api";
export const DEFAULT_PROVIDER_TIMEOUT_MS = 10_000;
export const DEFAULT_PROVIDER_RETRIES = 2;

export class ProviderError extends Error {
  constructor(message, { classification = "provider", retryable = false, cause } = {}) {
    super(message, { cause });
    this.name = "ProviderError";
    this.classification = classification;
    this.retryable = retryable;
  }
}

// 4xx statuses this upstream has been observed to return transiently. Everything at 5xx
// is retried as well; every other 4xx is treated as a persistent request defect and is
// not retried, so a 400/401/404 still fails on the first attempt.
//
// 429 is ordinary rate limiting. 403 is here because of a real observation on
// 2026-09-06: the first staging Edge Function sync failed with `http_403` while direct
// requests carrying identical headers succeeded throughout, and the same request from
// the same deployed function succeeded 65 seconds later. HTTP 403 from this upstream has
// been observed to be transient from the deployed Edge Function environment, and it
// involves no application authorization. Do not narrow this back to `429` alone.
const TRANSIENT_HTTP_STATUSES = new Set([403, 429]);

const isRetryableStatus = (status) => status >= 500 || TRANSIENT_HTTP_STATUSES.has(status);

const isInteger = (value) => Number.isInteger(value);
const isNullable = (value, predicate) => value === null || value === undefined || predicate(value);
const isBoolean = (value) => typeof value === "boolean";
const isString = (value) => typeof value === "string" && value.trim().length > 0;

function validateTeams(teams) {
  if (!Array.isArray(teams) || teams.length === 0) throw new ProviderError("Provider teams collection is invalid.", { classification: "validation" });
  const ids = new Set();
  teams.forEach((team) => {
    if (!team || !isInteger(team.id) || !isInteger(team.code) || !isString(team.name) || !isString(team.short_name))
      throw new ProviderError("Provider team shape is invalid.", { classification: "validation" });
    if (ids.has(team.id)) throw new ProviderError("Provider team identifiers are not unique.", { classification: "validation" });
    ids.add(team.id);
  });
  return ids;
}

function validateFixtures(fixtures, teamIds) {
  if (!Array.isArray(fixtures) || fixtures.length === 0) throw new ProviderError("Provider fixtures collection is invalid.", { classification: "validation" });
  const ids = new Set();
  fixtures.forEach((fixture) => {
    const valid = fixture && isInteger(fixture.id) && isInteger(fixture.team_h) && isInteger(fixture.team_a)
      && fixture.team_h !== fixture.team_a && teamIds.has(fixture.team_h) && teamIds.has(fixture.team_a)
      && isNullable(fixture.event, (value) => isInteger(value) && value >= 1 && value <= 38)
      && isNullable(fixture.kickoff_time, (value) => isString(value) && !Number.isNaN(Date.parse(value)))
      && isNullable(fixture.team_h_score, isInteger) && isNullable(fixture.team_a_score, isInteger)
      && isNullable(fixture.started, isBoolean) && isNullable(fixture.finished, isBoolean)
      && isNullable(fixture.finished_provisional, isBoolean) && isNullable(fixture.provisional_start_time, isBoolean);
    if (!valid) throw new ProviderError("Provider fixture shape is invalid.", { classification: "validation" });
    if (ids.has(fixture.id)) throw new ProviderError("Provider fixture identifiers are not unique.", { classification: "validation" });
    ids.add(fixture.id);
  });
}

export function validateAndProjectFplPayload(bootstrap, fixtures) {
  if (!bootstrap || typeof bootstrap !== "object") throw new ProviderError("Provider bootstrap payload is invalid.", { classification: "validation" });
  const teamIds = validateTeams(bootstrap.teams);
  validateFixtures(fixtures, teamIds);
  return {
    teams: bootstrap.teams.map(({ id, code, name, short_name }) => ({ id, code, name, short_name })),
    fixtures: fixtures.map(({ id, event, kickoff_time, team_h, team_a, team_h_score, team_a_score, started, finished, finished_provisional, provisional_start_time }) => ({
      id, event, kickoff_time, team_h, team_a, team_h_score, team_a_score, started, finished, finished_provisional, provisional_start_time
    }))
  };
}

async function fetchJson(url, { fetchImpl, timeoutMs }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, {
      headers: { "user-agent": "GRM-LMS/2.0", accept: "application/json", "cache-control": "no-cache" },
      signal: controller.signal,
      cache: "no-store"
    });
    if (!response.ok) throw new ProviderError("The FPL feed returned an unsuccessful response.", {
      classification: `http_${response.status}`,
      retryable: isRetryableStatus(response.status)
    });
    try { return await response.json(); }
    catch (cause) { throw new ProviderError("The FPL feed returned malformed JSON.", { classification: "malformed_json", cause }); }
  } catch (error) {
    if (error instanceof ProviderError) throw error;
    if (error?.name === "AbortError") throw new ProviderError("The FPL feed timed out.", { classification: "timeout", retryable: true, cause: error });
    throw new ProviderError("Could not reach the FPL feed.", { classification: "network", retryable: true, cause: error });
  } finally { clearTimeout(timer); }
}

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

export async function fetchFplData({ fetchImpl = fetch, timeoutMs = DEFAULT_PROVIDER_TIMEOUT_MS, retries = DEFAULT_PROVIDER_RETRIES, retryDelayMs = 150 } = {}) {
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      const [bootstrap, fixtures] = await Promise.all([
        fetchJson(`${FPL_BASE_URL}/bootstrap-static/`, { fetchImpl, timeoutMs }),
        fetchJson(`${FPL_BASE_URL}/fixtures/`, { fetchImpl, timeoutMs })
      ]);
      return validateAndProjectFplPayload(bootstrap, fixtures);
    } catch (error) {
      lastError = error;
      if (!error.retryable || attempt === retries) throw error;
      await delay(retryDelayMs * (attempt + 1));
    }
  }
  throw lastError;
}
