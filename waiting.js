import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
const greeting = document.querySelector("#player-greeting");
const signOutButton = document.querySelector("#sign-out");
const brandLink = document.querySelector("#waiting-brand");
const adminLink = document.querySelector("#admin-link");

function showPersonalGreeting(firstName,storageKey){
  if(!firstName)return;
  localStorage.setItem(storageKey,firstName);
  greeting.textContent=`${firstName}, your place has been registered. We’ll open the competition when everything is ready.`;
}

async function initialise(){
  const {data,error}=await supabase.auth.getSession();
  if(error||!data.session){window.location.replace("/");return}
  const user=data.session.user;
  const firstNameStorageKey=`lms-player-first-name:${user.id}`;
  let firstName=user?.user_metadata?.first_name||user?.user_metadata?.full_name?.split(" ")[0];
  showPersonalGreeting(firstName||localStorage.getItem(firstNameStorageKey),firstNameStorageKey);
  if(!firstName){
    const {data:profile}=await supabase.from("profiles").select("first_name,is_admin").eq("id",user.id).maybeSingle();
    firstName=profile?.first_name;
    adminLink.hidden=!profile?.is_admin;
  }else{
    const {data:profile}=await supabase.from("profiles").select("is_admin").eq("id",user.id).maybeSingle();
    adminLink.hidden=!profile?.is_admin;
  }
  showPersonalGreeting(firstName,firstNameStorageKey);
}

signOutButton.addEventListener("click",async()=>{
  signOutButton.disabled=true;
  const {data}=await supabase.auth.getSession();
  await supabase.auth.signOut();
  if(data.session?.user?.id)localStorage.removeItem(`lms-player-first-name:${data.session.user.id}`);
  window.location.replace("/");
});

brandLink.addEventListener("click",event=>event.preventDefault());

initialise();
