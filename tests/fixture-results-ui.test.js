import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";

const adminSource = readFileSync(new URL("../admin.js", import.meta.url), "utf8");

function handlerBody(name) {
  const match = adminSource.match(new RegExp(`async function ${name}\\b([\\s\\S]*?)(?=\\n(?:async )?function |\\n[a-zA-Z].*addEventListener|$)`));
  expect(match, `${name} should exist`).not.toBeNull();
  return match[0];
}

beforeEach(() => {
  const dom = new JSDOM('<!doctype html><div id="fixtures"></div>', { url: "https://example.com/admin" });
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  vi.resetModules();
});

describe("administrator fixture-result renderer", () => {
  it("renders raw and authoritative results separately with inert correction history", async () => {
    const { renderAdminFixtureResults } = await import("../fixture-results-ui.js");
    const container = document.querySelector("#fixtures");
    renderAdminFixtureResults(container, [{
      id: 42,
      gameweek_number: 6,
      kickoff_at: "2031-08-09T15:00:00Z",
      home_team: { name: "Home <img src=x onerror=alert(1)>", short_name: "HOM", emblem_url: "javascript:alert(1)" },
      away_team: { name: "Away", short_name: "AWY", emblem_url: "https://resources.premierleague.com/badge.png" },
      raw: { home_score: 1, away_score: 0, status: "finished" },
      effective: { home_score: 0, away_score: 2, status: "finished", source: "admin_override", override_id: "safe-id" },
      overrides: [{ reason: '<svg onload="alert(1)">', source: "admin_correction" }],
    }], vi.fn());
    expect(container.textContent).toContain("Provider raw");
    expect(container.textContent).toContain("Effective");
    expect(container.textContent).toContain("1 – 0");
    expect(container.textContent).toContain("0 – 2");
    expect(container.querySelector("script,svg")).toBeNull();
    expect(container.querySelector("img")?.hasAttribute("src")).toBe(false);
  });

  it("offers a superseding correction without mutating the supplied fixture", async () => {
    const { renderAdminFixtureResults } = await import("../fixture-results-ui.js");
    const fixture = {
      id: 7, home_team: { name: "Home", short_name: "H" }, away_team: { name: "Away", short_name: "A" },
      raw: { home_score: 1, away_score: 1, status: "finished" },
      effective: { home_score: 2, away_score: 1, status: "finished", source: "admin_override", override_id: "current" },
      overrides: [{}],
    };
    const onCorrect = vi.fn();
    renderAdminFixtureResults(document.querySelector("#fixtures"), [fixture], onCorrect);
    const button = document.querySelector("button");
    expect(button.textContent).toBe("Add superseding correction");
    button.click();
    expect(onCorrect).toHaveBeenCalledWith(fixture);
    expect(fixture.effective.home_score).toBe(2);
  });

  it("keeps fixtures beyond position 30 reachable through filtering", async () => {
    const { filterAdminFixtures, renderAdminFixtureResults } = await import("../fixture-results-ui.js");
    const fixtures = Array.from({ length: 35 }, (_, index) => ({ id: index + 1, gameweek_number: index + 1,
      home_team: { name: `Home ${index + 1}`, short_name: `H${index + 1}` },
      away_team: { name: `Away ${index + 1}`, short_name: `A${index + 1}` },
      raw: { status: "scheduled" }, effective: { status: "scheduled" }, overrides: [] }));
    const filtered = filterAdminFixtures(fixtures, "35", "away 35");
    expect(filtered.map((fixture) => fixture.id)).toEqual([35]);
    renderAdminFixtureResults(document.querySelector("#fixtures"), fixtures, vi.fn());
    expect(document.querySelectorAll(".fixture-result-card")).toHaveLength(35);
  });

  it("maps expected errors and hides unexpected backend details", async () => {
    const { correctionErrorMessage } = await import("../fixture-results-ui.js");
    expect(correctionErrorMessage({ message: "Result changed; preview again" })).toContain("Preview");
    const unexpected = correctionErrorMessage({ message: "violates constraint internal_secret_table" });
    expect(unexpected).toBe("The correction could not be completed. Preview again or try later.");
    expect(unexpected).not.toContain("constraint");
  });

  it("uses a controlled message when the real fixture-results loader receives a backend failure", async () => {
    const { loadAdminFixtureResults } = await import("../fixture-results-ui.js");
    const client = {
      rpc: vi.fn().mockResolvedValue({
        data: null,
        error: { message: "relation private_schema.internal_results does not exist" },
      }),
    };
    const result = await loadAdminFixtureResults(client, "2031/32");
    expect(client.rpc).toHaveBeenCalledWith("get_admin_fixture_results", { selected_season: "2031/32" });
    expect(result).toEqual({ fixtures: [], errorMessage: "Couldn’t load fixture results. Try again." });
    expect(result.errorMessage).not.toContain("private_schema");
    expect(result.errorMessage).not.toContain("relation");
  });

  it("routes the actual fixture loading, preview and confirmation handlers through safe error handling", () => {
    const loading = handlerBody("loadFixtures"),
      preview = handlerBody("previewFixtureCorrection"),
      confirmation = handlerBody("confirmFixtureCorrection");
    expect(loading).toContain("loadAdminFixtureResults");
    expect(loading).not.toContain("error.message");
    expect(preview).toContain("correctionErrorMessage(error)");
    expect(preview).not.toContain("error.message");
    expect(confirmation).toContain("correctionErrorMessage(error)");
    expect(confirmation).not.toContain("error.message");
  });
});
