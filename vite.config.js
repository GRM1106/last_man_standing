import { defineConfig, loadEnv } from "vite";

const PRODUCTION = Object.freeze({
  url: "https://enzdvsppduyqtpdeseyh.supabase.co",
  publishableKey: "sb_publishable_hzT1zV_hfo3O9crCap083A_XDCEMBur",
});

const STAGING_URL = "https://evhiixndiuwwodsouyhf.supabase.co";

export default defineConfig(({ mode }) => {
  const environment = loadEnv(mode, process.cwd(), "LMS_");
  const target = process.env.LMS_BUILD_TARGET || environment.LMS_BUILD_TARGET || "production";

  if (!new Set(["production", "staging"]).has(target)) {
    throw new Error(`Unsupported LMS_BUILD_TARGET: ${target}`);
  }

  const stagingKey =
    process.env.LMS_STAGING_SUPABASE_PUBLISHABLE_KEY ||
    environment.LMS_STAGING_SUPABASE_PUBLISHABLE_KEY;
  const selected =
    target === "staging"
      ? { url: STAGING_URL, publishableKey: stagingKey }
      : PRODUCTION;

  if (
    target === "staging" &&
    (!selected.publishableKey || !selected.publishableKey.startsWith("sb_publishable_"))
  ) {
    throw new Error(
      "A staging build requires LMS_STAGING_SUPABASE_PUBLISHABLE_KEY with an sb_publishable_ value.",
    );
  }

  return {
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
