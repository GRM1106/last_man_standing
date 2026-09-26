import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

// Both administrator modules share the same authenticated session client.
export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
