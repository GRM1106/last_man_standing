import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

const supabase=createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);
const potSelect=document.querySelector("#pick-pot");
const gameweekSelect=document.querySelector("#pick-gameweek");
const reviewButton=document.querySelector("#review-processing");
const resetButton=document.querySelector("#reset-test-processing");
const dialog=document.querySelector("#processing-dialog");
const title=document.querySelector("#processing-title");
const summary=document.querySelector("#processing-summary");
const warning=document.querySelector("#processing-warning");
const confirmButton=document.querySelector("#confirm-processing");
const message=document.querySelector("#admin-message");
let preview=null;

function renderPreview(data){
  preview=data;
  title.textContent=`${data.pot_name} · GW${data.gameweek_number}`;
  summary.replaceChildren();
  [["Survive",data.winners+data.postponed],["Eliminated",data.losers],["Players",data.player_count]].forEach(([label,value])=>{
    const item=document.createElement("div");
    item.innerHTML=`<span>${label}</span><strong>${value}</strong>`;
    summary.append(item);
  });
  warning.className=`processing-warning${data.ready?" ready":""}`;
  warning.textContent=data.ready
    ? `${data.test_mode?"TEST RUN — ":""}All checks passed. Confirming will lock these outcomes and update player statuses.`
    : data.problems.join(" ");
  confirmButton.disabled=!data.ready||data.processed;
  confirmButton.textContent=data.processed?"Already processed":data.test_mode?"Process test results":"Confirm and process";
  resetButton.hidden=!(data.test_mode&&data.processed);
}

async function getPreview(){
  if(!potSelect.value||!gameweekSelect.value)return;
  reviewButton.disabled=true;
  message.textContent="Checking gameweek results…";
  const {data,error}=await supabase.rpc("process_pot_gameweek",{selected_pot_id:potSelect.value,selected_gameweek:Number(gameweekSelect.value),apply_changes:false});
  reviewButton.disabled=false;
  if(error){message.textContent=`Couldn’t review results: ${error.message}. Run 13 — Gameweek result processing in Supabase.`;return}
  message.textContent="";
  renderPreview(data);
  dialog.showModal();
}

async function applyProcessing(event){
  event.preventDefault();
  if(!preview?.ready)return;
  confirmButton.disabled=true;
  confirmButton.textContent="Processing…";
  const {data,error}=await supabase.rpc("process_pot_gameweek",{selected_pot_id:potSelect.value,selected_gameweek:Number(gameweekSelect.value),apply_changes:true});
  if(error){warning.className="processing-warning";warning.textContent=error.message;confirmButton.disabled=false;confirmButton.textContent="Try again";return}
  dialog.close();
  message.textContent=`GW${data.gameweek_number} processed: ${data.winners+data.postponed} survived and ${data.losers} eliminated.`;
  document.querySelector(".admin-tab[data-view='picks']")?.click();
}

async function resetTestProcessing(){
  resetButton.disabled=true;
  const {error}=await supabase.rpc("reset_test_gameweek",{selected_pot_id:potSelect.value,selected_gameweek:Number(gameweekSelect.value)});
  resetButton.disabled=false;
  if(error){message.textContent=error.message;return}
  message.textContent=`GW${gameweekSelect.value} test processing reset.`;
  document.querySelector(".admin-tab[data-view='picks']")?.click();
}

reviewButton.addEventListener("click",getPreview);
confirmButton.addEventListener("click",applyProcessing);
resetButton.addEventListener("click",resetTestProcessing);
