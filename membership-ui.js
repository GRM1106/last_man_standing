import { addText } from './ui.js';
const generations = new WeakMap();
const openers = new WeakMap();
const statusLabel = value => value ? value.replaceAll("_", " ").replace(/^./, letter => letter.toUpperCase()) : "—";
const money = pence => new Intl.NumberFormat('en-GB', { style:'currency', currency:'GBP' }).format(pence / 100);
const button = (parent, text) => { const b=addText(parent,'button',text,'nav-button'); b.type='button'; return b; };
async function rpc(client, name, args) { const result=await client.rpc(name,args); if(result.error) throw new Error(result.error.message); return result.data; }
function action(parent, text, run, reload, feedback) {
  const b=button(parent,text);
  b.addEventListener('click',async()=>{ if(b.disabled)return; b.disabled=true; feedback.textContent='Saving…';
    try { await run(); await reload('Saved.'); } catch(error) { feedback.textContent=error.message; b.disabled=false; }
  }); return b;
}
function requestControls(parent, request, client, reload, feedback) {
  for(const [label,accept] of [['Accept request',true],['Decline request',false]]) action(parent,label,()=>rpc(client,'decide_pot_membership',{
    selected_pot_id:request.pot_id,selected_player_id:request.player_id,expected_version:request.version,accept_request:accept,
  }),reload,feedback);
}
export async function renderPlayerMemberships(target, player, client, success='') {
  if (target.hidden) openers.set(target, document.activeElement);
  const generation=(generations.get(target)||0)+1; generations.set(target,generation);
  target.hidden=false; target.replaceChildren();
  const heading=addText(target,'h2',`${player.name} — pot memberships`);
  heading.tabIndex=-1; heading.focus();
  button(target,'Close player details').addEventListener('click',()=>{ generations.set(target,generation+1);target.hidden=true;const opener=openers.get(target);if(opener?.isConnected)opener.focus(); });
  addText(target,'p',`${player.email} · ${player.is_admin?'Administrator':'Registered account'}`);
  const feedback=addText(target,'p',success||'Loading memberships…','admin-message'); feedback.setAttribute('role','status');
  const reload=text=>generations.get(target)===generation ? renderPlayerMemberships(target,player,client,text) : undefined;
  button(target,'Refresh player details').addEventListener('click',()=>reload(''));
  let data;
  try { data=await rpc(client,'get_admin_player_memberships',{selected_player_id:player.id}); }
  catch(error) { if(generations.get(target)===generation)feedback.textContent=error.message; return; }
  if(generations.get(target)!==generation)return;
  feedback.textContent=success;
  for(const m of data.memberships) {
    const row=document.createElement('article'); row.className='membership-card';
    addText(row,'h3',m.name); addText(row,'p',`${m.season} · ${statusLabel(m.pot_status)} · ${statusLabel(m.player_status)}`);
    addText(row,'p',`Buy-back: ${statusLabel(m.buy_back_status)} · Payment: ${statusLabel(m.buy_back_payment_status)}`);
    const label=document.createElement('label'); label.textContent='Entry payment';
    const select=document.createElement('select'); select.setAttribute('aria-label',`Entry payment for ${m.name}`);
    for(const [value,text] of [['unpaid','Not paid'],['claimed','Player says paid'],['paid','Paid']])select.add(new Option(text,value));
    select.value=m.payment_status; label.append(select); row.append(label);
    action(row,'Save entry payment',()=>rpc(client,'set_pot_player_payment',{selected_pot_id:m.pot_id,selected_player_id:player.id,new_payment_status:select.value}),reload,feedback);
    if(m.buy_back_status==='requested')action(row,`Confirm ${money(m.buy_back_fee_pence)} buy-back payment`,()=>rpc(client,'set_buy_back_decision',{selected_pot_id:m.pot_id,selected_player_id:player.id,approved:true}),reload,feedback);
    target.append(row);
  }
  if(!data.memberships.length)addText(target,'p','This player does not belong to a pot yet.');
  addText(target,'h3','Pot requests');
  if(!data.requests.length)addText(target,'p','No pot requests.');
  for(const request of data.requests) {
    const row=document.createElement('article'); row.className='membership-card';
    addText(row,'strong',request.name); addText(row,'p',`Request ${request.status}`);
    if(request.status==='pending')requestControls(row,request,client,reload,feedback); target.append(row);
  }
  if(data.assignable_pots.length) {
    const label=document.createElement('label'); label.textContent='Assign to a pot';
    const select=document.createElement('select'); select.setAttribute('aria-label',`Assign ${player.name} to a pot`);
    select.add(new Option('Select a pot','')); for(const pot of data.assignable_pots)select.add(new Option(`${pot.name} · ${pot.season}`,pot.id));
    label.append(select);target.append(label);
    action(target,'Assign player',async()=>{if(!select.value)throw new Error('Select a pot.');await rpc(client,'add_player_to_pot',{selected_pot_id:select.value,selected_player_id:player.id});},reload,feedback);
  } else addText(target,'p','No other pots are currently available for assignment.');
}
export async function renderPotRequests(target,pot,client,reload) {
  const feedback=addText(target,'p','','admin-message');feedback.setAttribute('role','status');
  addText(target,'p',pot.is_discoverable?'Join requests enabled while this pot is open and before its deadline.':'Private pot — not listed for players to request.');
  action(target,pot.is_discoverable?'Close join requests':'Open join requests',()=>rpc(client,'set_pot_discoverable',{selected_pot_id:pot.id,discoverable:!pot.is_discoverable}),reload,feedback);
  try {
    const requests=await rpc(client,'get_pot_join_requests',{selected_pot_id:pot.id});
    addText(target,'h3',`Pending join requests (${requests.length})`);
    for(const request of requests){const row=document.createElement('article');addText(row,'strong',request.name);addText(row,'p',request.email);requestControls(row,request,client,reload,feedback);target.append(row);}
  } catch(error){feedback.textContent=error.message;}
}
export function renderAvailablePots(target,pots,client,refresh) {
  target.replaceChildren();addText(target,'h2','Available pots and requests');
  addText(target,'p','Request a place in an open pot. Your organiser decides membership; your account remains available.');
  if(!pots.length)addText(target,'p','No pots are available to request at the moment. Your organiser can also assign you directly.');
  for(const pot of pots){const row=document.createElement('article');row.className='membership-card discovery-card';addText(row,'span',pot.state==='pending'?'Awaiting organiser':pot.state==='declined'?'Request declined':pot.state==='unavailable'?'Joining closed':'Open for requests','discovery-state');addText(row,'h3',pot.name);addText(row,'p',`${pot.season} · ${money(pot.entry_fee_pence)} entry · ${money(pot.buy_back_fee_pence)} buy-back`);
    const feedback=addText(row,'p','','admin-message');feedback.setAttribute('role','status');
    if(pot.state==='pending')addText(row,'p','Request pending — your organiser will review it.');
    else if(pot.state==='unavailable')addText(row,'p',pot.request_status==='pending'?'This pot is no longer available to join. Your earlier request is still recorded for the organiser.':'This pot is no longer available to join.');
    else {if(pot.state==='declined')addText(row,'p','Your request was declined. You may request again while this pot is available.');action(row,pot.state==='declined'?'Request again':'Request to join',()=>rpc(client,'request_pot_membership',{selected_pot_id:pot.id}),refresh,feedback);}
    target.append(row);
  }
}
