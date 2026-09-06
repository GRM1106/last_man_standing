import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, describe, expect, it } from "vitest";
import {
  EDGE_FUNCTIONS,
  MANAGED_SECRETS,
  REMOTE_OPERATIONS,
  SUPABASE_ENVIRONMENTS,
  SUPABASE_REF,
  SupabaseTargetError,
  assertEdgeFunction,
  assertManagedSecret,
  assertRemoteOperationAllowed,
  environmentForRef,
  readLinkedProject,
  resolveRemoteTarget,
} from "../scripts/lms-supabase-target.mjs";
import { SUPABASE_REF as DEPLOY_TARGET_REF } from "../scripts/lms-deploy-target.mjs";

const STAGING = SUPABASE_REF.staging;
const PRODUCTION = SUPABASE_REF.production;
const UNKNOWN = "zzzzzzzzzzzzzzzzzzzz";

// Scratch checkouts only. The real supabase/.temp/linked-project.json is never written.
const scratches = [];
function checkout(link) {
  const dir = mkdtempSync(join(tmpdir(), "lms-supabase-guard-"));
  scratches.push(dir);
  if (link !== undefined) {
    mkdirSync(join(dir, "supabase", ".temp"), { recursive: true });
    writeFileSync(
      join(dir, "supabase", ".temp", "linked-project.json"),
      typeof link === "string" ? link : JSON.stringify(link),
    );
  }
  return dir;
}
afterAll(() => scratches.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

const wrapperSource = readFileSync(new URL("../scripts/supabase-remote.mjs", import.meta.url), "utf8");
const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));

// fileURLToPath, not .pathname: this repository's path contains spaces.
const repoRoot = fileURLToPath(new URL("../", import.meta.url));
function runWrapper(args) {
  try {
    const stdout = execFileSync(process.execPath, [join(repoRoot, "scripts/supabase-remote.mjs"), ...args], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { status: 0, output: stdout };
  } catch (error) {
    return { status: error.status ?? 1, output: `${error.stdout ?? ""}${error.stderr ?? ""}` };
  }
}

describe("environment model", () => {
  it("keeps one project-ref mapping shared with the Vercel guard", () => {
    expect(SUPABASE_REF).toBe(DEPLOY_TARGET_REF);
    expect(SUPABASE_REF.staging).toBe("evhiixndiuwwodsouyhf");
    expect(SUPABASE_REF.production).not.toBe(SUPABASE_REF.staging);
  });

  it("identifies each registered ref and rejects anything else", () => {
    expect(environmentForRef(STAGING)).toBe("staging");
    expect(environmentForRef(PRODUCTION)).toBe("production");
    for (const value of [UNKNOWN, "", null, undefined, "  "]) expect(environmentForRef(value)).toBeNull();
  });

  it("permits staging operations and blocks production ones", () => {
    expect(REMOTE_OPERATIONS.staging.allowed).toBe(true);
    expect(REMOTE_OPERATIONS.production.allowed).toBe(false);
    expect(SUPABASE_ENVIRONMENTS).toEqual(["production", "staging"]);
  });
});

describe("remote operation policy", () => {
  it("accepts staging", () => {
    expect(() => assertRemoteOperationAllowed("staging")).not.toThrow();
  });

  it("refuses production and names registration as the prerequisite", () => {
    expect(() => assertRemoteOperationAllowed("production")).toThrow(SupabaseTargetError);
    try {
      assertRemoteOperationAllowed("production");
    } catch (error) {
      expect(error.message).toMatch(/not permitted from this repository/i);
      expect(error.message).toMatch(/prerequisite/i);
      expect(error.message).toMatch(/REMOTE_OPERATIONS/);
    }
    expect.assertions(4);
  });

  it("refuses an environment it does not model", () => {
    for (const name of ["preview", "prod", "", undefined]) {
      expect(() => assertRemoteOperationAllowed(name)).toThrow(SupabaseTargetError);
    }
  });
});

describe("linked project evidence", () => {
  it("reads a link when present", () => {
    expect(readLinkedProject(checkout({ ref: STAGING, name: "last-man-standing-staging" })))
      .toEqual({ ref: STAGING, name: "last-man-standing-staging" });
  });

  it("returns null for absent, malformed or refless links instead of throwing", () => {
    expect(readLinkedProject(checkout())).toBeNull();
    expect(readLinkedProject(checkout("{not json"))).toBeNull();
    expect(readLinkedProject(checkout({ name: "no ref here" }))).toBeNull();
    expect(readLinkedProject(join(tmpdir(), "lms-does-not-exist-at-all"))).toBeNull();
  });
});

describe("target proof", () => {
  it("passes when the link matches the requested staging project", () => {
    const rootDir = checkout({ ref: STAGING, name: "last-man-standing-staging" });
    const target = resolveRemoteTarget({ environment: "staging", rootDir });
    expect(target.ref).toBe(STAGING);
    expect(target.evidence.map((item) => item.source)).toContain(
      "linked project (supabase/.temp/linked-project.json)",
    );
  });

  it("passes with no link at all, because the explicit ref is positive proof", () => {
    const target = resolveRemoteTarget({ environment: "staging", rootDir: checkout() });
    expect(target.ref).toBe(STAGING);
    expect(JSON.stringify(target.evidence)).toMatch(/none present/);
  });

  it("refuses staging when the link points at production", () => {
    const rootDir = checkout({ ref: PRODUCTION, name: "last-man-standing" });
    expect(() => resolveRemoteTarget({ environment: "staging", rootDir })).toThrow(/contradicts/i);
    try {
      resolveRemoteTarget({ environment: "staging", rootDir });
    } catch (error) {
      expect(error.message).toMatch(/is the production project/);
      expect(error.message).toMatch(/unlink/);
    }
    expect.assertions(3);
  });

  it("refuses staging when the link points at an unrecognised project", () => {
    const rootDir = checkout({ ref: UNKNOWN, name: "someone-elses-project" });
    expect(() => resolveRemoteTarget({ environment: "staging", rootDir })).toThrow(SupabaseTargetError);
    try {
      resolveRemoteTarget({ environment: "staging", rootDir });
    } catch (error) {
      expect(error.message).toMatch(/is not a project this repository recognises/);
    }
    expect.assertions(2);
  });

  it("refuses production before the link is even considered", () => {
    const rootDir = checkout({ ref: PRODUCTION, name: "last-man-standing" });
    // Even with a *matching* production link, policy refuses first.
    expect(() => resolveRemoteTarget({ environment: "production", rootDir }))
      .toThrow(/not permitted from this repository/i);
  });

  it("refuses an environment with no registered ref", () => {
    expect(() => resolveRemoteTarget({ environment: "staging", linkedProject: null, refs: { staging: "" } }))
      .toThrow(SupabaseTargetError);
  });
});

describe("operation allowlists", () => {
  it("manages only lms-scheduler", () => {
    expect(EDGE_FUNCTIONS).toEqual(["lms-scheduler"]);
    expect(assertEdgeFunction("lms-scheduler")).toBe("lms-scheduler");
    for (const name of ["other-function", "", "lms-scheduler-copy"]) {
      expect(() => assertEdgeFunction(name)).toThrow(SupabaseTargetError);
    }
  });

  it("manages only the LMS_ secrets and never the platform-injected ones", () => {
    for (const name of MANAGED_SECRETS) expect(assertManagedSecret(name)).toBe(name);
    for (const name of ["SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_URL", "SUPABASE_ANON_KEY", "OTHER"]) {
      expect(() => assertManagedSecret(name)).toThrow(SupabaseTargetError);
    }
    expect(MANAGED_SECRETS).not.toContain("SUPABASE_SERVICE_ROLE_KEY");
  });
});

describe("guarded wrapper", () => {
  it("proves the target before it builds any Supabase command", () => {
    // resolveRemoteTarget must be called before cliArgs is assembled.
    expect(wrapperSource.indexOf("resolveRemoteTarget(")).toBeLessThan(wrapperSource.indexOf("cliArgs ="));
    expect(wrapperSource.indexOf("resolveRemoteTarget(")).toBeLessThan(wrapperSource.indexOf("execFileSync(\"npx\""));
  });

  it("passes an explicit --project-ref on every remote command", () => {
    const scratch = mkdtempSync(join(tmpdir(), "lms-supabase-ref-"));
    scratches.push(scratch);
    const file = join(scratch, "values.env");
    writeFileSync(file, "LMS_SEASON=2026/27\n");
    for (const op of ["deploy-function", "delete-function", "set-secrets", "unset-secrets"]) {
      const { status, output } = runWrapper([op, "staging", "--dry-run", "--env-file", file, "--secret", "LMS_SEASON"]);
      expect(status, `${op} should validate`).toBe(0);
      expect(output, `${op} should target explicitly`).toContain(`--project-ref ${SUPABASE_REF.staging}`);
    }
  });

  it("targets exactly lms-scheduler for deploy and delete", () => {
    expect(runWrapper(["deploy-function", "staging", "--dry-run"]).output)
      .toContain(`functions deploy lms-scheduler --project-ref ${STAGING}`);
    expect(runWrapper(["delete-function", "staging", "--dry-run"]).output)
      .toContain(`functions delete lms-scheduler --project-ref ${STAGING}`);
  });

  it("refuses production from the wrapper", () => {
    const { status, output } = runWrapper(["check", "production"]);
    expect(status).toBe(1);
    expect(output).toMatch(/not permitted from this repository/i);
  });

  it("refuses unknown operations, environments and options", () => {
    expect(runWrapper(["deploy-function", "preview", "--dry-run"]).status).toBe(1);
    expect(runWrapper(["drop-everything", "staging", "--dry-run"]).status).toBe(1);
    expect(runWrapper(["check", "staging", "--force"]).status).toBe(1);
    expect(runWrapper(["check", "staging", "--project-ref", UNKNOWN]).status).toBe(1);
  });

  it("requires an env file for set-secrets and never accepts inline values", () => {
    const { status, output } = runWrapper(["set-secrets", "staging", "--dry-run"]);
    expect(status).toBe(1);
    expect(output).toMatch(/needs --env-file/);
    expect(wrapperSource).not.toMatch(/NAME=VALUE|--secret\s+\w+=/);
  });

  it("never prints a secret value and holds none in source or package.json", () => {
    const scratch = mkdtempSync(join(tmpdir(), "lms-supabase-secrets-"));
    scratches.push(scratch);
    const file = join(scratch, "values.env");
    writeFileSync(file, "LMS_SCHEDULER_SECRET=super-secret-fixture-value\nLMS_SEASON=2026/27\n");
    const { status, output } = runWrapper(["set-secrets", "staging", "--env-file", file, "--dry-run"]);
    expect(status).toBe(0);
    expect(output).not.toContain("super-secret-fixture-value");
    expect(output).toContain("--env-file");
    // Nothing that looks like a value assignment is stored in the repo's own files.
    for (const source of [wrapperSource, JSON.stringify(pkg.scripts)]) {
      expect(source).not.toMatch(/LMS_SCHEDULER_SECRET\s*=\s*\S/);
    }
  });

  it("exposes narrow named scripts rather than a passthrough CLI", () => {
    const names = Object.keys(pkg.scripts).filter((name) => name.startsWith("supabase:"));
    expect(names).toEqual(expect.arrayContaining([
      "supabase:check:staging",
      "supabase:deploy:staging",
      "supabase:delete:staging",
      "supabase:secrets:set:staging",
      "supabase:secrets:unset:staging",
    ]));
    // Every guarded script routes through the wrapper, and none exposes production mutation.
    for (const name of names) {
      expect(pkg.scripts[name]).toContain("scripts/supabase-remote.mjs");
      if (name !== "supabase:check:production") expect(pkg.scripts[name]).toContain("staging");
    }
    expect(Object.values(pkg.scripts).join("\n")).not.toMatch(/supabase (functions deploy|functions delete|secrets set|db push)/);
  });
});

describe("local-only development", () => {
  it("keeps local Supabase commands out of the guard entirely", () => {
    // start / stop / db reset --local / functions serve must not be wrapped, so they
    // never require a registered remote project or a link.
    const scripts = JSON.stringify(pkg.scripts);
    for (const local of ["supabase start", "supabase stop", "db reset", "functions serve"]) {
      expect(scripts).not.toContain(local);
    }
    expect(wrapperSource).not.toMatch(/\bstart\b.*supabase|functions serve|db reset/);
  });

  it("never writes to the linked-project file", () => {
    const guardSource = readFileSync(new URL("../scripts/lms-supabase-target.mjs", import.meta.url), "utf8");
    for (const source of [guardSource, wrapperSource]) {
      expect(source).not.toMatch(/writeFileSync|unlinkSync|rmSync|supabase link|supabase unlink"/);
    }
  });
});
