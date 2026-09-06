import { describe, expect, it, vi } from "vitest";
import { fetchFplData, ProviderError, validateAndProjectFplPayload } from "../server/fpl-provider.js";
import { runSchedulerPipeline } from "../server/scheduler-pipeline.js";
import { readFileSync } from "node:fs";

const teams = [{ id: 1, code: 10, name: "Alpha", short_name: "ALP" }, { id: 2, code: 20, name: "Beta", short_name: "BET" }];
const fixtures = [{ id: 9, event: 1, kickoff_time: "2026-08-24T12:00:00Z", team_h: 1, team_a: 2, team_h_score: null, team_a_score: null, started: false, finished: false, finished_provisional: false, provisional_start_time: false }];
const jsonResponse = (value, status = 200) => ({ ok: status >= 200 && status < 300, status, json: vi.fn().mockResolvedValue(value) });
const fetchSuccess = () => vi.fn().mockResolvedValueOnce(jsonResponse({ teams })).mockResolvedValueOnce(jsonResponse(fixtures));

describe("scheduler provider boundary", () => {
  it("rejects malformed and partial provider payloads before ingestion", () => {
    expect(() => validateAndProjectFplPayload({ teams }, [{ ...fixtures[0], team_a: 99 }])).toThrow(ProviderError);
    expect(() => validateAndProjectFplPayload({ teams }, [])).toThrow("fixtures collection");
  });

  it("runs fetch, validation, ingestion and scan through one operation", async () => {
    const operations = { claim: vi.fn().mockResolvedValue({ acquired: true, run_id: "run-1" }), ingestAndScan: vi.fn().mockResolvedValue({ status: "succeeded" }), fail: vi.fn() };
    await expect(runSchedulerPipeline({ source: "local_simulation", season: "2026/27", operations, fetchOptions: { fetchImpl: fetchSuccess(), retries: 0 } })).resolves.toEqual({ status: "succeeded" });
    expect(operations.ingestAndScan).toHaveBeenCalledWith("run-1", "2026/27", { teams, fixtures });
    expect(operations.fail).not.toHaveBeenCalled();
  });

  it("records provider failure and never calls ingestion", async () => {
    const operations = { claim: vi.fn().mockResolvedValue({ acquired: true, run_id: "run-2" }), ingestAndScan: vi.fn(), fail: vi.fn() };
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse({}, 503));
    await expect(runSchedulerPipeline({ source: "scheduler", season: "2026/27", operations, fetchOptions: { fetchImpl, retries: 0 } })).rejects.toMatchObject({ classification: "http_503", retryable: true });
    expect(operations.ingestAndScan).not.toHaveBeenCalled();
    expect(operations.fail).toHaveBeenCalledWith("run-2", "http_503", true);
  });

  it("does not fetch when the database lock reports an overlap", async () => {
    const fetchImpl = vi.fn();
    // Shape returned by claim_lms_provider_run when another run holds the lock.
    const claim = { acquired: false, run_id: "attempt-2", active_run_id: "run-1", reason: "already_running" };
    const operations = { claim: vi.fn().mockResolvedValue(claim), ingestAndScan: vi.fn(), fail: vi.fn() };
    await expect(runSchedulerPipeline({ source: "admin", season: "2026/27", operations, fetchOptions: { fetchImpl } })).resolves.toEqual({ status: "skipped", reason: "already_running", runId: "attempt-2" });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("reports the kill switch as disabled rather than as an overlap", async () => {
    // claim_lms_provider_run returns this when provider_automation_enabled is false.
    const fetchImpl = vi.fn();
    const operations = { claim: vi.fn().mockResolvedValue({ acquired: false, run_id: "attempt-3", reason: "disabled" }), ingestAndScan: vi.fn(), fail: vi.fn() };
    const result = await runSchedulerPipeline({ source: "scheduler", season: "2026/27", operations, fetchOptions: { fetchImpl } });
    expect(result).toEqual({ status: "skipped", reason: "disabled", runId: "attempt-3" });
    expect(result.reason).not.toBe("already_running");
    expect(fetchImpl).not.toHaveBeenCalled();
    expect(operations.ingestAndScan).not.toHaveBeenCalled();
  });

  it("passes an unrecognised skip reason through without relabelling it", async () => {
    const operations = { claim: vi.fn().mockResolvedValue({ acquired: false, run_id: "attempt-4", reason: "some_future_reason" }), ingestAndScan: vi.fn(), fail: vi.fn() };
    await expect(runSchedulerPipeline({ source: "scheduler", season: "2026/27", operations, fetchOptions: { fetchImpl: vi.fn() } }))
      .resolves.toEqual({ status: "skipped", reason: "some_future_reason", runId: "attempt-4" });
  });

  it("falls back to a neutral reason when the claim supplies none", async () => {
    const operations = { claim: vi.fn().mockResolvedValue({ acquired: false, run_id: "attempt-5" }), ingestAndScan: vi.fn(), fail: vi.fn() };
    const result = await runSchedulerPipeline({ source: "admin", season: "2026/27", operations, fetchOptions: { fetchImpl: vi.fn() } });
    expect(result).toEqual({ status: "skipped", reason: "unavailable", runId: "attempt-5" });
    expect(result.reason).not.toBe("already_running");
  });

  it("keeps display wording out of the scheduler layer", () => {
    const pipeline = readFileSync(new URL("../server/scheduler-pipeline.js", import.meta.url), "utf8");
    expect(pipeline).not.toMatch(/Sync skipped|another provider run|automation is disabled/i);
  });

  it("retries bounded transient failures", async () => {
    const fetchImpl = vi.fn().mockResolvedValueOnce(jsonResponse({}, 503)).mockResolvedValueOnce(jsonResponse([], 503)).mockResolvedValueOnce(jsonResponse({ teams })).mockResolvedValueOnce(jsonResponse(fixtures));
    await expect(fetchFplData({ fetchImpl, retries: 1, retryDelayMs: 0 })).resolves.toEqual({ teams, fixtures });
    expect(fetchImpl).toHaveBeenCalledTimes(4);
  });

  it("keeps LMS sporting rules out of the scheduler layer", () => {
    const source = ["../server/scheduler-pipeline.js", "../supabase/functions/lms-scheduler/index.ts"]
      .map((path) => readFileSync(new URL(path, import.meta.url), "utf8").toLowerCase()).join("\n");
    ["draw eliminates", "postponed auto", "everybody reinstated", "buy-back eligibility", "gw38 fallback"].forEach((rule) => expect(source).not.toContain(rule));
  });
});
