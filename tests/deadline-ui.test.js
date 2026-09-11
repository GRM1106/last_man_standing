import { beforeEach, describe, expect, it } from "vitest";
import { JSDOM } from "jsdom";

beforeEach(() => {
  const dom = new JSDOM(`<!doctype html><body>
    <section class="selection-panel">
      <div class="selection-deadline"><strong>Pick deadline</strong><span data-deadline="2026-08-23T12:30:00Z"></span></div>
      <button class="pick-team">Team one</button><button class="pick-team">Team two</button>
    </section>
  </body>`);
  globalThis.document = dom.window.document;
});

describe("pick deadline UI", () => {
  it("keeps controls available before the deadline", async () => {
    const { updatePickDeadlineStates } = await import("../deadline-ui.js");
    updatePickDeadlineStates(document, new Date("2026-08-23T12:29:59Z"));
    expect([...document.querySelectorAll(".pick-team")].every(button => !button.disabled)).toBe(true);
    expect(document.querySelector(".selection-deadline").classList.contains("passed")).toBe(false);
  });

  it("closes the UI and disables every rendered pick button at expiry", async () => {
    const { updatePickDeadlineStates } = await import("../deadline-ui.js");
    updatePickDeadlineStates(document, new Date("2026-08-23T12:30:00Z"));
    expect([...document.querySelectorAll(".pick-team")].every(button => button.disabled)).toBe(true);
    expect(document.querySelector(".selection-deadline").classList.contains("passed")).toBe(true);
    expect(document.querySelector(".selection-deadline strong").textContent).toBe("Picks closed");
    expect(document.querySelector("[data-deadline]").textContent).toBe("Picks closed");
  });
});
