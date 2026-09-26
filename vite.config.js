import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { readFileSync } from "node:fs";
import { localBrowserConfig } from "./server/environment.js";
import fplHandler from "./api/fpl.js";
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

export default defineConfig(({ mode, command, isPreview }) => {
  const env = mergeBuildEnv(process.env, loadEnv(mode, process.cwd(), "LMS_"));
  const declared = env.LMS_BUILD_TARGET?.trim().toLowerCase();
  const target = isPreview ? (process.env.LMS_PREVIEW_TARGET || 'local') : (declared || 'local');
  if (command === 'serve' && !isPreview && target !== 'local' && process.env.LMS_ALLOW_HOSTED_DEV !== target) {
    throw new Error('Hosted development requires an explicit environment command. Use npm run dev for local services or npm run dev:staging.');
  }
  if (target !== 'local') resolveBuildTarget({ ...env, LMS_BUILD_TARGET: target });
  if (command === 'build' && env.VERCEL && target === 'local') {
    throw new Error('Vercel requires an explicit staging or production build target.');
  }

  const stagingKey = env[STAGING_KEY_ENV];
  const selected =
    target === "local"
      ? localBrowserConfig(env)
      : target === "staging"
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

  const localHeaders = target === 'local' ? {
        'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' http://127.0.0.1:55321 ws://127.0.0.1:55321 ws://127.0.0.1:5173; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'",
        'X-LMS-Environment': 'local',
      } : {};

  return {
    // Disable Vite's automatic VITE_* exposure: only the three public defines below
    // are allowed into client code, even when a shell contains privileged values.
    envPrefix: [],
    plugins: [
      ...(target === 'local' ? [] : [deployTargetGuard(target, env)]),
      {
        name: 'lms-environment-boundary',
        generateBundle() {
          this.emitFile({ type: 'asset', fileName: 'lms-environment.json', source: JSON.stringify({ target }) });
        },
        configureServer(server) {
          server.middlewares.use('/api/fpl', async (request, response) => {
            response.status = (code) => { response.statusCode = code; return response; };
            response.json = (body) => { response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(body)); return response; };
            await fplHandler(request, response);
          });
        },
        configurePreviewServer(server) {
          let built;
          try { built = JSON.parse(readFileSync(resolve(server.config.root, server.config.build.outDir, 'lms-environment.json'), 'utf8')); } catch { /* fail closed */ }
          if (built?.target !== target) throw new Error('Preview target does not match the built bundle. Run npm run build:local then npm run preview, or use an explicit preview:production/preview:staging command.');
        },
      },
    ],
    server: {
      host: '127.0.0.1', port: 5173, strictPort: true,
      headers: localHeaders,
    },
    preview: { host: '127.0.0.1', port: 4173, strictPort: true, headers: localHeaders },
    define: {
      __LMS_DEPLOY_TARGET__: JSON.stringify(target),
      __LMS_SUPABASE_URL__: JSON.stringify(selected.url),
      __LMS_SUPABASE_PUBLISHABLE_KEY__: JSON.stringify(selected.publishableKey),
    },
    build: {
      outDir: target === 'local' ? 'dist-local' : 'dist',
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
