import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import {
  BUILD_TARGETS,
  DEPLOYABLE_OUTPUT_DIRECTORY,
  DeployTargetError,
  SUPABASE_REF,
  SUPABASE_URL,
  VERCEL_CONFIG,
  VERCEL_PROJECT_IDENTITIES,
  assertConfigMatchesTarget,
  assertProjectTargetCompatible,
  identityTarget,
  mergeBuildEnv,
  readLinkedVercelProject,
  resolveBuildTarget,
} from "../scripts/lms-deploy-target.mjs";

// Scratch checkouts only. The real .vercel/project.json is never written or modified.
const scratches = [];
function checkout(projectJson) {
  const dir = mkdtempSync(join(tmpdir(), "lms-deploy-guard-"));
  scratches.push(dir);
  if (projectJson !== undefined) {
    mkdirSync(join(dir, ".vercel"), { recursive: true });
    writeFileSync(
      join(dir, ".vercel", "project.json"),
      typeof projectJson === "string" ? projectJson : JSON.stringify(projectJson),
    );
  }
  return dir;
}
afterAll(() => scratches.forEach((dir) => rmSync(dir, { recursive: true, force: true })));

const STAGING_PROJECT = { projectId: "prj_7e9MI9tYTLrSlSrdmaXWu2oIs6ZV", projectName: "last-man-standing-staging" };
const OTHER_PROJECT = { projectId: "prj_someOtherProjectIdentifier01", projectName: "last-man-standing" };

// A registry in which BOTH targets are closed, so the production-linked case is representable.
const CLOSED_REGISTRY = {
  production: ["prj_someOtherProjectIdentifier01", "last-man-standing"],
  staging: VERCEL_PROJECT_IDENTITIES.staging,
};

const realConfig = (target) =>
  JSON.parse(readFileSync(new URL(`../${VERCEL_CONFIG[target].file}`, import.meta.url), "utf8"));

describe("build target resolution", () => {
  it("accepts each supported target", () => {
    for (const target of BUILD_TARGETS) {
      expect(resolveBuildTarget({ LMS_BUILD_TARGET: target })).toBe(target);
    }
  });

  it("keeps the historic production default for local invocations", () => {
    expect(resolveBuildTarget({})).toBe("production");
  });

  it("refuses an unsupported target", () => {
    expect(() => resolveBuildTarget({ LMS_BUILD_TARGET: "prod" })).toThrow(DeployTargetError);
    expect(() => resolveBuildTarget({ LMS_BUILD_TARGET: "PRODUCTION " })).not.toThrow();
    expect(() => resolveBuildTarget({ LMS_BUILD_TARGET: "staging-2" })).toThrow(/unsupported LMS_BUILD_TARGET/i);
  });

  it("refuses to infer a target on a Vercel build", () => {
    expect(() => resolveBuildTarget({ VERCEL: "1" })).toThrow(/no LMS_BUILD_TARGET was set/i);
    expect(resolveBuildTarget({ VERCEL: "1", LMS_BUILD_TARGET: "staging" })).toBe("staging");
  });

  it("applies the stricter Vercel rule only where the caller asks for it", () => {
    // A test or dev-server run inside a Vercel build is not a deployment path.
    expect(resolveBuildTarget({ VERCEL: "1" }, { requireExplicit: false })).toBe("production");
    expect(() => resolveBuildTarget({}, { requireExplicit: true })).toThrow(/no LMS_BUILD_TARGET was set/i);
  });

  it("prefers a real environment variable over a .env fallback", () => {
    expect(mergeBuildEnv({ LMS_BUILD_TARGET: "staging" }, { LMS_BUILD_TARGET: "production" }).LMS_BUILD_TARGET)
      .toBe("staging");
    expect(mergeBuildEnv({}, { LMS_BUILD_TARGET: "staging" }).LMS_BUILD_TARGET).toBe("staging");
    expect(mergeBuildEnv({ LMS_BUILD_TARGET: "" }, { LMS_BUILD_TARGET: "staging" }).LMS_BUILD_TARGET)
      .toBe("staging");
  });
});

describe("Supabase target isolation", () => {
  it("maps each target to its own project ref and never the other", () => {
    expect(SUPABASE_URL.production).toContain(SUPABASE_REF.production);
    expect(SUPABASE_URL.production).not.toContain(SUPABASE_REF.staging);
    expect(SUPABASE_URL.staging).toContain(SUPABASE_REF.staging);
    expect(SUPABASE_URL.staging).not.toContain(SUPABASE_REF.production);
    expect(SUPABASE_REF.production).not.toBe(SUPABASE_REF.staging);
  });
});

describe("Vercel config policy", () => {
  it("accepts the real production config for the production target", () => {
    expect(() => assertConfigMatchesTarget("production", realConfig("production"))).not.toThrow();
  });

  it("accepts the real staging config for the staging target", () => {
    expect(() => assertConfigMatchesTarget("staging", realConfig("staging"))).not.toThrow();
  });

  it("rejects the production config used as a staging policy", () => {
    expect(() => assertConfigMatchesTarget("staging", realConfig("production"))).toThrow(DeployTargetError);
  });

  it("rejects the staging config used as a production policy", () => {
    expect(() => assertConfigMatchesTarget("production", realConfig("staging"))).toThrow(DeployTargetError);
  });

  it("rejects a staging policy whose CSP names the production Supabase project", () => {
    const config = realConfig("staging");
    config.headers[0].headers[0].value += ` https://${SUPABASE_REF.production}.supabase.co`;
    expect(() => assertConfigMatchesTarget("staging", config)).toThrow(/allows the production Supabase project/i);
  });

  it("rejects a production policy whose CSP names the staging Supabase project", () => {
    const config = realConfig("production");
    config.headers[0].headers[0].value += ` https://${SUPABASE_REF.staging}.supabase.co`;
    expect(() => assertConfigMatchesTarget("production", config)).toThrow(/allows the staging Supabase project/i);
  });

  it("rejects a policy whose build command targets the other environment", () => {
    const config = { ...realConfig("staging"), buildCommand: VERCEL_CONFIG.production.buildCommand };
    expect(() => assertConfigMatchesTarget("staging", config)).toThrow(/Found buildCommand/);
  });

  it("rejects a moved output directory, which would bypass the build guard", () => {
    const config = { ...realConfig("production"), outputDirectory: "build" };
    expect(() => assertConfigMatchesTarget("production", config)).toThrow(/outputDirectory/);
    expect(realConfig("production").outputDirectory).toBe(DEPLOYABLE_OUTPUT_DIRECTORY);
    expect(realConfig("staging").outputDirectory).toBe(DEPLOYABLE_OUTPUT_DIRECTORY);
  });
});

describe("deployment entry points", () => {
  const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));

  it("routes each Vercel config through a guarded npm script that exists", () => {
    for (const target of BUILD_TARGETS) {
      const command = realConfig(target).buildCommand;
      expect(command).toBe(VERCEL_CONFIG[target].buildCommand);
      const scriptName = command.replace(/^npm run /, "");
      expect(pkg.scripts).toHaveProperty(scriptName);
      // The entry point must assert in deployment mode before it builds anything.
      expect(pkg.scripts[scriptName]).toContain("check-deploy-target.mjs");
      expect(pkg.scripts[scriptName]).toContain(target);
      expect(pkg.scripts[scriptName]).toContain("--deployment");
      expect(pkg.scripts[scriptName]).toContain(VERCEL_CONFIG[target].localBuildCommand);
    }
  });

  it("gives each target a deploy script that validates before invoking Vercel", () => {
    for (const target of BUILD_TARGETS) {
      const deploy = pkg.scripts[`deploy:${target}`];
      expect(deploy).toBeDefined();
      // Validation must come first, so an unsafe combination never reaches the CLI.
      expect(deploy.indexOf("check-deploy-target.mjs")).toBeLessThan(deploy.indexOf("vercel "));
      expect(deploy).toContain("--deployment");
    }
    // Staging must name its own config, or it would deploy the production policy.
    expect(pkg.scripts["deploy:staging"]).toContain(`--local-config ${VERCEL_CONFIG.staging.file}`);
    expect(pkg.scripts["deploy:production"]).not.toContain(VERCEL_CONFIG.staging.file);
  });

  it("keeps the plain build scripts free of the deployment gate", () => {
    // Requirement: a fresh clone, CI and scratch builds must not need a Vercel link.
    expect(pkg.scripts.build).not.toContain("check-deploy-target");
    expect(pkg.scripts["build:staging"]).not.toContain("check-deploy-target");
  });
});

describe("linked Vercel project metadata", () => {
  it("reads a linked project when present", () => {
    expect(readLinkedVercelProject(checkout(STAGING_PROJECT))).toEqual(STAGING_PROJECT);
  });

  it("returns null when absent, malformed or empty rather than throwing", () => {
    expect(readLinkedVercelProject(checkout())).toBeNull();
    expect(readLinkedVercelProject(checkout("{not json"))).toBeNull();
    expect(readLinkedVercelProject(checkout({}))).toBeNull();
    expect(readLinkedVercelProject(join(tmpdir(), "lms-does-not-exist-at-all"))).toBeNull();
  });

  it("recognises the staging project by id, name and production hostname", () => {
    expect(identityTarget(STAGING_PROJECT.projectId)).toBe("staging");
    expect(identityTarget(STAGING_PROJECT.projectName)).toBe("staging");
    expect(identityTarget("last-man-standing-staging.vercel.app")).toBe("staging");
    expect(identityTarget("prj_unknown")).toBeNull();
  });
});

describe("project/target compatibility guard", () => {
  it("rejects a production build from a staging-linked checkout", () => {
    const rootDir = checkout(STAGING_PROJECT);
    expect(() => assertProjectTargetCompatible({ target: "production", env: {}, rootDir }))
      .toThrow(/deployment target mismatch/i);
    try {
      assertProjectTargetCompatible({ target: "production", env: {}, rootDir });
    } catch (error) {
      expect(error.message).toContain("Requested target     : production");
      expect(error.message).toContain("last-man-standing-staging");
      expect(error.message).toContain("is the staging Vercel project");
      expect(error.message).toContain("npm run build:staging");
      expect(error.message).not.toMatch(/sb_publishable_/);
    }
  });

  it("allows a staging build from a staging-linked checkout", () => {
    const rootDir = checkout(STAGING_PROJECT);
    expect(() => assertProjectTargetCompatible({ target: "staging", env: {}, rootDir })).not.toThrow();
  });

  it("rejects a staging build from a checkout linked to any non-staging project", () => {
    const rootDir = checkout(OTHER_PROJECT);
    expect(() => assertProjectTargetCompatible({ target: "staging", env: {}, rootDir }))
      .toThrow(/deployment target mismatch/i);
  });

  it("rejects a staging build from a production-linked checkout when production is registered", () => {
    const rootDir = checkout(OTHER_PROJECT);
    expect(() =>
      assertProjectTargetCompatible({ target: "staging", env: {}, rootDir, identities: CLOSED_REGISTRY }),
    ).toThrow(/is the production Vercel project/i);
  });

  it("rejects a production build from a production-linked checkout only when it is not registered", () => {
    const rootDir = checkout(OTHER_PROJECT);
    expect(() =>
      assertProjectTargetCompatible({ target: "production", env: {}, rootDir, identities: CLOSED_REGISTRY }),
    ).not.toThrow();
  });

  it("rejects a production build running on the staging Vercel project", () => {
    expect(() =>
      assertProjectTargetCompatible({
        target: "production",
        env: { VERCEL: "1", VERCEL_PROJECT_ID: STAGING_PROJECT.projectId },
        linkedProject: null,
      }),
    ).toThrow(/VERCEL_PROJECT_ID/);
  });

  it("rejects a production build whose Vercel production URL is the staging project", () => {
    expect(() =>
      assertProjectTargetCompatible({
        target: "production",
        env: { VERCEL: "1", VERCEL_PROJECT_PRODUCTION_URL: "https://last-man-standing-staging.vercel.app/" },
        linkedProject: null,
      }),
    ).toThrow(/VERCEL_PROJECT_PRODUCTION_URL/);
  });

  it("allows a production build with no project evidence at all", () => {
    const rootDir = checkout();
    expect(() => assertProjectTargetCompatible({ target: "production", env: {}, rootDir })).not.toThrow();
    expect(assertProjectTargetCompatible({ target: "production", env: {}, rootDir })).toEqual([]);
  });

  it("allows a staging build with no project evidence, so a fresh clone and CI still build", () => {
    const rootDir = checkout();
    expect(() => assertProjectTargetCompatible({ target: "staging", env: {}, rootDir })).not.toThrow();
    expect(() => assertProjectTargetCompatible({ target: "staging", env: {}, linkedProject: null })).not.toThrow();
  });

  it("proves a staging deployment from the staging link, with no manual pre-check", () => {
    const rootDir = checkout(STAGING_PROJECT);
    expect(() =>
      assertProjectTargetCompatible({ target: "staging", env: {}, rootDir, requireProof: true }),
    ).not.toThrow();
  });

  it("rejects a production deployment from the staging link", () => {
    const rootDir = checkout(STAGING_PROJECT);
    expect(() =>
      assertProjectTargetCompatible({ target: "production", env: {}, rootDir, requireProof: true }),
    ).toThrow(/deployment target mismatch/i);
  });

  it("rejects a deployment it cannot positively prove, even with no contradiction", () => {
    // This is the plain `vercel deploy` remote build: no .vercel/project.json was
    // uploaded, and system environment variables may be switched off.
    const rootDir = checkout();
    expect(() =>
      assertProjectTargetCompatible({ target: "production", env: {}, rootDir, requireProof: true }),
    ).toThrow(/could not be proven/i);
    expect(() =>
      assertProjectTargetCompatible({ target: "staging", env: {}, linkedProject: null, requireProof: true }),
    ).toThrow(/could not be proven/i);
  });

  it("names registering the production project as the prerequisite", () => {
    try {
      assertProjectTargetCompatible({ target: "production", env: {}, linkedProject: null, requireProof: true });
    } catch (error) {
      expect(error.message).toContain("No production Vercel project is recorded");
      expect(error.message).toContain("VERCEL_PROJECT_ID");
      expect(error.message).not.toMatch(/sb_publishable_/);
    }
    expect.assertions(3);
  });

  it("proves a deployment from VERCEL_PROJECT_ID when the project is registered", () => {
    expect(() =>
      assertProjectTargetCompatible({
        target: "staging",
        env: { VERCEL: "1", VERCEL_PROJECT_ID: STAGING_PROJECT.projectId },
        linkedProject: null,
        requireProof: true,
      }),
    ).not.toThrow();
    expect(() =>
      assertProjectTargetCompatible({
        target: "production",
        env: { VERCEL: "1", VERCEL_PROJECT_ID: OTHER_PROJECT.projectId },
        linkedProject: null,
        requireProof: true,
        identities: CLOSED_REGISTRY,
      }),
    ).not.toThrow();
  });

  it("never lets an unknown project prove the staging target", () => {
    for (const value of ["prj_unknown", "last-man-standing", "last-man-standing-staging-preview", ""]) {
      expect(() =>
        assertProjectTargetCompatible({
          target: "staging",
          env: { VERCEL: "1", VERCEL_PROJECT_ID: value },
          linkedProject: null,
          requireProof: true,
        }),
      ).toThrow(DeployTargetError);
    }
  });

  it("ignores VERCEL_URL, whose per-deployment suffix cannot be matched safely", () => {
    expect(() =>
      assertProjectTargetCompatible({
        target: "production",
        env: { VERCEL: "1", VERCEL_URL: "last-man-standing-staging-a1b2c3.vercel.app" },
        linkedProject: null,
      }),
    ).not.toThrow();
  });
});
