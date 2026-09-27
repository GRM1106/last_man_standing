import { JSDOM } from 'jsdom';
import { beforeEach, afterEach, expect, it, vi } from 'vitest';
import { watchMaintenance, maintenanceCopy } from '../maintenance.js';
vi.mock('../config.js', () => ({ SUPABASE_URL: 'http://127.0.0.1:55321', SUPABASE_PUBLISHABLE_KEY: 'test' }));
let dom, screen, fetchRequest, auth, reopen;
const reply = (enabled, status=200) => new Response(JSON.stringify({enabled}), {status});
beforeEach(() => {
  dom = new JSDOM('<main><button>Pick</button></main>', {url:'http://localhost'});
  vi.stubGlobal('window',dom.window);vi.stubGlobal('document',dom.window.document);
  dom.window.HTMLDialogElement.prototype.showModal = function(){this.open=true;};
  dom.window.HTMLDialogElement.prototype.close = function(){this.open=false;};
  fetchRequest=vi.fn(async()=>reply(false));auth={signOut:vi.fn(async()=>({error:{message:'failed'}}))};reopen=vi.fn();
});
afterEach(()=>{screen?.stop();dom.window.close();vi.unstubAllGlobals();});
const start=()=>screen=watchMaintenance({auth},{fetchRequest,interval:100000,reopen});
it('covers startup, then permits normal presentation only on an explicit OFF response',async()=>{
  start();expect(screen.blocked).toBe(true);await screen.check();expect(screen.blocked).toBe(false);
  expect(document.querySelector('dialog').open).toBe(false);
});
it('shows the same accessible maintenance experience to anonymous, player and admin callers',async()=>{
  fetchRequest.mockResolvedValue(reply(true));start();await screen.check();
  expect(document.querySelector('dialog').open).toBe(true);expect(document.body.textContent).toContain(maintenanceCopy);
  expect(document.querySelector('dialog').getAttribute('aria-labelledby')).toBe('maintenance-title');
  const event=new dom.window.Event('cancel',{cancelable:true});document.querySelector('dialog').dispatchEvent(event);expect(event.defaultPrevented).toBe(true);
  expect(fetchRequest.mock.calls[0][1].headers).not.toHaveProperty('Authorization');
});
it.each([undefined,null,'false',0])('fails closed for malformed status %s',async enabled=>{
  fetchRequest.mockResolvedValue(reply(enabled));start();await screen.check();expect(screen.blocked).toBe(true);
});
it.each([404,500,503])('fails closed for HTTP %s even if a body says OFF',async status=>{
  fetchRequest.mockResolvedValue(reply(false,status));start();await screen.check();expect(screen.blocked).toBe(true);
});
it('fails closed on transport errors and recovers on a subsequent explicit state',async()=>{
  fetchRequest.mockRejectedValue(new Error('network'));start();await screen.check();expect(screen.blocked).toBe(true);
  fetchRequest.mockResolvedValue(reply(false));await screen.check();expect(screen.blocked).toBe(false);
});
it('closes stale confirmation dialogues when maintenance becomes active',async()=>{
  start();await screen.check();const old=document.createElement('dialog');document.body.append(old);old.showModal();
  fetchRequest.mockResolvedValue(reply(true));await screen.check();expect(old.open).toBe(false);expect(screen.blocked).toBe(true);
});
it('reloads after reopening so pre-migration data and callbacks are discarded',async()=>{
  fetchRequest.mockResolvedValue(reply(true));start();await screen.check();fetchRequest.mockResolvedValue(reply(false));await screen.check();expect(reopen).toHaveBeenCalledOnce();
});
it('coalesces overlapping checks and does not silently allow an unknown state',async()=>{
  let finish;fetchRequest.mockImplementation(()=>new Promise(resolve=>{finish=resolve;}));start();const check=screen.check();
  expect(fetchRequest).toHaveBeenCalledOnce();expect(screen.blocked).toBe(true);finish(reply(false));await check;expect(screen.blocked).toBe(false);
});
it('keeps logout available and reports a failed logout truthfully',async()=>{
  fetchRequest.mockResolvedValue(reply(true));start();await screen.check();document.querySelector('.maintenance-logout').click();
  await vi.waitFor(()=>expect(auth.signOut).toHaveBeenCalledOnce());expect(document.body.textContent).toContain('Sign out did not complete');
});

it('does not initialise application routes until status is explicitly OFF',async()=>{
  fetchRequest.mockResolvedValue(reply(true));start();const initialise=vi.fn();screen.ready.then(initialise);await screen.check();expect(initialise).not.toHaveBeenCalled();
  fetchRequest.mockResolvedValue(reply(false));await screen.check();expect(initialise).toHaveBeenCalledOnce();
});
