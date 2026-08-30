import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const scratch = mkdtempSync(join(tmpdir(), "lms-build-targets-"));
const vite = join(root, "node_modules", ".bin", "vite");
const productionRef = "enzdvsppduyqtpdeseyh";
const stagingRef = "evhiixndiuwwodsouyhf";
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

  const productionPolicy = readPolicy("vercel.json");
  const stagingPolicy = readPolicy("vercel.staging.json");
  requireCondition(productionPolicy.config.buildCommand === "npm run build", "production build command changed");
  requireCondition(stagingPolicy.config.buildCommand === "npm run build:staging", "staging build command is wrong");
  requireCondition(productionPolicy.csp.includes(productionRef), "production CSP lacks production ref");
  requireCondition(!productionPolicy.csp.includes(stagingRef), "staging ref leaked into production CSP");
  requireCondition(stagingPolicy.csp.includes(stagingRef), "staging CSP lacks staging ref");
  requireCondition(!stagingPolicy.csp.includes(productionRef), "production ref leaked into staging CSP");
  requireCondition(stagingPolicy.headers["X-LMS-Environment"] === "staging", "staging marker missing");

  console.log("PASS: production and staging bundles/configurations are isolated");
  console.log("PASS: staging build fails closed without its publishable key");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
