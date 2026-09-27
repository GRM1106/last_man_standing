import { createAccountClient } from './account-client.js';

// Both administrator modules share the same authenticated session client.
export const { supabase, accountContext } = createAccountClient();
