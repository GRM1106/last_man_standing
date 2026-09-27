import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { beforeEach,afterEach,expect,it,vi } from 'vitest';
const client=vi.hoisted(()=>({auth:{getSession:vi.fn(async()=>({data:{session:{user:{id:'alice'},access_token:'test'}}})),onAuthStateChange:vi.fn()},rpc:vi.fn()}));
vi.mock('@supabase/supabase-js',()=>({createClient:()=>client}));
vi.mock('../account-client.js',async importOriginal=>{const actual=await importOriginal();return {createAccountClient:()=>actual.createAccountClient({navigate:vi.fn()})};});
vi.mock('../config.js',()=>({SUPABASE_URL:'http://127.0.0.1:55321',SUPABASE_PUBLISHABLE_KEY:'test'}));
let dom,ui;
const pots=['a','b'].map(id=>({id,name:`Pot ${id}`,payment_status:'unpaid',player_status:'active',entry_fee_pence:1000,buy_back_fee_pence:500}));
const reply=(name)=>name==='get_my_dashboard'?{data:{pots}}:name==='get_available_pots'?{data:[]}:{error:{message:'Panel is outside this test'}};
beforeEach(async()=>{client.auth.getSession.mockResolvedValue({data:{session:{user:{id:'alice'},access_token:'test'}}});client.auth.onAuthStateChange.mockClear();client.rpc.mockClear();vi.useFakeTimers();dom=new JSDOM(readFileSync(new URL('../dashboard.html',import.meta.url),'utf8'),{url:'http://localhost/dashboard.html'});vi.stubGlobal('window',dom.window);vi.stubGlobal('document',dom.window.document);vi.stubGlobal('Option',dom.window.Option);client.rpc.mockImplementation(async name=>reply(name));vi.resetModules();ui=await import('../dashboard.js');await vi.waitFor(()=>expect(document.querySelectorAll('#dashboard-pot option')).toHaveLength(2));client.rpc.mockClear();});
afterEach(()=>{vi.clearAllTimers();vi.useRealTimers();dom.window.close();vi.unstubAllGlobals();});
it('preserves a selection made during a dashboard refresh and hides other pot cards',async()=>{await ui.loadDashboard();let resolve;const pending=new Promise(r=>resolve=r);client.rpc.mockImplementation(name=>name==='get_my_dashboard'?pending:Promise.resolve(reply(name)));const loading=ui.loadDashboard();const select=document.querySelector('#dashboard-pot');select.value='b';ui.selectDashboardPot();resolve({data:{pots:[...pots].reverse()}});await loading;expect(select.value).toBe('b');expect(document.querySelector('[data-pot-id="a"]').hidden).toBe(true);expect(document.querySelector('[data-pot-id="b"]').hidden).toBe(false);});
it('rejects an older dashboard response after a newer membership load',async()=>{let resolve;const pending=new Promise(r=>resolve=r);client.rpc.mockImplementationOnce(()=>pending);const first=ui.loadDashboard();await vi.waitFor(()=>expect(client.rpc).toHaveBeenCalled());await ui.loadDashboard();resolve({data:{pots:[]}});await first;expect(document.querySelectorAll('#dashboard-pot option')).toHaveLength(2);expect(document.querySelector('#dashboard-empty').hidden).toBe(true);});
it('keeps discovery visible for a registered account with no memberships',async()=>{client.rpc.mockImplementation(async name=>name==='get_my_dashboard'?{data:{pots:[],first_name:'New',email:'new@example.test'}}:reply(name));await ui.loadDashboard();expect(document.querySelector('#dashboard-content').hidden).toBe(false);expect(document.querySelector('#dashboard-empty').hidden).toBe(false);expect(document.querySelector('#available-pots').textContent).toContain('Available pots and requests');expect(document.querySelector('#account-email').textContent).toBe('new@example.test');});

it('cancels an open pick confirmation when the selected competition changes',async()=>{
  await ui.loadDashboard();
  const dialog=document.querySelector('#pick-confirmation');
  dialog.setAttribute('open','');dialog.close=vi.fn(()=>dialog.removeAttribute('open'));
  document.querySelector('#dashboard-pot').value='b';ui.selectDashboardPot();
  expect(dialog.close).toHaveBeenCalledWith('cancel');
  expect(client.rpc.mock.calls.some(([name])=>name==='confirm_team_pick')).toBe(false);
});
it('cancels an open pick confirmation before refreshing memberships',async()=>{
  await ui.loadDashboard();
  const dialog=document.querySelector('#pick-confirmation');
  dialog.setAttribute('open','');dialog.close=vi.fn(()=>dialog.removeAttribute('open'));
  await ui.loadDashboard();
  expect(dialog.close).toHaveBeenCalledWith('cancel');
});

async function pickableDashboard() {
  client.rpc.mockClear();
  client.rpc.mockImplementation(async name => {
    if(name==='get_pot_selection') return {data:{gameweek_number:1,player_status:'active',fixtures:[{id:12,kickoff_at:'2035-01-01T12:00:00Z',home_team:{id:3,name:'Home',available:true},away_team:{id:4,name:'Away',available:true}}]}};
    if(name==='get_my_team_availability') return {data:[]};
    if(name==='get_gameweek_deadline') return {data:{deadline:'2035-01-01T12:00:00Z',deadline_passed:false}};
    if(name==='confirm_team_pick') return {data:{}};
    return reply(name);
  });
  const dialog=document.querySelector('#pick-confirmation');
  dialog.showModal=()=>dialog.setAttribute('open','');
  dialog.close=value=>{dialog.returnValue=value;dialog.removeAttribute('open');dialog.dispatchEvent(new dom.window.Event('close'));};
  await ui.loadDashboard();
  await vi.waitFor(()=>expect(document.querySelectorAll('.pick-team')).toHaveLength(4));
  return dialog;
}
it('submits only the explicitly confirmed pot and prevents duplicate pick dialogues',async()=>{
  const dialog=await pickableDashboard();
  document.querySelector('#dashboard-pot').value='b';ui.selectDashboardPot();
  const button=document.querySelector('[data-pot-id="b"] .pick-team');
  button.click();button.click();
  expect(document.querySelector('#pick-confirmation-fixture').textContent).toContain('Pot b');
  dialog.close('confirm');
  await vi.waitFor(()=>expect(client.rpc).toHaveBeenCalledWith('confirm_team_pick',{selected_pot_id:'b',selected_fixture_id:12,selected_team_id:3}));
  expect(client.rpc.mock.calls.filter(([name])=>name==='confirm_team_pick')).toHaveLength(1);
});
it('never submits a stale confirmation after the visible pot changes',async()=>{
  const dialog=await pickableDashboard();
  document.querySelector('[data-pot-id="a"] .pick-team').click();
  document.querySelector('#dashboard-pot').value='b';ui.selectDashboardPot();
  dialog.close('confirm');
  await Promise.resolve();
  expect(client.rpc.mock.calls.filter(([name])=>name==='confirm_team_pick')).toHaveLength(0);
});
it('describes a completed pot without inviting another pick',async()=>{
  client.rpc.mockImplementation(async name=>name==='get_my_dashboard'?{data:{pots:[{...pots[0],status:'complete'}]}}:name==='get_pot_selection'?{data:{}}:name==='get_my_team_availability'?{data:[]}:reply(name));
  await ui.loadDashboard();
  expect(document.querySelector('.selection-panel').textContent).toContain('Competition complete');
  expect(document.querySelector('.selection-panel').textContent).not.toContain('MAKE YOUR PICK');
});
it('disables manual refresh until its request finishes, then restores the control',async()=>{
  await ui.loadDashboard();let resolve;
  client.rpc.mockImplementation(name=>name==='get_my_dashboard'?new Promise(r=>resolve=r):Promise.resolve(reply(name)));
  const button=document.querySelector('#refresh-dashboard');button.click();button.click();
  expect(button.disabled).toBe(true);expect(button.textContent).toBe('Refreshing…');
  await vi.waitFor(()=>expect(resolve).toBeTypeOf('function'));
  resolve({data:{pots}});
  await vi.waitFor(()=>expect(button.disabled).toBe(false));
  expect(button.textContent).toBe('Refresh dashboard');
});

const stored = account => window.localStorage.getItem(`lms:selected-pot:${account}`);
async function reloadAs(account) {
  const saved = Object.entries(window.localStorage);
  dom.window.close();
  dom = new JSDOM(readFileSync(new URL('../dashboard.html',import.meta.url),'utf8'),{url:'http://localhost/dashboard.html'});
  vi.stubGlobal('window',dom.window);vi.stubGlobal('document',dom.window.document);vi.stubGlobal('Option',dom.window.Option);
  for(const [key,value] of saved) window.localStorage.setItem(key,value);
  client.auth.getSession.mockResolvedValue({data:{session:{user:{id:account},access_token:'test'}}});
  client.rpc.mockImplementation(async name=>reply(name));vi.resetModules();ui=await import('../dashboard.js');
  await vi.waitFor(()=>expect(document.querySelectorAll('#dashboard-pot option')).toHaveLength(2));
}
function changeAccount(account, broadcast=true) {
  const session=account?{user:{id:account},access_token:'test'}:null;
  client.auth.getSession.mockResolvedValue({data:{session}});
  if(broadcast)client.auth.onAuthStateChange.mock.calls.at(-1)[0](account?'SIGNED_IN':'SIGNED_OUT',session);
}
it('isolates A → B → A preferences across auth events and fresh documents',async()=>{
  document.querySelector('#dashboard-pot').value='a';await ui.selectDashboardPot();
  window.localStorage.setItem('lms:selected-pot:bob','b');
  changeAccount('bob');await ui.selectDashboardPot();expect(stored('alice')).toBe('a');
  expect(document.querySelector('#dashboard-content').hidden).toBe(true);
  await reloadAs('bob');expect(document.querySelector('#dashboard-pot').value).toBe('b');
  document.querySelector('#dashboard-pot').value='a';await ui.selectDashboardPot();expect(stored('bob')).toBe('a');
  changeAccount('alice');await ui.selectDashboardPot();expect(stored('bob')).toBe('a');
  await reloadAs('alice');expect(document.querySelector('#dashboard-pot').value).toBe('a');
  document.querySelector('#dashboard-pot').value='b';await ui.selectDashboardPot();
  expect(stored('alice')).toBe('b');expect(stored('bob')).toBe('a');
});
it('blocks persistence before a delayed cross-tab broadcast arrives',async()=>{
  const before=stored('alice');changeAccount('bob',false);
  document.querySelector('#dashboard-pot').value='b';await ui.selectDashboardPot();
  expect(stored('alice')).toBe(before);expect(stored('bob')).toBe(null);
  expect(document.querySelectorAll('#dashboard-pot option')).toHaveLength(0);
});
it('makes a retained selection handler harmless after logout',async()=>{
  const before=stored('alice');changeAccount(null);await ui.selectDashboardPot();await ui.loadDashboard();
  expect(stored('alice')).toBe(before);expect(document.querySelector('#dashboard-content').hidden).toBe(true);
});
it('discards an old-account dashboard response after an auth change',async()=>{
  let finish;client.rpc.mockImplementation(name=>name==='get_my_dashboard'?new Promise(resolve=>finish=resolve):Promise.resolve(reply(name)));
  const loading=ui.loadDashboard();await vi.waitFor(()=>expect(finish).toBeTypeOf('function'));
  const before=stored('alice');changeAccount('bob');finish({data:{pots,first_name:'Old account'}});await loading;
  expect(document.querySelector('#dashboard-content').hidden).toBe(true);
  expect(document.querySelectorAll('#dashboard-pot option')).toHaveLength(0);
  expect(stored('alice')).toBe(before);expect(stored('bob')).toBe(null);
});
it('restores a same-account preference on full reload and rejects inaccessible saved pots',async()=>{
  document.querySelector('#dashboard-pot').value='b';await ui.selectDashboardPot();await reloadAs('alice');
  expect(document.querySelector('#dashboard-pot').value).toBe('b');
  window.localStorage.setItem('lms:selected-pot:alice','inaccessible');await reloadAs('alice');
  expect(document.querySelector('#dashboard-pot').value).toBe('a');expect(stored('alice')).toBe('a');
});
it('cancels a pick preview on account change and rejects its delayed confirmation',async()=>{
  const dialog=await pickableDashboard();document.querySelector('[data-pot-id="a"] .pick-team').click();
  changeAccount('bob');dialog.close('confirm');await Promise.resolve();
  expect(client.rpc.mock.calls.filter(([name])=>name==='confirm_team_pick')).toHaveLength(0);
});
