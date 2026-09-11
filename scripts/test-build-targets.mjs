// Proves that a production build and a staging build cannot contaminate each other, and
// that the deploy-target guard actually refuses an unsafe deployable build.
//
// The two isolation builds write to a temp directory. That is deliberate: they are
// verification builds, not deployable artifacts, so the project-identity guard — which
// only applies to the deployable output directory — leaves them alone and both targets
// can be built from one checkout.

import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BUILD_TARGETS,
  SUPABASE_REF,
  VERCEL_CONFIG,
  assertConfigMatchesTarget,
  identityTarget,
  readLinkedVercelProject,
} from "./lms-deploy-target.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const scratch = mkdtempSync(join(tmpdir(), "lms-build-targets-"));
const vite = join(root, "node_modules", ".bin", "vite");
const productionRef = SUPABASE_REF.production;
const stagingRef = SUPABASE_REF.staging;
const validationKey = "sb_publishable_staging_build_validation_only";

function listFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? listFiles(path) : [path];
  });
}

function bundleText(directory) {
  return listFiles(directory)
    .filter((path) => /\.(?:html|js|css|json)$/.test(path))
    .map((path) => readFileSync(path, "utf8"))
    .join("\n");
}

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function readPolicy(name) {
  const config = JSON.parse(readFileSync(join(root, name), "utf8"));
  const headers = Object.fromEntries(
    config.headers[0].headers.map(({ key, value }) => [key, value]),
  );
  return { config, headers, csp: headers["Content-Security-Policy"] };
}

try {
  const productionOut = join(scratch, "production");
  const stagingOut = join(scratch, "staging");

  execFileSync(vite, ["build", "--mode", "production", "--outDir", productionOut], {
    cwd: root,
    env: { ...process.env, LMS_BUILD_TARGET: "production" },
    stdio: "pipe",
  });
  execFileSync(vite, ["build", "--mode", "staging", "--outDir", stagingOut], {
    cwd: root,
    env: {
      ...process.env,
      LMS_BUILD_TARGET: "staging",
      LMS_STAGING_SUPABASE_PUBLISHABLE_KEY: validationKey,
    },
    stdio: "pipe",
  });

  const productionBundle = bundleText(productionOut);
  const stagingBundle = bundleText(stagingOut);
  requireCondition(productionBundle.includes(productionRef), "production ref missing from production bundle");
  requireCondition(!productionBundle.includes(stagingRef), "staging ref leaked into production bundle");
  requireCondition(stagingBundle.includes(stagingRef), "staging ref missing from staging bundle");
  requireCondition(!stagingBundle.includes(productionRef), "production ref leaked into staging bundle");
  requireCondition(stagingBundle.includes(validationKey), "staging publishable key was not injected");
  requireCondition(!productionBundle.includes(validationKey), "staging validation key leaked into production bundle");

  const refused = spawnSync(vite, ["build", "--mode", "staging", "--outDir", join(scratch, "refused")], {
    cwd: root,
    env: {
      ...process.env,
      LMS_BUILD_TARGET: "staging",
      LMS_STAGING_SUPABASE_PUBLISHABLE_KEY: "",
    },
    encoding: "utf8",
  });
  requireCondition(refused.status !== 0, "staging build without a publishable key did not refuse");

  const badTarget = spawnSync(vite, ["build", "--outDir", join(scratch, "bad-target")], {
    cwd: root,
    env: { ...process.env, LMS_BUILD_TARGET: "prod" },
    encoding: "utf8",
  });
  requireCondition(badTarget.status !== 0, "an unsupported LMS_BUILD_TARGET did not refuse");
  requireCondition(
    `${badTarget.stdout}${badTarget.stderr}`.includes("unsupported LMS_BUILD_TARGET"),
    "an unsupported LMS_BUILD_TARGET did not explain itself",
  );

  const productionPolicy = readPolicy(VERCEL_CONFIG.production.file);
  const stagingPolicy = readPolicy(VERCEL_CONFIG.staging.file);
  requireCondition(
    productionPolicy.config.buildCommand === VERCEL_CONFIG.production.buildCommand,
    "production build command changed",
  );
  requireCondition(
    stagingPolicy.config.buildCommand === VERCEL_CONFIG.staging.buildCommand,
    "staging build command is wrong",
  );
  requireCondition(productionPolicy.csp.includes(productionRef), "production CSP lacks production ref");
  requireCondition(!productionPolicy.csp.includes(stagingRef), "staging ref leaked into production CSP");
  requireCondition(stagingPolicy.csp.includes(stagingRef), "staging CSP lacks staging ref");
  requireCondition(!stagingPolicy.csp.includes(productionRef), "production ref leaked into staging CSP");
  requireCondition(stagingPolicy.headers["X-LMS-Environment"] === "staging", "staging marker missing");

  // Each config must still describe the target it belongs to, and neither may describe the other.
  assertConfigMatchesTarget("production", productionPolicy.config);
  assertConfigMatchesTarget("staging", stagingPolicy.config);
  for (const target of BUILD_TARGETS) {
    const foreign = BUILD_TARGETS.find((candidate) => candidate !== target);
    let crossAccepted = true;
    try {
      assertConfigMatchesTarget(target, readPolicy(VERCEL_CONFIG[foreign].file).config);
    } catch {
      crossAccepted = false;
    }
    requireCondition(!crossAccepted, `${VERCEL_CONFIG[foreign].file} was accepted as the ${target} policy`);
  }

  console.log("PASS: production and staging bundles/configurations are isolated");
  console.log("PASS: staging build fails closed without its publishable key");
  console.log("PASS: an unsupported build target fails closed");
  console.log("PASS: neither Vercel config is accepted as the other target's policy");

  // End-to-end proof that the guard is wired into the deployable build path. Only
  // possible when this checkout is linked to a project of a known target.
  const linked = readLinkedVercelProject(root);
  const linkedTarget = identityTarget(linked?.projectName) ?? identityTarget(linked?.projectId);
  if (!linkedTarget) {
    console.log("NOTE: no recognised .vercel/project.json link, so the linked-project guard was not exercised");
  } else {
    const wrongTarget = BUILD_TARGETS.find((candidate) => candidate !== linkedTarget);
    const blocked = spawnSync(vite, ["build"], {
      cwd: root,
      env: {
        ...process.env,
        LMS_BUILD_TARGET: wrongTarget,
        LMS_STAGING_SUPABASE_PUBLISHABLE_KEY: validationKey,
      },
      encoding: "utf8",
    });
    const output = `${blocked.stdout}${blocked.stderr}`;
    requireCondition(
      blocked.status !== 0,
      `a ${wrongTarget} build into the deployable directory was allowed on a ${linkedTarget}-linked checkout`,
    );
    requireCondition(output.includes("deployment target mismatch"), "the guard did not explain the mismatch");
    requireCondition(!output.includes("sb_publishable_"), "the guard error exposed a publishable key");
    console.log(
      `PASS: a ${wrongTarget} build into ${VERCEL_CONFIG[linkedTarget].outputDirectory}/ is refused on this ${linkedTarget}-linked checkout`,
    );

    // The deployment entry point itself — what `vercel build`/`vercel deploy` invokes.
    const entryPoint = VERCEL_CONFIG[wrongTarget].buildCommand.replace(/^npm run /, "");
    const deployBlocked = spawnSync("npm", ["run", "--silent", entryPoint], {
      cwd: root,
      env: { ...process.env, LMS_STAGING_SUPABASE_PUBLISHABLE_KEY: validationKey },
      encoding: "utf8",
    });
    const deployOutput = `${deployBlocked.stdout}${deployBlocked.stderr}`;
    requireCondition(
      deployBlocked.status !== 0,
      `${VERCEL_CONFIG[wrongTarget].file}'s build command was allowed on a ${linkedTarget}-linked checkout`,
    );
    requireCondition(
      /deployment target mismatch|could not be proven/.test(deployOutput),
      "the deployment entry point did not explain its refusal",
    );
    requireCondition(!deployOutput.includes(validationKey), "the deployment guard exposed a publishable key");
    console.log(
      `PASS: ${VERCEL_CONFIG[wrongTarget].file}'s build command (${VERCEL_CONFIG[wrongTarget].buildCommand}) is refused on this ${linkedTarget}-linked checkout`,
    );

    // The matching target's gate, run on its own so this harness never writes to the
    // deployable directory. That the Vercel config actually routes through this gate is
    // pinned separately by tests/deploy-target-guard.test.js.
    const entryAllowed = spawnSync(
      process.execPath,
      [join(root, "scripts", "check-deploy-target.mjs"), linkedTarget, "--deployment"],
      { cwd: root, encoding: "utf8" },
    );
    requireCondition(
      entryAllowed.status === 0 && /deployment target proven/.test(entryAllowed.stdout),
      `the ${linkedTarget} deployment gate did not prove its target on a ${linkedTarget}-linked checkout`,
    );
    console.log(`PASS: the ${linkedTarget} deployment gate proves its target with no manual pre-check`);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
