// Single source of truth for "which environment is this build for?".
//
// Every build path (vite.config.js, scripts/check-deploy-target.mjs,
// scripts/test-build-targets.mjs and the Vitest suite) resolves the target and its
// Supabase/Vercel identity through this module, so the mapping exists in exactly one
// place. See DEPLOY_TARGET_GUARD.md for the operator-facing description.
//
// This module never reads or prints a publishable key, and never contacts Supabase
// or Vercel. It only inspects environment variables and, when present, the local
// .vercel/project.json that the Vercel CLI writes on `vercel link`.

import { readFileSync } from "node:fs";
import { join } from "node:path";

export const BUILD_TARGETS = Object.freeze(["production", "staging"]);

export const SUPABASE_REF = Object.freeze({
  production: "enzdvsppduyqtpdeseyh",
  staging: "evhiixndiuwwodsouyhf",
});

export const SUPABASE_URL = Object.freeze({
  production: `https://${SUPABASE_REF.production}.supabase.co`,
  staging: `https://${SUPABASE_REF.staging}.supabase.co`,
});

// Safe public browser value. Never a service-role key or database password.
export const PRODUCTION_PUBLISHABLE_KEY = "sb_publishable_hzT1zV_hfo3O9crCap083A_XDCEMBur";
export const STAGING_KEY_ENV = "LMS_STAGING_SUPABASE_PUBLISHABLE_KEY";
export const PUBLISHABLE_KEY_PREFIX = "sb_publishable_";

// The deployment policy that belongs to each target. Tests assert the real files match.
//
// `outputDirectory` matters to the guard as well as to Vercel: a build writing to this
// directory is the artifact a deployment ships, so that is the build the project-identity
// check applies to. A build sent elsewhere (the isolation harness writes to a temp
// directory) is a verification build and cannot be deployed by itself.
export const DEPLOYABLE_OUTPUT_DIRECTORY = "dist";

// `buildCommand` is the deployment entry point: it runs only when Vercel builds this
// project, locally under `vercel build` or remotely under `vercel deploy`. Because
// reaching it *means* a deployment is happening, it can demand positive proof of the
// target rather than merely the absence of a contradiction. `npm run build` stays the
// plain local/CI build and is deliberately not that entry point.
export const VERCEL_CONFIG = Object.freeze({
  production: Object.freeze({
    file: "vercel.json",
    buildCommand: "npm run vercel-build:production",
    localBuildCommand: "npm run build",
    outputDirectory: DEPLOYABLE_OUTPUT_DIRECTORY,
  }),
  staging: Object.freeze({
    file: "vercel.staging.json",
    buildCommand: "npm run vercel-build:staging",
    localBuildCommand: "npm run build:staging",
    outputDirectory: DEPLOYABLE_OUTPUT_DIRECTORY,
  }),
});

// Known Vercel project identities, by target. Values are compared case-insensitively
// against a project id (prj_...), a project name, or a project production hostname.
//
// A target with a NON-EMPTY list is CLOSED: only a listed project may build it.
// A target with an EMPTY list is OPEN: any project may build it, unless that project
// is claimed by another target.
//
export const VERCEL_PROJECT_IDENTITIES = Object.freeze({
  production: Object.freeze([
    "prj_RwQmKxhshLDHXKOYfSuuqXiOOzyq",
    "last-man-standing",
    "www.grm-lms.co.uk",
  ]),
  staging: Object.freeze([
    "prj_7e9MI9tYTLrSlSrdmaXWu2oIs6ZV",
    "last-man-standing-staging",
    "last-man-standing-staging.vercel.app",
  ]),
});

export class DeployTargetError extends Error {
  constructor(message) {
    super(message);
    this.name = "DeployTargetError";
  }
}

const token = (value) => (typeof value === "string" ? value.trim().toLowerCase() : "");

const hostname = (value) => token(value).replace(/^https?:\/\//, "").split("/")[0];

const safeCommand = (target) =>
  `npm run ${VERCEL_CONFIG[target].localBuildCommand.replace(/^npm run /, "")}` +
  `   (to deploy: npm run deploy:${target})`;

/**
 * Merge Vite's loadEnv result under process.env, preserving the historic precedence:
 * a real environment variable wins, an LMS_ value from a .env file is the fallback.
 */
export function mergeBuildEnv(processEnv = process.env, dotEnv = {}) {
  const merged = { ...dotEnv, ...processEnv };
  for (const key of Object.keys(dotEnv)) {
    if (!token(merged[key]) && token(dotEnv[key])) merged[key] = dotEnv[key];
  }
  return merged;
}

/**
 * Resolve the requested build target.
 *
 * Local invocations keep the historic default of `production` so `npm run dev`,
 * `vite build` and `npm run preview` continue to work unchanged. A build running on
 * Vercel (VERCEL=1) is a deployment path, so there the target must be explicit.
 *
 * `requireExplicit` lets a caller narrow that to builds only, so a test or dev-server
 * run that happens inside a Vercel build is not broken by the stricter rule.
 */
export function resolveBuildTarget(env = process.env, { requireExplicit } = {}) {
  const declared = token(env.LMS_BUILD_TARGET);
  const mustBeExplicit = requireExplicit ?? Boolean(token(env.VERCEL));

  if (!declared) {
    if (mustBeExplicit) {
      throw new DeployTargetError(
        [
          "Refusing to build: no LMS_BUILD_TARGET was set for a Vercel build.",
          "",
          "  Why this is unsafe : on Vercel there is no safe default. Silently assuming",
          "                       'production' could embed the production Supabase project",
          "                       into a deployment of the staging project.",
          "",
          "  Safe options:",
          `    - production : buildCommand ${VERCEL_CONFIG.production.buildCommand}`,
          `    - staging    : buildCommand ${VERCEL_CONFIG.staging.buildCommand}`,
        ].join("\n"),
      );
    }
    return "production";
  }

  if (!BUILD_TARGETS.includes(declared)) {
    throw new DeployTargetError(
      [
        `Refusing to build: unsupported LMS_BUILD_TARGET "${declared}".`,
        "",
        `  Supported targets : ${BUILD_TARGETS.join(", ")}`,
        "",
        "  Safe options:",
        `    - ${safeCommand("production")}`,
        `    - ${safeCommand("staging")}`,
      ].join("\n"),
    );
  }

  return declared;
}

/**
 * Read the Vercel project this checkout is linked to.
 *
 * Returns null when .vercel/project.json is absent, unreadable or malformed. The file
 * is gitignored and does not exist in CI or a fresh clone, so its absence is normal
 * and must never block a build. This function never writes to the file.
 */
export function readLinkedVercelProject(rootDir) {
  try {
    const parsed = JSON.parse(readFileSync(join(rootDir, ".vercel", "project.json"), "utf8"));
    if (!parsed || typeof parsed !== "object") return null;
    const projectId = typeof parsed.projectId === "string" ? parsed.projectId : null;
    const projectName = typeof parsed.projectName === "string" ? parsed.projectName : null;
    return projectId || projectName ? { projectId, projectName } : null;
  } catch {
    return null;
  }
}

/**
 * Reject a Vercel deployment policy that does not describe the target it belongs to:
 * wrong build command, wrong output directory, or a CSP naming the other environment's
 * Supabase project. Throws DeployTargetError; returns the policy when it is consistent.
 */
export function assertConfigMatchesTarget(target, config) {
  const policy = VERCEL_CONFIG[target];
  if (!policy) throw new DeployTargetError(`Unsupported target "${target}".`);

  const unsafe = (lines) =>
    new DeployTargetError(
      [`Refusing to deploy: ${policy.file} does not describe the ${target} target.`, "", ...lines].join("\n"),
    );

  if (config?.buildCommand !== policy.buildCommand) {
    throw unsafe([
      `  Expected buildCommand : ${policy.buildCommand}`,
      `  Found buildCommand    : ${config?.buildCommand}`,
      `  Why this is unsafe    : this policy would ship a bundle built for another environment.`,
    ]);
  }

  if (config?.outputDirectory !== policy.outputDirectory) {
    throw unsafe([
      `  Expected outputDirectory : ${policy.outputDirectory}`,
      `  Found outputDirectory    : ${config?.outputDirectory}`,
      `  Why this is unsafe       : the build guard only inspects the deployable output`,
      `                             directory, so changing it would bypass the check.`,
    ]);
  }

  const csp =
    config?.headers?.[0]?.headers?.find((header) => header.key === "Content-Security-Policy")?.value ?? "";

  if (!csp.includes(SUPABASE_REF[target])) {
    throw unsafe([`  Why this is unsafe : its CSP does not allow the ${target} Supabase project.`]);
  }

  for (const other of BUILD_TARGETS.filter((candidate) => candidate !== target)) {
    if (csp.includes(SUPABASE_REF[other])) {
      throw unsafe([`  Why this is unsafe : its CSP allows the ${other} Supabase project.`]);
    }
  }

  return policy;
}

/** The target a project identity is known to belong to, or null when unrecognised. */
export function identityTarget(value, identities = VERCEL_PROJECT_IDENTITIES) {
  const candidate = token(value);
  if (!candidate) return null;
  for (const target of BUILD_TARGETS) {
    if ((identities[target] ?? []).some((known) => token(known) === candidate)) return target;
  }
  return null;
}

/**
 * Collect every project identity we can observe, without contacting Vercel.
 *
 * Local link  : .vercel/project.json, written by `vercel link`. Covers `vercel build`
 *               and `vercel deploy --prebuilt`, which build on this machine.
 * Vercel build: VERCEL_PROJECT_ID and VERCEL_PROJECT_PRODUCTION_URL, both documented as
 *               available at build time. Covers a plain `vercel deploy`, which builds
 *               remotely where .vercel/project.json does not exist.
 *
 * VERCEL_URL is deliberately ignored: it carries a per-deployment suffix, so matching it
 * would need prefix logic that can confuse one project for another.
 */
export function collectProjectEvidence({ env = process.env, rootDir, linkedProject } = {}) {
  const evidence = [];
  const linked =
    linkedProject !== undefined ? linkedProject : rootDir ? readLinkedVercelProject(rootDir) : null;

  // Name first: it is the identity an operator recognises in an error message.
  if (linked?.projectName) {
    evidence.push({ source: "linked Vercel project name (.vercel/project.json)", value: linked.projectName });
  }
  if (linked?.projectId) {
    evidence.push({ source: "linked Vercel project id (.vercel/project.json)", value: linked.projectId });
  }
  if (token(env.VERCEL_PROJECT_ID)) {
    evidence.push({ source: "VERCEL_PROJECT_ID (Vercel build environment)", value: env.VERCEL_PROJECT_ID });
  }
  if (hostname(env.VERCEL_PROJECT_PRODUCTION_URL)) {
    evidence.push({
      source: "VERCEL_PROJECT_PRODUCTION_URL (Vercel build environment)",
      value: hostname(env.VERCEL_PROJECT_PRODUCTION_URL),
    });
  }
  return evidence;
}

function mismatch({ target, source, value, detected }) {
  const owner = detected ? `is the ${detected} Vercel project` : `is not a known ${target} Vercel project`;
  const reason =
    target === "production"
      ? "a production build embeds the production Supabase project and production\n" +
        "                         CSP, so deploying it to this project would point that project at\n" +
        "                         production data."
      : "a staging build embeds the staging Supabase project and staging CSP, so\n" +
        "                         deploying it to this project would point that project at staging data.";

  return [
    "Refusing to build: deployment target mismatch.",
    "",
    `  Requested target     : ${target}`,
    `  Conflicting evidence : ${source}`,
    `                         "${value}" ${owner}`,
    `  Why this is unsafe   : ${reason}`,
    "",
    "  Safe options:",
    detected ? `    - build for the linked project : ${safeCommand(detected)}` : null,
    `    - or link this checkout to the intended ${target} Vercel project first`,
    "",
    "  If this project is legitimately a new deployment target, add its id or name to",
    "  VERCEL_PROJECT_IDENTITIES in scripts/lms-deploy-target.mjs.",
  ]
    .filter((line) => line !== null)
    .join("\n");
}

const VERCEL_CONTEXT_KEYS = Object.freeze([
  "VERCEL",
  "VERCEL_ENV",
  "VERCEL_TARGET_ENV",
  "VERCEL_PROJECT_ID",
  "VERCEL_PROJECT_PRODUCTION_URL",
]);

function describeVercelContext(env) {
  return VERCEL_CONTEXT_KEYS.map((key) => `${key}=${token(env[key]) ? "present" : "missing"}`).join(", ");
}

function unproven(target, identities, env) {
  const recorded = identitiesFor(target, identities);
  return [
    `Refusing to deploy: the ${target} deployment target could not be proven.`,
    "",
    `  Requested target   : ${target}`,
    "  Evidence found     : none",
    `  Vercel context     : ${describeVercelContext(env)}`,
    "  Why this is unsafe : a deployment must positively identify the Vercel project it",
    "                       is going to. Without proof, this bundle could be published to",
    "                       a project belonging to another environment.",
    "",
    `  A ${target} deployment needs one of these:`,
    `    - this checkout linked to the ${target} Vercel project, with that project's id or`,
    "      name listed in VERCEL_PROJECT_IDENTITIES (scripts/lms-deploy-target.mjs); or",
    '    - a Vercel build with "Enable access to System Environment Variables" switched on,',
    "      so VERCEL_PROJECT_ID is available, and that id listed there.",
    "",
    recorded.length === 0
      ? `  No ${target} Vercel project is recorded in this repository.`
      : `  Recorded ${target} projects: ${recorded.join(", ")}`,
  ].join("\n");
}

const identitiesFor = (target, identities = VERCEL_PROJECT_IDENTITIES) => identities[target] ?? [];

/**
 * Reject a build whose target contradicts the Vercel project it is being built for.
 *
 * Default (`requireProof: false`) is the ordinary build rule: fail closed on a
 * contradiction, stay out of the way when there is no evidence, so a fresh clone or CI
 * checkout with no .vercel/project.json still builds normally.
 *
 * `requireProof: true` is the deployment rule: absence of evidence is itself a failure,
 * because a deployment must positively identify where it is going. Only the Vercel
 * buildCommand entry points and the repository deploy scripts use it.
 *
 * Returns the evidence considered, for reporting.
 */
export function assertProjectTargetCompatible({
  target,
  env = process.env,
  rootDir,
  linkedProject,
  identities = VERCEL_PROJECT_IDENTITIES,
  requireProof = false,
} = {}) {
  const evidence = collectProjectEvidence({ env, rootDir, linkedProject });
  const closed = identitiesFor(target, identities).length > 0;
  let proven = false;

  for (const item of evidence) {
    const detected = identityTarget(item.value, identities);
    if (detected === target) {
      proven = true;
      continue;
    }
    // Claimed by a different target, or unrecognised while this target is a closed set.
    if (detected !== null || closed) {
      throw new DeployTargetError(mismatch({ target, source: item.source, value: item.value, detected }));
    }
  }

  if (requireProof && !proven) throw new DeployTargetError(unproven(target, identities, env));

  return evidence.map((item) => ({ ...item, detected: identityTarget(item.value, identities) }));
}

/** Resolve and fully validate a build target in one call. Throws DeployTargetError. */
export function resolveVerifiedBuildTarget({ env = process.env, rootDir, linkedProject } = {}) {
  const target = resolveBuildTarget(env);
  const evidence = assertProjectTargetCompatible({ target, env, rootDir, linkedProject });
  return { target, evidence };
}
