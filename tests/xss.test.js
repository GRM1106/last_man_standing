import { beforeEach, describe, expect, it } from "vitest";
import { JSDOM } from "jsdom";

const payload = `<img src=x onerror="window.__xssExecuted=true">`;

beforeEach(async () => {
  const dom = new JSDOM("<!doctype html><body></body>", { url: "https://example.test" });
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  window.__xssExecuted = false;
});

describe("safe DOM renderers", () => {
  it.each(["Admin Pots", "Admin Standings"])("renders attacker-controlled names and email as inert text in %s", async () => {
    const { renderIdentity } = await import("../ui.js");
    const target = document.createElement("div");
    renderIdentity(target, payload, `bad'\"&<>@example.test`, "active");
    expect(target.textContent).toContain(payload);
    expect(target.querySelector("img")).toBeNull();
    expect(window.__xssExecuted).toBe(false);
    expect(target.querySelector(".standings-status").textContent).toBe("active");
  });

  it("keeps malformed, long, and Unicode names inside their text node", async () => {
    const { addText } = await import("../ui.js");
    const target = document.createElement("section");
    const value = `</strong><script>window.__xssExecuted=true</script> ${"A".repeat(500)} ⚽ 李`;
    addText(target, "strong", value);
    expect(target.querySelectorAll("strong")).toHaveLength(1);
    expect(target.querySelector("script")).toBeNull();
    expect(target.textContent).toBe(value);
  });

  it.each([
    ["http://resources.premierleague.com/x.png", ""],
    ["https://resources.premierleague.com.attacker.test/x.png", ""],
    ["https://resources.premierleague.com@attacker.test/x.png", ""],
    ["//attacker.test/x.png", ""],
    ["HTTPS://RESOURCES.PREMIERLEAGUE.COM/x.png", "https://resources.premierleague.com/x.png"],
    ["https://resources.premierleague.com./x.png", ""],
    ["https://resources.premierleague.com:444/x.png", ""],
    ["javascript:alert(1)", ""],
    ["data:image/svg+xml,<svg/>", ""],
    ["blob:https://example.test/id", ""],
    ["/images/badge.png", "https://example.test/images/badge.png"],
    ["http://[", ""]
  ])("validates badge URL %s", async (input, expected) => {
    const { safeImageUrl } = await import("../ui.js");
    expect(safeImageUrl(input)).toBe(expected);
  });

  it("omits src when a badge URL is rejected", async () => {
    const { addImage } = await import("../ui.js");
    const target = document.createElement("div");
    addImage(target, "javascript:alert(1)");
    expect(target.querySelector("img").hasAttribute("src")).toBe(false);
    expect(window.__xssExecuted).toBe(false);
  });

  it("exercises the actual Admin Picks identity renderer with database-shaped malicious values", async () => {
    const { renderAdminPickIdentity } = await import("../ui.js");
    const target = document.createElement("div");
    renderAdminPickIdentity(target, { name: payload, email: `${payload}@example.test` });
    expect(target.textContent).toContain(payload);
    expect(target.querySelector("img")).toBeNull();
    expect(target.querySelector("[onerror]")).toBeNull();
    expect(window.__xssExecuted).toBe(false);
  });

  it("exercises the actual player standings identity renderer with malicious values", async () => {
    const { renderPlayerStandingIdentity } = await import("../ui.js");
    const target = document.createElement("td");
    renderPlayerStandingIdentity(target, { name: payload, player_status: "active" });
    expect(target.textContent).toContain(payload);
    expect(target.querySelector("img")).toBeNull();
    expect(target.querySelector("[onerror]")).toBeNull();
    expect(window.__xssExecuted).toBe(false);
  });

  it("renders admin and player standings picks without injected elements", async () => {
    const { renderStandingPick } = await import("../ui.js");
    for (const showSource of [false, true]) {
      const cell = document.createElement("td");
      renderStandingPick(cell, { team_name: payload, short_name: payload, emblem_url: "x' onerror='alert(1)", outcome: "won", selection_source: "random" }, showSource);
      expect(cell.textContent).toContain(payload);
      expect(cell.querySelectorAll("img")).toHaveLength(1);
      expect(cell.querySelector("img").getAttribute("onerror")).toBeNull();
      expect(window.__xssExecuted).toBe(false);
    }
  });
});
