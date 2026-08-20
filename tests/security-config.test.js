import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("deployment security policy", () => {
  const config = JSON.parse(readFileSync(new URL("../vercel.json", import.meta.url), "utf8"));
  const headers = Object.fromEntries(config.headers[0].headers.map(({ key, value }) => [key, value]));
  const csp = headers["Content-Security-Policy"];

  it("uses the bundled production directory", () => {
    expect(config.buildCommand).toBe("npm run build");
    expect(config.outputDirectory).toBe("dist");
  });

  it("has a restrictive CSP with only required remote origins", () => {
    for (const directive of ["default-src", "script-src", "style-src", "connect-src", "img-src", "font-src", "object-src", "base-uri", "form-action", "frame-ancestors"]) {
      expect(csp).toContain(`${directive} `);
    }
    expect(csp).not.toContain("unsafe-eval");
    expect(csp).not.toContain("unsafe-inline");
    expect(csp).not.toContain("*");
    expect(csp).toContain("https://enzdvsppduyqtpdeseyh.supabase.co");
    expect(csp).toContain("wss://enzdvsppduyqtpdeseyh.supabase.co");
    expect(csp).toContain("https://resources.premierleague.com");
  });

  it("sets the related browser hardening headers", () => {
    expect(headers["X-Content-Type-Options"]).toBe("nosniff");
    expect(headers["Referrer-Policy"]).toBe("strict-origin-when-cross-origin");
    expect(headers["Permissions-Policy"]).toContain("camera=()");
  });
});

describe("rendering sink inventory", () => {
  it("contains only the one approved static markup assignment and no high-risk DOM sinks", () => {
    const scripts = ["admin.js", "dashboard.js", "app.js", "waiting.js", "gameweek-processing.js"]
      .map(file => readFileSync(new URL(`../${file}`, import.meta.url), "utf8"))
      .join("\n");
    const occurrences = scripts.match(/\.innerHTML\s*=/g) || [];
    expect(occurrences).toHaveLength(1);
    expect(scripts.match(/select\.innerHTML\s*=\s*'<option value="">Select approved player<\/option>';/g)).toHaveLength(1);
    expect(scripts).not.toMatch(/innerHTML\s*=\s*`/);
    expect(scripts).not.toMatch(/\.outerHTML\s*=/);
    expect(scripts).not.toMatch(/\.insertAdjacentHTML\s*\(/);
    expect(scripts).not.toMatch(/document\.write\s*\(/);
    expect(scripts).not.toMatch(/\.srcdoc\s*=|setAttribute\s*\(\s*["']srcdoc["']/i);
    expect(scripts).not.toMatch(/new\s+DOMParser\s*\(/);
    expect(scripts).not.toMatch(/setAttribute\s*\(\s*["']on[a-z]+["']/i);
    expect(scripts).not.toMatch(/\.on[a-z]+\s*=\s*["'`]/i);
    expect(scripts).not.toMatch(/\.style\.cssText\s*=/);
  });
});
