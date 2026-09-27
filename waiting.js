import { watchMaintenance } from './maintenance.js';
import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

// Preserve old bookmarks without retaining the retired registration holding page.
const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
const maintenance = watchMaintenance(supabase);
async function initialise() {
  const { data, error } = await supabase.auth.getSession();
  if (error) {
    document.querySelector("#account-message").textContent = "We couldn’t check your session. Please sign in again.";
    return;
  }
  window.location.replace(data.session ? "/dashboard.html" : "/");
}
maintenance.ready.then(initialise);
