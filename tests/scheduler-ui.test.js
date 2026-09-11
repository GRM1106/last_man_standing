import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { skipReasonMessage, syncResultMessage } from "../scheduler-ui.js";

const adminSource = readFileSync(new URL("../admin.js", import.meta.url), "utf8");

describe("provider sync wording", () => {
  it("explains an overlap as another run being active", () => {
    const message = syncResultMessage({ status: "skipped", reason: "already_running", runId: "attempt-2" });
    expect(message).toBe("Sync skipped safely because another provider run is active.");
  });

  it("explains the kill switch without claiming another run is active", () => {
    const message = syncResultMessage({ status: "skipped", reason: "disabled", runId: "attempt-3" });
    expect(message).toBe("Sync skipped because scheduled provider automation is disabled.");
    expect(message).not.toMatch(/another provider run/i);
  });

  it("says the scheduled automation is disabled, not that manual sync is", () => {
    // Only source='scheduler' is gated by provider_automation_enabled, so the wording
    // must not imply an administrator's own sync has been switched off.
    const message = skipReasonMessage("disabled");
    expect(message).toMatch(/scheduled provider automation/i);
    expect(message).not.toMatch(/admin|manual|you cannot|not permitted/i);
  });

  it("gives an unrecognised reason neutral wording rather than an overlap claim", () => {
    for (const reason of ["some_future_reason", "unavailable", "", null, undefined]) {
      const message = syncResultMessage({ status: "skipped", reason });
      expect(message).toBe("Sync skipped safely. No football data was changed.");
      expect(message).not.toMatch(/another provider run|disabled/i);
    }
  });

  it("never echoes the raw reason token or any run identifier back to the operator", () => {
    const message = syncResultMessage({
      status: "skipped",
      reason: "internal detail: relation \"x\" does not exist",
      runId: "6b22de13-1eb5-4f75-9d9b-06742eaedc8f",
    });
    expect(message).toBe("Sync skipped safely. No football data was changed.");
    expect(message).not.toMatch(/relation|does not exist|6b22de13/);
  });

  it("reports a completed sync with its ingestion counts", () => {
    expect(syncResultMessage({ status: "succeeded", ingestion: { teams: 20, fixtures: 380 } }))
      .toBe("Football data sync complete: 20 clubs and 380 fixtures updated; automation scan finished.");
  });

  it("tolerates a completed sync with no ingestion detail", () => {
    expect(syncResultMessage({ status: "succeeded" }))
      .toBe("Football data sync complete: 0 clubs and 0 fixtures updated; automation scan finished.");
    expect(syncResultMessage(undefined)).toMatch(/^Football data sync complete: 0 clubs and 0 fixtures/);
  });
});

describe("admin sync handler", () => {
  it("renders the shared mapper instead of its own hardcoded skip wording", () => {
    expect(adminSource).toContain('import { syncResultMessage } from "./scheduler-ui.js"');
    expect(adminSource).toContain("message.textContent = syncResultMessage(data);");
    // The old wording must no longer be reachable for every skip reason.
    expect(adminSource).not.toContain('"Sync skipped safely because another provider run is active."');
  });
});
