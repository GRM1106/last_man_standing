import { describe, expect, it, vi } from "vitest";
import { DEFAULT_PROVIDER_RETRIES, ProviderError, fetchFplData } from "../server/fpl-provider.js";

// Minimal valid payload, so a successful attempt returns rather than failing validation.
const teams = [{ id: 1, code: 10, name: "Alpha", short_name: "ALP" }, { id: 2, code: 20, name: "Beta", short_name: "BET" }];
const fixtures = [{ id: 9, event: 1, kickoff_time: "2026-08-24T12:00:00Z", team_h: 1, team_a: 2, team_h_score: null, team_a_score: null, started: false, finished: false, finished_provisional: false, provisional_start_time: false }];

const ok = (value) => ({ ok: true, status: 200, json: vi.fn().mockResolvedValue(value) });
const httpError = (status, body = "<html>upstream block page: secret-token-abc123</html>") => ({
  ok: false,
  status,
  json: vi.fn().mockResolvedValue(body),
  text: vi.fn().mockResolvedValue(body),
});

/** fetch mock: each attempt consumes two calls (bootstrap + fixtures, issued in parallel). */
function sequence(...attempts) {
  const impl = vi.fn();
  for (const attempt of attempts) {
    if (attempt === "ok") impl.mockResolvedValueOnce(ok({ teams })).mockResolvedValueOnce(ok(fixtures));
    else impl.mockResolvedValueOnce(httpError(attempt)).mockResolvedValueOnce(httpError(attempt));
  }
  return impl;
}

const run = (fetchImpl, options = {}) => fetchFplData({ fetchImpl, retryDelayMs: 0, ...options });

describe("provider retry classification", () => {
  it("classifies a 403 as retryable", async () => {
    const error = await run(sequence(403), { retries: 0 }).catch((caught) => caught);
    expect(error).toBeInstanceOf(ProviderError);
    expect(error.classification).toBe("http_403");
    expect(error.retryable).toBe(true);
  });

  it("recovers when a transient 403 is followed by success", async () => {
    // The exact staging shape: one 403, then an identical request succeeds.
    const fetchImpl = sequence(403, "ok");
    await expect(run(fetchImpl, { retries: DEFAULT_PROVIDER_RETRIES })).resolves.toEqual({ teams, fixtures });
    expect(fetchImpl).toHaveBeenCalledTimes(4); // 2 failed + 2 successful
  });

  it("gives up after the bounded retries when 403 persists", async () => {
    const fetchImpl = sequence(403, 403, 403, 403);
    const error = await run(fetchImpl, { retries: DEFAULT_PROVIDER_RETRIES }).catch((caught) => caught);
    expect(error.classification).toBe("http_403");
    expect(error.retryable).toBe(true);
    // retries: 2 means three attempts in total, so six fetch calls — never a fourth attempt.
    expect(fetchImpl).toHaveBeenCalledTimes(6);
  });

  it("keeps 429 retryable", async () => {
    const error = await run(sequence(429), { retries: 0 }).catch((caught) => caught);
    expect(error.classification).toBe("http_429");
    expect(error.retryable).toBe(true);
    await expect(run(sequence(429, "ok"), { retries: 1 })).resolves.toEqual({ teams, fixtures });
  });

  it("keeps 5xx retryable", async () => {
    for (const status of [500, 502, 503]) {
      const error = await run(sequence(status), { retries: 0 }).catch((caught) => caught);
      expect(error.classification).toBe(`http_${status}`);
      expect(error.retryable).toBe(true);
    }
    await expect(run(sequence(503, "ok"), { retries: 1 })).resolves.toEqual({ teams, fixtures });
  });

  it("keeps other 4xx non-retryable and fails on the first attempt", async () => {
    for (const status of [400, 401, 404, 409, 422]) {
      const fetchImpl = sequence(status, "ok"); // a success is queued but must never be reached
      const error = await run(fetchImpl, { retries: DEFAULT_PROVIDER_RETRIES }).catch((caught) => caught);
      expect(error, `${status} should reject`).toBeInstanceOf(ProviderError);
      expect(error.classification).toBe(`http_${status}`);
      expect(error.retryable, `${status} must not be retryable`).toBe(false);
      expect(fetchImpl, `${status} must not retry`).toHaveBeenCalledTimes(2);
    }
  });

  it("does not treat 403 as an application authorization failure", async () => {
    // The distinction that justifies retrying: it is an upstream transport condition,
    // so it is reported as a provider error, never as a credential problem.
    const error = await run(sequence(403), { retries: 0 }).catch((caught) => caught);
    expect(error.name).toBe("ProviderError");
    expect(error.message).toBe("The FPL feed returned an unsuccessful response.");
  });
});

describe("preserved transient behaviour", () => {
  it("still retries a timeout", async () => {
    const abort = Object.assign(new Error("aborted"), { name: "AbortError" });
    const fetchImpl = vi.fn()
      .mockRejectedValueOnce(abort).mockRejectedValueOnce(abort)
      .mockResolvedValueOnce(ok({ teams })).mockResolvedValueOnce(ok(fixtures));
    await expect(run(fetchImpl, { retries: 1 })).resolves.toEqual({ teams, fixtures });
    const error = await run(vi.fn().mockRejectedValue(abort), { retries: 0 }).catch((caught) => caught);
    expect(error.classification).toBe("timeout");
    expect(error.retryable).toBe(true);
  });

  it("still retries a network failure", async () => {
    const boom = new Error("connection reset");
    const fetchImpl = vi.fn()
      .mockRejectedValueOnce(boom).mockRejectedValueOnce(boom)
      .mockResolvedValueOnce(ok({ teams })).mockResolvedValueOnce(ok(fixtures));
    await expect(run(fetchImpl, { retries: 1 })).resolves.toEqual({ teams, fixtures });
    const error = await run(vi.fn().mockRejectedValue(boom), { retries: 0 }).catch((caught) => caught);
    expect(error.classification).toBe("network");
    expect(error.retryable).toBe(true);
  });

  it("keeps malformed JSON non-retryable", async () => {
    const bad = { ok: true, status: 200, json: vi.fn().mockRejectedValue(new Error("bad json")) };
    const fetchImpl = vi.fn().mockResolvedValue(bad);
    const error = await run(fetchImpl, { retries: DEFAULT_PROVIDER_RETRIES }).catch((caught) => caught);
    expect(error.classification).toBe("malformed_json");
    expect(error.retryable).toBe(false);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("keeps the documented defaults", () => {
    expect(DEFAULT_PROVIDER_RETRIES).toBe(2);
  });
});

describe("safe error reporting", () => {
  it("never leaks the upstream response body, headers or credentials", async () => {
    const error = await run(sequence(403), { retries: 0 }).catch((caught) => caught);
    const surfaced = `${error.message} ${error.classification}`;
    for (const leak of ["secret-token-abc123", "<html>", "upstream block page", "user-agent", "GRM-LMS"]) {
      expect(surfaced).not.toContain(leak);
    }
    // classification carries the status only — safe to store and display.
    expect(error.classification).toMatch(/^http_\d{3}$/);
  });

  it("keeps the classification short enough for the provider-run column", async () => {
    // fail_lms_provider_run truncates error_class to 80 chars; ours stays far below.
    for (const status of [400, 403, 429, 503]) {
      const error = await run(sequence(status), { retries: 0 }).catch((caught) => caught);
      expect(error.classification.length).toBeLessThanOrEqual(80);
    }
  });
});
