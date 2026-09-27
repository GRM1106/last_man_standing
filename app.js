import { createClient } from "@supabase/supabase-js";
import { DEPLOY_TARGET, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

const registerView = document.querySelector("#register-view");
const signInButton = document.querySelector("#google-sign-in");
const emailForm = document.querySelector("#email-registration");
const signInForm = document.querySelector("#email-sign-in");
const modeButton = document.querySelector("#switch-auth-mode");
const message = document.querySelector("#auth-message");
const configured = (SUPABASE_URL.startsWith("https://") || (DEPLOY_TARGET === "local" && SUPABASE_URL === "http://127.0.0.1:55321")) && !SUPABASE_URL.includes("YOUR_") && !SUPABASE_PUBLISHABLE_KEY.includes("YOUR_");
const supabase = configured ? createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY) : null;

function showRegistration(){document.querySelector("#auth-loading").hidden=true;registerView.hidden=false}
function showDashboard(){window.location.replace("/dashboard.html")}

async function initialise(){
  if(!supabase){showRegistration();message.textContent="Registration is being connected. Please check back soon.";return}
  const {data,error}=await supabase.auth.getSession();
  if(error){showRegistration();message.textContent="We couldn’t check your registration. Please refresh and try again.";return}
  data.session?.user?showDashboard(data.session.user):showRegistration();
  supabase.auth.onAuthStateChange((_event,session)=>session?.user?showDashboard(session.user):showRegistration());
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
  if(data.session)showDashboard(data.user);
  else{emailForm.reset();message.textContent="Account created. Check your email to confirm your address."}
});

signInForm.addEventListener("submit",async(event)=>{
  event.preventDefault();
  if(!supabase){message.textContent="Sign in is being connected. Please check back soon.";return}
  const submitButton=signInForm.querySelector("button[type='submit']");
  const fields=new FormData(signInForm);
  submitButton.disabled=true;message.textContent="Signing you in…";
  const {error}=await supabase.auth.signInWithPassword({email:fields.get("email").trim(),password:fields.get("password")});
  submitButton.disabled=false;
  if(error)message.textContent=error.message;
});

modeButton.addEventListener("click",()=>{
  const showingSignIn=!signInForm.hidden;
  document.querySelector("#nav-sign-in").hidden=!showingSignIn;
  signInForm.hidden=showingSignIn;
  emailForm.hidden=!showingSignIn;
  modeButton.textContent=showingSignIn?"Already registered? Sign in":"Need an account? Register";
  document.querySelector('#auth-title').textContent=showingSignIn?'Claim your place.':'Welcome back.';
  document.querySelector('#auth-eyebrow').textContent=showingSignIn?'GET IN THE GAME':'YOUR NEXT ROUND AWAITS';
  document.querySelector('.divider span').textContent=showingSignIn?'or register with email':'or sign in with email';
  signInButton.querySelector('span').textContent=showingSignIn?'Register with Google':'Sign in with Google';
  document.querySelector('.copy').textContent=showingSignIn?'Create an account to access your player dashboard. Request a place in an available pot, or ask your organiser to assign you.':'Sign in to see your pots, check the next deadline and make your pick.';
  (showingSignIn?emailForm:signInForm).querySelector('input').focus();
  message.textContent="";
});

document.querySelector("#nav-sign-in").addEventListener("click",()=>{if(signInForm.hidden)modeButton.click();});
initialise();
