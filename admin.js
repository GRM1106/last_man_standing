import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";
const supabase=createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);
const loading=document.querySelector("#admin-loading"),denied=document.querySelector("#admin-denied"),content=document.querySelector("#admin-content"),playerList=document.querySelector("#player-list"),playerCount=document.querySelector("#player-count"),message=document.querySelector("#admin-message"),signOutButton=document.querySelector("#sign-out");
const playerName=player=>[player.first_name,player.last_name].filter(Boolean).join(" ")||player.display_name||"Unnamed player";
function showDenied(){loading.hidden=true;content.hidden=true;denied.hidden=false}
function renderPlayers(players){
  playerCount.textContent=players.length;playerList.replaceChildren();
  if(!players.length){const empty=document.createElement("p");empty.className="empty-list";empty.textContent="No players have registered yet.";playerList.append(empty);return}
  players.forEach(player=>{
    const row=document.createElement("article");row.className="player-row";
    const details=document.createElement("div");details.className="player-details";
    const name=document.createElement("h2");name.textContent=playerName(player);
    const email=document.createElement("p");email.textContent=player.email;
    const joined=document.createElement("small");joined.textContent=`Joined ${new Date(player.created_at).toLocaleDateString("en-GB",{day:"numeric",month:"short",year:"numeric"})}`;details.append(name,email,joined);
    const controls=document.createElement("div");controls.className="player-controls";
    const status=document.createElement("span");status.className=`status ${player.approved?"approved":"pending"}`;status.textContent=player.approved?"Approved":"Waiting";
    const button=document.createElement("button");button.className=`approval-button ${player.approved?"revoke":"approve"}`;button.type="button";button.textContent=player.approved?"Revoke access":"Approve player";button.addEventListener("click",()=>setApproval(player,!player.approved,button));controls.append(status,button);row.append(details,controls);playerList.append(row);
  });
}
async function loadPlayers(){const {data,error}=await supabase.from("profiles").select("id,email,display_name,first_name,last_name,approved,is_admin,created_at").order("created_at",{ascending:false});if(error){message.textContent="Couldn’t load players. Check that admin_setup.sql has been run.";return}renderPlayers(data)}
async function setApproval(player,newApproved,button){button.disabled=true;message.textContent=`${newApproved?"Approving":"Revoking access for"} ${playerName(player)}…`;const {error}=await supabase.rpc("set_player_approval",{player_id:player.id,new_approved:newApproved});if(error){button.disabled=false;message.textContent=error.message;return}message.textContent=`${playerName(player)} is now ${newApproved?"approved":"waiting for approval"}.`;await loadPlayers()}
async function initialise(){const {data:{session}}=await supabase.auth.getSession();if(!session){window.location.replace("/");return}const {data:profile,error}=await supabase.from("profiles").select("is_admin").eq("id",session.user.id).maybeSingle();if(error||!profile?.is_admin){showDenied();return}loading.hidden=true;content.hidden=false;await loadPlayers()}
signOutButton.addEventListener("click",async()=>{signOutButton.disabled=true;await supabase.auth.signOut();window.location.replace("/")});initialise();
