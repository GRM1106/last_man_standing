vi.mock('../maintenance.js', () => ({ watchMaintenance: vi.fn(() => ({ ready: Promise.resolve() })) }));
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { membershipClosed, standingGap, playerName } from "../admin-display.js";
const client = vi.hoisted(() => ({ auth: { getSession: vi.fn(async () => ({ data: { session: {} } })) }, rpc: vi.fn(async () => ({ data: false })) }));
vi.mock("../admin-client.js", () => ({ supabase: client, accountContext: {start: async()=>'alice', onInvalidate: vi.fn(), signOut: vi.fn()} }));
let ui;
beforeEach(async () => {
  client.rpc.mockReset().mockResolvedValue({ data: false });
  vi.useFakeTimers();
  const dom = new JSDOM(readFileSync(new URL("../admin.html", import.meta.url), "utf8"), { url: "http://localhost/admin.html" });
  vi.stubGlobal("window", dom.window); vi.stubGlobal("document", dom.window.document); vi.stubGlobal("Option", dom.window.Option);
  vi.resetModules(); ui = await import("../admin.js");
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); });
const player = { id: "alice", name: "Alice", player_status: "active", payment_status: "unpaid", buy_back_status: "requested",
  picks: [{ gameweek_number: 36, outcome: "lost", short_name: "ALB" }, { gameweek_number: 37, outcome: "won", short_name: "CIT" }] };
it("renders an active re-entrant's future cell as unpicked while retaining the historical loss", () => {
  ui.renderStandings({ players: [player], gameweeks: [36,37,38], current_gameweek: 38 });
  const cells = document.querySelectorAll("tbody td");
  expect(cells[1].textContent).toContain("lost"); expect(cells[2].textContent).toContain("won");
  expect(cells[3].textContent).toBe("—"); expect(cells[3].classList.contains("after-elimination")).toBe(false);
});
it("shows an eligible gap immediately after buy-back before the next pick", () => {
  expect(standingGap({ ...player, picks: player.picks.slice(0,1) }, 37, 37)).toBe("empty");
});
it("keeps eliminated players crossed out after their latest loss", () => {
  expect(standingGap({ ...player, player_status: "eliminated", picks: [{ gameweek_number: 37, outcome: "lost" }] }, 38, 38)).toBe("eliminated");
});
it("preserves earlier elimination gaps but clears the loss after a later surviving pick", () => {
  const history = { ...player, picks: [{ gameweek_number: 34, outcome: "lost" }, { gameweek_number: 36, outcome: "won" }] };
  expect(standingGap(history,35,38)).toBe("eliminated"); expect(standingGap(history,37,38)).toBe("empty");
});
it.each(["won", "postponed", "pending"])("a later %s pick breaks the historical loss latch", outcome => {
  expect(standingGap({ ...player, picks: [player.picks[0], { gameweek_number: 37, outcome }] },38,39)).toBe("empty");
});
it("allows membership before the first deadline", () => {
  expect(membershipClosed({ id:"pot", lifecycle_status:"open" }, [{ pot_id:"pot", pick_deadline_at:"2030-01-01" }], Date.parse("2029-01-01"))).toBe(false);
});
it("closes membership exactly at the deadline even without a persisted lock", () => {
  expect(membershipClosed({ id:"pot", lifecycle_status:"setup" }, [{ pot_id:"pot", pick_deadline_at:"2030-01-01" }], Date.parse("2030-01-01"))).toBe(true);
});
it("keeps a persisted membership lock closed after a moved deadline", () => {
  expect(membershipClosed({ id:"pot", lifecycle_status:"open", membership_locked_at:"2028-01-01" }, [{ pot_id:"pot", pick_deadline_at:"2030-01-01" }], Date.parse("2029-01-01"))).toBe(true);
});
it.each(["in_progress", "review", "complete"])("disables membership for %s despite legacy open status", lifecycle_status => {
  expect(membershipClosed({ id:"pot", status:"open", lifecycle_status }, [])).toBe(true);
});
it("does not use another pot's deadline", () => {
  expect(membershipClosed({ id:"pot", lifecycle_status:"setup" }, [{ pot_id:"other", pick_deadline_at:"2000-01-01" }])).toBe(false);
});
it("updates rendered membership and draft controls as the deadline passes without a reload", () => {
  vi.setSystemTime(new Date("2030-01-01T00:00:00Z"));
  document.querySelector("#pot-list").innerHTML='<article class="pot-card"><div class="pot-member"></div></article>';
  ui.addPotManagement([{ id:"pot", name:"Pot", status:"draft", lifecycle_status:"setup" }], [{ pot_id:"pot", player_id:"alice" }], [{ pot_id:"pot", pick_deadline_at:"2030-01-01T00:00:01Z" }]);
  const remove = document.querySelector(".membership-edit"); expect(remove.disabled).toBe(false);
  vi.advanceTimersByTime(1000); expect(remove.disabled).toBe(true);
  expect(document.querySelector(".delete-pot-button").disabled).toBe(true);
  expect(document.querySelector(".pot-management select").disabled).toBe(true);
});
it("renders zero players and no phantom row for an empty RPC result", () => {
  ui.renderAdminPicks({ players: [], pot_status:"draft", test_mode:false });
  expect(document.querySelector("#admin-pick-list").textContent).toContain("No players are assigned");
  expect(document.querySelectorAll(".admin-pick-row")).toHaveLength(0);
  expect([...document.querySelectorAll("#pick-summary strong")].map(x=>x.textContent)).toEqual(["0","0","0"]);
});
it("refreshes registered players from the current query result", async () => {
  let players = [{id:"one",first_name:"First",email:"one@example.test",created_at:"2026-01-01"}];
  client.from = vi.fn(() => ({select:()=>({order:async()=>({data:players})})}));
  await ui.loadPlayers(); expect(document.querySelectorAll(".player-row")).toHaveLength(1);
  players = [...players,{id:"two",first_name:"Second",email:"two@example.test",created_at:"2026-01-02"}];
  await ui.loadPlayers(); expect(document.querySelectorAll(".player-row")).toHaveLength(2);
  expect(document.querySelector("#player-count").textContent).toBe("2");
});
it("distinguishes no filter matches from no imported data", async () => {
  const { renderAdminFixtureResults } = await import("../fixture-results-ui.js");
  const target=document.querySelector("#fixture-list");
  renderAdminFixtureResults(target,[],vi.fn(),true); expect(target.textContent).toBe("No fixtures match these filters.");
  renderAdminFixtureResults(target,[],vi.fn(),false); expect(target.textContent).toContain("No fixtures imported yet");
});
it("retains a successful pot operation message after reloading its authoritative data", async () => {
  client.from = vi.fn(() => ({select:()=>({data:[],order:async()=>({data:[]})})}));
  await ui.loadPots("Draft deleted."); expect(document.querySelector("#admin-message").textContent).toBe("Draft deleted.");
});
it("describes unpaid eligible random assignment without claiming payment", async () => {
  client.rpc.mockResolvedValueOnce({data:{ready:true,missing:1}});
  document.querySelector("#pick-pot").add(new Option("Pot","pot"));
  document.querySelector("#pick-gameweek").add(new Option("GW1","1"));
  await import("../gameweek-processing.js");
  document.querySelector("#assign-random-picks").click(); await Promise.resolve(); await Promise.resolve();
  expect(document.querySelector("#admin-message").textContent).toContain("1 eligible player is missing a pick");
});

it("retains processing feedback while refreshing the selected round", async () => {
  document.querySelector("#pick-pot").add(new Option("Pot","pot"));
  document.querySelector("#pick-gameweek").add(new Option("GW1","1"));
  client.rpc.mockImplementation(async name => ({data:name==="get_admin_pick_overview" ? {players:[],pot_status:"draft"} : {deadline:null}}));
  await ui.loadAdminPicks({detail:{message:"GW1 processed: 1 survived and 0 eliminated."}});
  expect(document.querySelector("#admin-message").textContent).toContain("GW1 processed");
  expect(document.querySelector("#admin-pick-list").textContent).toContain("No players are assigned");
});

it.each([
  [{first_name:"  Alice",last_name:"Smith  ",email:"alice@example.test"},"Alice Smith"],
  [{display_name:"  ALICE@EXAMPLE.TEST ",email:"alice@example.test"},"Player"],
  [{display_name:"Nickname",email:"alice@example.test"},"Nickname"],
  [{first_name:" ",last_name:" ",email:"alice@example.test"},"Player"],
])("formats names independently of authorised contact details: %j", (input,expected) => {
  expect(playerName(input)).toBe(expected);
});
it("does not tell an eliminated player without a pick that a pick is awaited", () => {
  ui.renderAdminPicks({players:[{...player,player_status:"eliminated",pick:null}],pot_status:"open"});
  expect(document.querySelector("#admin-pick-list").textContent).toContain("No pick recorded");
  expect(document.querySelector("#admin-pick-list").textContent).not.toContain("Awaiting");
});
it("clears a previous round's reset action when the selected pot changes", async () => {
  await import("../gameweek-processing.js");
  const reset=document.querySelector("#reset-test-processing"); reset.hidden=false;
  document.querySelector("#pick-pot").dispatchEvent(new window.Event("change"));
  expect(reset.hidden).toBe(true);
});

it('retains a pot selected while the standings filter query is in flight', async () => {
  let resolve; const pending=new Promise(r=>resolve=r);
  const select=document.querySelector('#standings-pot');select.add(new Option('A','a'));select.add(new Option('B','b'));
  client.from=vi.fn(()=>({select:()=>({order:()=>pending})}));
  client.rpc.mockResolvedValue({data:{players:[],gameweeks:[]}});
  const loading=ui.loadStandingsFilters();select.value='b';
  resolve({data:[{id:'a',name:'A'},{id:'b',name:'B'}]});await loading;
  expect(select.value).toBe('b');expect(client.rpc).toHaveBeenLastCalledWith('get_pot_standings',{selected_pot_id:'b'});
});
it('ignores stale standings errors after a newer pot has rendered', async () => {
  let resolve;const pending=new Promise(r=>resolve=r);
  const select=document.querySelector('#standings-pot');select.add(new Option('A','a'));select.add(new Option('B','b'));
  client.rpc.mockImplementationOnce(()=>pending).mockResolvedValueOnce({data:{players:[{...player,name:'Current player'}],gameweeks:[]}});
  const first=ui.loadStandings();select.value='b';await ui.loadStandings();resolve({error:{message:'Old failure'}});await first;
  expect(document.querySelector('#standings-board').textContent).toContain('Current player');expect(document.querySelector('#admin-message').textContent).not.toContain('Old failure');
});
it('retains both selected pot and week while pick filters refresh', async () => {
  let resolve;const pending=new Promise(r=>resolve=r);const pots=document.querySelector('#pick-pot'),weeks=document.querySelector('#pick-gameweek');
  pots.add(new Option('A','a'));pots.add(new Option('B','b'));weeks.add(new Option('GW2','2'));weeks.add(new Option('GW3','3'));
  client.from=vi.fn(table=>({select:()=>table==='pots'?{order:()=>pending}:{data:[{pot_id:'b',gameweek_number:2},{pot_id:'b',gameweek_number:3}]}}));
  client.rpc.mockImplementation(async name=>({data:name==='get_admin_pick_overview'?{players:[],pot_status:'open'}:{deadline:null}}));
  const loading=ui.loadPickFilters();pots.value='b';weeks.value='3';resolve({data:[{id:'a',name:'A'},{id:'b',name:'B'}]});await loading;
  expect(pots.value).toBe('b');expect(weeks.value).toBe('3');
});
it('ignores an older picks response when the selected pot changes', async () => {
  let resolve;const pending=new Promise(r=>resolve=r);const pots=document.querySelector('#pick-pot');pots.add(new Option('A','a'));pots.add(new Option('B','b'));document.querySelector('#pick-gameweek').add(new Option('GW1','1'));
  client.rpc.mockImplementation((name,args)=>name==='get_gameweek_deadline'?Promise.resolve({data:{deadline:null}}):args.selected_pot_id==='a'?pending:Promise.resolve({data:{players:[],pot_status:'open'}}));
  const loading=ui.loadAdminPicks();pots.value='b';await ui.loadAdminPicks();resolve({error:{message:'Stale failure'}});await loading;
  expect(document.querySelector('#admin-pick-list').textContent).toContain('No players are assigned');expect(document.querySelector('#admin-message').textContent).not.toContain('Stale failure');
});
