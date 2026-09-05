import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { defineConfig, loadEnv } from "vite";
import {
  DEPLOYABLE_OUTPUT_DIRECTORY,
  PRODUCTION_PUBLISHABLE_KEY,
  PUBLISHABLE_KEY_PREFIX,
  STAGING_KEY_ENV,
  SUPABASE_URL,
  assertProjectTargetCompatible,
  mergeBuildEnv,
  resolveBuildTarget,
} from "./scripts/lms-deploy-target.mjs";

const root = fileURLToPath(new URL(".", import.meta.url));
const deployableOutDir = resolve(root, DEPLOYABLE_OUTPUT_DIRECTORY);

/**
 * Refuse a deployable build whose target contradicts the linked Vercel project.
 *
 * Scoped to the output directory Vercel actually ships (`dist/`), so `vite build
 * --outDir <temp>` verification builds — which cannot be deployed on their own — still
 * run both targets. `configResolved` is used because that is where the real, resolved
 * output directory is available.
 */
const deployTargetGuard = (target, env) => ({
  name: "lms-deploy-target-guard",
  apply: "build",
  configResolved(config) {
    if (resolve(config.root, config.build.outDir) !== deployableOutDir) return;
    assertProjectTargetCompatible({ target, env, rootDir: root });
  },
});

export default defineConfig(({ mode, command }) => {
  const env = mergeBuildEnv(process.env, loadEnv(mode, process.cwd(), "LMS_"));
  // Only a build can be deployed, so only a build has to name its target on Vercel.
  const target = resolveBuildTarget(env, {
    requireExplicit: command === "build" && Boolean(env.VERCEL),
  });

  const stagingKey = env[STAGING_KEY_ENV];
  const selected =
    target === "staging"
      ? { url: SUPABASE_URL.staging, publishableKey: stagingKey }
      : { url: SUPABASE_URL.production, publishableKey: PRODUCTION_PUBLISHABLE_KEY };

  if (
    target === "staging" &&
    (!selected.publishableKey || !selected.publishableKey.startsWith(PUBLISHABLE_KEY_PREFIX))
  ) {
    throw new Error(
      `A staging build requires ${STAGING_KEY_ENV} with an ${PUBLISHABLE_KEY_PREFIX} value.`,
    );
  }

  return {
    plugins: [deployTargetGuard(target, env)],
    define: {
      __LMS_DEPLOY_TARGET__: JSON.stringify(target),
      __LMS_SUPABASE_URL__: JSON.stringify(selected.url),
      __LMS_SUPABASE_PUBLISHABLE_KEY__: JSON.stringify(selected.publishableKey),
    },
    build: {
      rollupOptions: {
        input: {
          index: "index.html",
          waiting: "waiting.html",
          dashboard: "dashboard.html",
          admin: "admin.html",
        },
      },
    },
  };
});
