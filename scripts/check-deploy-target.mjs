#!/usr/bin/env node
// Pre-deployment safety check.
//
//   node scripts/check-deploy-target.mjs production
//   node scripts/check-deploy-target.mjs staging
//   node scripts/check-deploy-target.mjs                        # uses LMS_BUILD_TARGET
//   node scripts/check-deploy-target.mjs staging --deployment   # deployment rule
//
// Without --deployment this applies the build rule: reject a contradiction, allow a
// checkout with no Vercel link at all.
//
// With --deployment it applies the deployment rule: the target must be positively proven
// by a linked project or by VERCEL_PROJECT_ID. Absence of evidence is itself a failure,
// because a deployment must identify where it is going. The Vercel buildCommand entry
// points (`vercel-build:*`) and the `deploy:*` scripts run in this mode, so the check is
// part of deploying rather than a separate step to remember.
//
// Exits 0 when the combination is safe, 1 when it is not.
//
// Read-only: it inspects environment variables, .vercel/project.json and the two Vercel
// config files. It never deploys, never writes, and never prints a publishable key.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BUILD_TARGETS,
  DeployTargetError,
  VERCEL_CONFIG,
  assertConfigMatchesTarget,
  assertProjectTargetCompatible,
  readLinkedVercelProject,
  resolveBuildTarget,
} from "./lms-deploy-target.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));

function fail(message) {
  console.error(`\n${message}\n`);
  process.exit(1);
}

const args = process.argv.slice(2);
const requireProof = args.includes("--deployment");
const requested = args.find((arg) => !arg.startsWith("--"));
const unknownFlag = args.find((arg) => arg.startsWith("--") && arg !== "--deployment");

if (unknownFlag !== undefined || (requested !== undefined && !BUILD_TARGETS.includes(requested))) {
  fail(
    [
      unknownFlag !== undefined
        ? `Refusing to check: unsupported option "${unknownFlag}".`
        : `Refusing to check: unsupported target "${requested}".`,
      "",
      `  Supported targets : ${BUILD_TARGETS.join(", ")}`,
      "",
      "  Usage: node scripts/check-deploy-target.mjs [production|staging] [--deployment]",
    ].join("\n"),
  );
}

let target;
try {
  target = requested ?? resolveBuildTarget(process.env);
} catch (error) {
  fail(error instanceof DeployTargetError ? error.message : String(error));
}

const policy = VERCEL_CONFIG[target];

// The config file that belongs to this target must still describe this target.
let config;
try {
  config = JSON.parse(readFileSync(join(root, policy.file), "utf8"));
} catch {
  fail(`Refusing to check: ${policy.file} is missing or is not valid JSON.`);
}

try {
  assertConfigMatchesTarget(target, config);
} catch (error) {
  fail(error instanceof DeployTargetError ? error.message : String(error));
}

let evidence;
try {
  evidence = assertProjectTargetCompatible({ target, env: process.env, rootDir: root, requireProof });
} catch (error) {
  fail(error instanceof DeployTargetError ? error.message : String(error));
}

const linked = readLinkedVercelProject(root);
const mode = requireProof ? "deployment" : "build";
console.log(`PASS: ${target} target is compatible with ${policy.file} and the Supabase ${target} project`);
console.log(
  linked
    ? `PASS: linked Vercel project "${linked.projectName ?? linked.projectId}" accepts a ${target} ${mode}`
    : "NOTE: no .vercel/project.json in this checkout, so no linked-project check was possible",
);
if (requireProof) {
  const proof = evidence.filter((item) => item.detected === target).map((item) => item.source);
  console.log(`PASS: ${target} deployment target proven by ${proof.join(", ")}`);
} else if (!evidence.length) {
  console.log("NOTE: no Vercel project evidence available; the guard cannot prove the target here");
}
console.log(`Deploy with: npm run deploy:${target}`);
