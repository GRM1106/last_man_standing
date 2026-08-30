// Safe public browser values only, injected at build time by vite.config.js.
// Never add a database password, service-role key, or scheduler secret.
export const DEPLOY_TARGET = __LMS_DEPLOY_TARGET__;
export const SUPABASE_URL = __LMS_SUPABASE_URL__;
export const SUPABASE_PUBLISHABLE_KEY = __LMS_SUPABASE_PUBLISHABLE_KEY__;
