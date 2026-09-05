import { readFileSync, readdirSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { SUPABASE_REF, VERCEL_CONFIG } from "../scripts/lms-deploy-target.mjs";

describe("deployment security policy", () => {
  const config = JSON.parse(readFileSync(new URL("../vercel.json", import.meta.url), "utf8"));
  const stagingConfig = JSON.parse(readFileSync(new URL("../vercel.staging.json", import.meta.url), "utf8"));
  const headers = Object.fromEntries(config.headers[0].headers.map(({ key, value }) => [key, value]));
  const stagingHeaders = Object.fromEntries(stagingConfig.headers[0].headers.map(({ key, value }) => [key, value]));
  const csp = headers["Content-Security-Policy"];
  const stagingCsp = stagingHeaders["Content-Security-Policy"];

  it("uses the bundled production directory", () => {
    expect(config.buildCommand).toBe("npm run vercel-build:production");
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

  it("keeps staging and production build policies isolated", () => {
    const productionRef = "enzdvsppduyqtpdeseyh";
    const stagingRef = "evhiixndiuwwodsouyhf";
    // Each config's build command is the guarded deployment entry point for its own target.
    expect(config.buildCommand).toBe("npm run vercel-build:production");
    expect(stagingConfig.buildCommand).toBe("npm run vercel-build:staging");
    expect(config.buildCommand).not.toBe(stagingConfig.buildCommand);
    expect(csp).toContain(productionRef);
    expect(csp).not.toContain(stagingRef);
    expect(stagingCsp).toContain(stagingRef);
    expect(stagingCsp).not.toContain(productionRef);
    expect(stagingHeaders["X-LMS-Environment"]).toBe("staging");
  });

  it("keeps these literals in step with the deploy-target guard's single source of truth", () => {
    // If these drift, the guard and this policy test would disagree about which ref and
    // build command belong to which environment.
    expect(SUPABASE_REF.production).toBe("enzdvsppduyqtpdeseyh");
    expect(SUPABASE_REF.staging).toBe("evhiixndiuwwodsouyhf");
    expect(VERCEL_CONFIG.production.buildCommand).toBe(config.buildCommand);
    expect(VERCEL_CONFIG.staging.buildCommand).toBe(stagingConfig.buildCommand);
    expect(VERCEL_CONFIG.production.outputDirectory).toBe(config.outputDirectory);
    expect(VERCEL_CONFIG.staging.outputDirectory).toBe(stagingConfig.outputDirectory);
  });

  it("keeps serverless JavaScript compatible with the ESM package runtime", () => {
    const apiDirectory = new URL("../api/", import.meta.url);
    const serverlessScripts = readdirSync(apiDirectory)
      .filter(file => file.endsWith(".js"))
      .map(file => readFileSync(new URL(file, apiDirectory), "utf8"))
      .join("\n");

    expect(serverlessScripts).not.toMatch(/\bmodule\.exports\b/);
    expect(serverlessScripts).not.toMatch(/\bexports\s*\./);
    expect(serverlessScripts).not.toMatch(/\brequire\s*\(/);
  });
});

describe("rendering sink inventory", () => {
  it("contains only the one approved static markup assignment and no high-risk DOM sinks", () => {
    const scripts = ["admin.js", "dashboard.js", "app.js", "waiting.js", "gameweek-processing.js"]
      .map(file => readFileSync(new URL(`../${file}`, import.meta.url), "utf8"))
      .join("\n");
    const occurrences = scripts.match(/\.innerHTML\s*=/g) || [];
    expect(occurrences).toHaveLength(1);
    expect(scripts.match(/select\.innerHTML\s*=\s*'<option value="">Select registered player<\/option>';/g)).toHaveLength(1);
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
