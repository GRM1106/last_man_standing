import { describe, expect, it, vi } from "vitest";
import { createSchedulerOperations } from "../server/scheduler-operations.js";

const administratorId = "12345678-1234-4234-8234-123456789abc";
const claim = { acquired: true, run_id: "run-1" };
const databaseStub = () => ({ rpc: vi.fn().mockResolvedValue({ data: claim, error: null }) });

describe("scheduler actor adapter", () => {
  it.each([undefined, null])("uses the system claim when actorId is %s", async (actorId) => {
    const database = databaseStub();
    await expect(createSchedulerOperations(database, actorId).claim("scheduler")).resolves.toEqual(claim);
    expect(database.rpc).toHaveBeenCalledExactlyOnceWith("claim_lms_provider_run", { run_source: "scheduler" });
  });

  it.each(["admin", "local_simulation"])("preserves the verified administrator for %s", async (source) => {
    const database = databaseStub();
    await expect(createSchedulerOperations(database, administratorId).claim(source)).resolves.toEqual(claim);
    expect(database.rpc).toHaveBeenCalledExactlyOnceWith("claim_lms_provider_run_for_admin", {
      run_source: source, administrator_id: administratorId,
    });
  });

  it("propagates an administrator claim rejection without falling back to the system actor", async () => {
    const error = new Error("Administrator required");
    const database = { rpc: vi.fn().mockResolvedValue({ data: null, error }) };
    await expect(createSchedulerOperations(database, administratorId).claim("admin")).rejects.toBe(error);
    expect(database.rpc).toHaveBeenCalledExactlyOnceWith("claim_lms_provider_run_for_admin", {
      run_source: "admin", administrator_id: administratorId,
    });
  });

  it("completes the durable run without supplying an actor override", async () => {
    const database = databaseStub();
    const payload = { teams: [{ id: 1 }], fixtures: [{ id: 2 }] };
    await createSchedulerOperations(database, administratorId).ingestAndScan("run-1", "2026/27", payload);
    expect(database.rpc).toHaveBeenCalledExactlyOnceWith("complete_lms_provider_run", {
      run_id: "run-1", selected_season: "2026/27", fpl_teams: payload.teams, fpl_fixtures: payload.fixtures,
    });
  });
});
