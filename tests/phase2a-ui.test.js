import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("Phase 2A player eligibility UI", () => {
  const dashboard = readFileSync(new URL("../dashboard.js", import.meta.url), "utf8");
  const waiting = readFileSync(new URL("../waiting.js", import.meta.url), "utf8");
  const admin = readFileSync(new URL("../admin.js", import.meta.url), "utf8");

  it("does not gate picks or the empty dashboard on payment or approval", () => {
    expect(dashboard).not.toContain('selection.payment_status !== "paid"');
    expect(dashboard).not.toContain("!data?.approved");
    expect(waiting).not.toContain("dashboard?.approved");
  });

  it("offers all registered players to the administrator", () => {
    expect(admin).toContain("Select registered player");
    expect(admin).not.toContain("player.approved && !memberIds.has");
  });
});
