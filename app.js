import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

const registerView = document.querySelector("#register-view");
const waitingView = document.querySelector("#waiting-view");
const signInButton = document.querySelector("#google-sign-in");
const signOutButton = document.querySelector("#sign-out");
const emailForm = document.querySelector("#email-registration");
const message = document.querySelector("#auth-message");
const greeting = document.querySelector("#player-greeting");
const configured = SUPABASE_URL.startsWith("https://") && !SUPABASE_URL.includes("YOUR_") && !SUPABASE_PUBLISHABLE_KEY.includes("YOUR_");
const supabase = configured ? createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY) : null;

function showRegistration(){registerView.hidden=false;waitingView.hidden=true}
function showWaiting(user){
  const firstName=user?.user_metadata?.full_name?.split(" ")[0];
  greeting.textContent=firstName?`${firstName}, your place has been registered. We’ll open the competition when everything is ready.`:"Your place has been registered. We’ll open the competition when everything is ready.";
  registerView.hidden=true;waitingView.hidden=false;
}

async function initialise(){
  if(!supabase){message.textContent="Registration is being connected. Please check back soon.";return}
  const {data,error}=await supabase.auth.getSession();
  if(error){message.textContent="We couldn’t check your registration. Please refresh and try again.";return}
  data.session?.user?showWaiting(data.session.user):showRegistration();
  supabase.auth.onAuthStateChange((_event,session)=>session?.user?showWaiting(session.user):showRegistration());
}

signInButton.addEventListener("click",async()=>{
  if(!supabase){message.textContent="Registration is being connected. Please check back soon.";return}
  signInButton.disabled=true;message.textContent="Opening Google…";
  const {error}=await supabase.auth.signInWithOAuth({provider:"google",options:{redirectTo:window.location.origin}});
  if(error){signInButton.disabled=false;message.textContent="Google registration didn’t complete. Please try again."}
});

emailForm.addEventListener("submit",async(event)=>{
  event.preventDefault();
  if(!supabase){message.textContent="Registration is being connected. Please check back soon.";return}
  const submitButton=emailForm.querySelector("button[type='submit']");
  const fields=new FormData(emailForm);
  submitButton.disabled=true;message.textContent="Creating your account…";
  const firstName=fields.get("firstName").trim();
  const lastName=fields.get("lastName").trim();
  const {data,error}=await supabase.auth.signUp({
    email:fields.get("email").trim(),password:fields.get("password"),
    options:{data:{first_name:firstName,last_name:lastName,full_name:`${firstName} ${lastName}`,phone:fields.get("phone").trim()||null}}
  });
  submitButton.disabled=false;
  if(error){message.textContent=error.message;return}
  if(data.session)showWaiting(data.user);
  else{emailForm.reset();message.textContent="Account created. Check your email to confirm your address."}
});

signOutButton.addEventListener("click",async()=>{if(supabase)await supabase.auth.signOut()});
initialise();
