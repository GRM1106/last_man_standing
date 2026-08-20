import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
const greeting = document.querySelector("#player-greeting");
const signOutButton = document.querySelector("#sign-out");
const brandLink = document.querySelector("#waiting-brand");

async function initialise(){
  const {data,error}=await supabase.auth.getSession();
  if(error||!data.session){window.location.replace("/");return}
  const firstName=data.session.user?.user_metadata?.full_name?.split(" ")[0];
  if(firstName)greeting.textContent=`${firstName}, your place has been registered. We’ll open the competition when everything is ready.`;
}

signOutButton.addEventListener("click",async()=>{
  signOutButton.disabled=true;
  await supabase.auth.signOut();
  window.location.replace("/");
});

brandLink.addEventListener("click",event=>event.preventDefault());

initialise();
