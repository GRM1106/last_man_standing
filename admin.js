import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";
import {
  addImage,
  addText,
  renderAdminPickIdentity,
  renderIdentity,
  renderMetric,
  renderStandingPick,
} from "./ui.js";
const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
const loading = document.querySelector("#admin-loading"),
  denied = document.querySelector("#admin-denied"),
  content = document.querySelector("#admin-content"),
  playerList = document.querySelector("#player-list"),
  playerCount = document.querySelector("#player-count"),
  countLabel = document.querySelector("#count-label"),
  adminTitle = document.querySelector("#admin-title"),
  message = document.querySelector("#admin-message"),
  signOutButton = document.querySelector("#sign-out"),
  playersView = document.querySelector("#players-view"),
  potsView = document.querySelector("#pots-view"),
  fixturesView = document.querySelector("#fixtures-view"),
  picksView = document.querySelector("#picks-view"),
  standingsView = document.querySelector("#standings-view"),
  potForm = document.querySelector("#pot-form"),
  showPotFormButton = document.querySelector("#show-pot-form"),
  cancelPotButton = document.querySelector("#cancel-pot"),
  gameweekGrid = document.querySelector("#gameweek-grid"),
  potPlayerOptions = document.querySelector("#pot-player-options"),
  potList = document.querySelector("#pot-list"),
  syncFplButton = document.querySelector("#sync-fpl"),
  fixtureList = document.querySelector("#fixture-list"),
  fixtureSyncDetail = document.querySelector("#fixture-sync-detail"),
  pickPot = document.querySelector("#pick-pot"),
  pickGameweek = document.querySelector("#pick-gameweek"),
  adminPickList = document.querySelector("#admin-pick-list"),
  pickSummary = document.querySelector("#pick-summary"),
  testModeToggle = document.querySelector("#test-mode-toggle"),
  testModeNote = document.querySelector("#test-mode-note"),
  standingsPot = document.querySelector("#standings-pot"),
  standingsBoard = document.querySelector("#standings-board"),
  standingsSummary = document.querySelector("#standings-summary");
const pickDeadline = document.querySelector("#pick-deadline"),
  randomPickButton = document.querySelector("#assign-random-picks");
const CURRENT_SEASON = "2026/27";
let allPlayers = [];
const playerName = (player) =>
  [player.first_name, player.last_name].filter(Boolean).join(" ") ||
  player.display_name ||
  "Unnamed player";
function showDenied() {
  loading.hidden = true;
  content.hidden = true;
  denied.hidden = false;
}
function renderPlayers(players) {
  playerCount.textContent = players.length;
  playerList.replaceChildren();
  if (!players.length) {
    const empty = document.createElement("p");
    empty.className = "empty-list";
    empty.textContent = "No players have registered yet.";
    playerList.append(empty);
    return;
  }
  players.forEach((player) => {
    const row = document.createElement("article");
    row.className = "player-row";
    const details = document.createElement("div");
    details.className = "player-details";
    const name = document.createElement("h2");
    name.textContent = playerName(player);
    const email = document.createElement("p");
    email.textContent = player.email;
    const joined = document.createElement("small");
    joined.textContent = `Joined ${new Date(player.created_at).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" })}`;
    details.append(name, email, joined);
    const controls = document.createElement("div");
    controls.className = "player-controls";
    const status = document.createElement("span");
    status.className = `status ${player.approved ? "approved" : "pending"}`;
    status.textContent = player.approved ? "Approved" : "Waiting";
    const button = document.createElement("button");
    button.className = `approval-button ${player.approved ? "revoke" : "approve"}`;
    button.type = "button";
    button.textContent = player.approved ? "Revoke access" : "Approve player";
    button.addEventListener("click", () =>
      setApproval(player, !player.approved, button),
    );
    controls.append(status, button);
    row.append(details, controls);
    playerList.append(row);
  });
}
async function loadPlayers() {
  const { data, error } = await supabase
    .from("profiles")
    .select(
      "id,email,display_name,first_name,last_name,approved,is_admin,created_at",
    )
    .order("created_at", { ascending: false });
  if (error) {
    message.textContent = `Couldn’t load players: ${error.message}`;
    return;
  }
  allPlayers = data;
  renderPlayers(allPlayers);
}
async function setApproval(player, newApproved, button) {
  button.disabled = true;
  message.textContent = `${newApproved ? "Approving" : "Revoking access for"} ${playerName(player)}…`;
  const { error } = await supabase.rpc("set_player_approval", {
    player_id: player.id,
    new_approved: newApproved,
  });
  if (error) {
    button.disabled = false;
    message.textContent = error.message;
    return;
  }
  message.textContent = `${playerName(player)} is now ${newApproved ? "approved" : "waiting for approval"}.`;
  await loadPlayers();
}
function renderPotPlayerOptions() {
  potPlayerOptions.replaceChildren();
  const approved = allPlayers.filter((player) => player.approved);
  if (!approved.length) {
    potPlayerOptions.textContent =
      "Approve at least one player before creating a pot.";
    return;
  }
  approved.forEach((player) => {
    const label = document.createElement("label");
    label.className = "check-option";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.name = "playerIds";
    input.value = player.id;
    const text = document.createElement("span");
    addText(text, "strong", playerName(player));
    addText(text, "small", player.email);
    label.append(input, text);
    potPlayerOptions.append(label);
  });
}
function buildGameweekGrid() {
  for (let gameweek = 1; gameweek <= 38; gameweek += 1) {
    const label = document.createElement("label");
    label.className = "gameweek-option";
    const input = document.createElement("input");
    input.type = "radio";
    input.name = "startGameweek";
    input.value = String(gameweek);
    input.required = true;
    const text = document.createElement("span");
    text.textContent = `GW${gameweek}`;
    label.append(input, text);
    gameweekGrid.append(label);
  }
}
function money(pence) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
  }).format(pence / 100);
}
function paymentLabel(status) {
  return status === "paid"
    ? "Paid"
    : status === "claimed"
      ? "Player says paid"
      : "Not paid";
}
function renderPots(pots, gameweeks, members) {
  potList.replaceChildren();
  playerCount.textContent = pots.length;
  countLabel.textContent = pots.length === 1 ? "pot" : "pots";
  if (!pots.length) {
    addText(
      potList,
      "p",
      "No pots yet. Create your first draft pot above.",
      "empty-list",
    );
    return;
  }
  pots.forEach((pot) => {
    const potGameweeks = gameweeks
      .filter((item) => item.pot_id === pot.id)
      .map((item) => item.gameweek_number)
      .sort((a, b) => a - b);
    const potMembers = members.filter((item) => item.pot_id === pot.id);
    const card = document.createElement("article");
    card.className = "pot-card";
    const heading = document.createElement("header"),
      headingCopy = document.createElement("div");
    addText(headingCopy, "span", pot.status, "status pending");
    addText(headingCopy, "h2", pot.name);
    addText(
      headingCopy,
      "p",
      `${pot.season} · ${money(pot.entry_fee_pence)} entry · ${money(pot.buy_back_fee_pence)} buy-back`,
    );
    addText(
      heading,
      "strong",
      `${potMembers.length} player${potMembers.length === 1 ? "" : "s"}`,
    );
    heading.prepend(headingCopy);
    const weeks = document.createElement("div");
    weeks.className = "pot-weeks";
    const weekText = document.createElement("span");
    weekText.textContent = potGameweeks.map((gw) => `GW${gw}`).join(" · ");
    weeks.append(weekText);
    if (potGameweeks.length && potGameweeks.at(-1) < 38) {
      const fillButton = document.createElement("button");
      fillButton.type = "button";
      fillButton.className = "fill-weeks-button";
      fillButton.textContent = "Include through GW38";
      fillButton.addEventListener("click", () =>
        fillRemainingGameweeks(pot.id, fillButton),
      );
      weeks.append(fillButton);
    }
    const memberList = document.createElement("div");
    memberList.className = "pot-member-list";
    potMembers.forEach((member) => {
      const player = allPlayers.find((item) => item.id === member.player_id);
      const row = document.createElement("div");
      row.className = "pot-member";
      const details = document.createElement("span");
      addText(
        details,
        "strong",
        player ? playerName(player) : "Unknown player",
      );
      addText(details, "small", player?.email || "");
      const select = document.createElement("select");
      select.setAttribute(
        "aria-label",
        `Payment status for ${player ? playerName(player) : "player"}`,
      );
      [
        ["unpaid", "Not paid"],
        ["claimed", "Player says paid"],
        ["paid", "Paid"],
      ].forEach(([value, label]) => {
        const option = document.createElement("option");
        option.value = value;
        option.textContent = label;
        option.selected = member.payment_status === value;
        select.append(option);
      });
      select.addEventListener("change", () =>
        setPayment(pot.id, member.player_id, select),
      );
      row.append(details, select);
      memberList.append(row);
    });
    card.append(heading, weeks, memberList);
    potList.append(card);
  });
}
async function fillRemainingGameweeks(potId, button) {
  button.disabled = true;
  message.textContent = "Adding the remaining gameweeks…";
  const { error } = await supabase.rpc("fill_remaining_pot_gameweeks", {
    selected_pot_id: potId,
  });
  if (error) {
    button.disabled = false;
    message.textContent = `${error.message}. Run 08 — Automatic remaining gameweeks in Supabase.`;
    return;
  }
  message.textContent =
    "The pot now includes every remaining gameweek through GW38.";
  await loadPots();
}
function addBuyBackControls(pots, members) {
  document.querySelectorAll(".pot-card").forEach((card, potIndex) => {
    const pot = pots[potIndex],
      potMembers = members.filter((member) => member.pot_id === pot.id);
    card.querySelectorAll(".pot-member").forEach((row, memberIndex) => {
      const member = potMembers[memberIndex],
        details = row.querySelector("span"),
        existing = row.querySelector("select");
      if (existing) existing.dataset.saved = member.payment_status;
      if (details) {
        const note = document.createElement("small");
        note.textContent = `${member.player_status} · buy-back ${member.buy_back_status}`;
        details.append(note);
      }
      if (member.buy_back_status !== "claimed") return;
      const controls = document.createElement("div");
      controls.className = "pot-member-controls";
      if (existing) controls.append(existing);
      const approve = document.createElement("button");
      approve.type = "button";
      approve.className = "fill-weeks-button";
      approve.textContent = `Confirm ${money(pot.buy_back_fee_pence)} buy-back`;
      approve.addEventListener("click", () =>
        setBuyBack(pot.id, member.player_id, true, approve),
      );
      const reject = document.createElement("button");
      reject.type = "button";
      reject.className = "fill-weeks-button";
      reject.textContent = "Reject claim";
      reject.addEventListener("click", () =>
        setBuyBack(pot.id, member.player_id, false, reject),
      );
      controls.append(approve, reject);
      row.append(controls);
    });
  });
}
function armAction(button, armedLabel, action) {
  if (button.dataset.armed === "true") {
    action();
    return;
  }
  button.dataset.armed = "true";
  button.textContent = armedLabel;
  setTimeout(() => {
    if (button.isConnected) {
      button.dataset.armed = "false";
      button.textContent = button.dataset.original;
    }
  }, 4000);
}
function addPotManagement(pots, members) {
  document.querySelectorAll(".pot-card").forEach((card, potIndex) => {
    const pot = pots[potIndex],
      potMembers = members.filter((member) => member.pot_id === pot.id),
      memberIds = new Set(potMembers.map((member) => member.player_id));
    const management = document.createElement("div");
    management.className = "pot-management";
    const select = document.createElement("select");
    select.setAttribute("aria-label", `Add a player to ${pot.name}`);
    const available = allPlayers.filter(
      (player) => player.approved && !memberIds.has(player.id),
    );
    select.innerHTML = '<option value="">Select approved player</option>';
    available.forEach((player) => {
      const option = document.createElement("option");
      option.value = player.id;
      option.textContent = `${playerName(player)} · ${player.email}`;
      select.append(option);
    });
    const add = document.createElement("button");
    add.type = "button";
    add.className = "fill-weeks-button";
    add.textContent = "Add player";
    add.disabled = !available.length || !["draft", "open"].includes(pot.status);
    add.addEventListener("click", () => addPlayerToPot(pot.id, select, add));
    management.append(select, add);
    if (pot.status === "draft") {
      const removeButtons = card.querySelectorAll(".pot-member");
      removeButtons.forEach((row, index) => {
        const member = potMembers[index],
          player = allPlayers.find((item) => item.id === member.player_id),
          remove = document.createElement("button");
        remove.type = "button";
        remove.className = "pot-danger-button";
        remove.dataset.original = "Remove";
        remove.textContent = "Remove";
        remove.addEventListener("click", () =>
          armAction(remove, "Click again to remove", () =>
            removePlayerFromPot(
              pot.id,
              member.player_id,
              player ? playerName(player) : "player",
              remove,
            ),
          ),
        );
        row.append(remove);
      });
      const deletion = document.createElement("button");
      deletion.type = "button";
      deletion.className = "pot-danger-button delete-pot-button";
      deletion.dataset.original = "Delete draft pot";
      deletion.textContent = "Delete draft pot";
      deletion.addEventListener("click", () =>
        armAction(deletion, `Click again to delete ${pot.name}`, () =>
          deletePot(pot, deletion),
        ),
      );
      management.append(deletion);
    }
    card.append(management);
  });
}
function addTournamentControls(pots, members) {
  document.querySelectorAll(".pot-card").forEach((card, index) => {
    const pot = pots[index],
      potMembers = members.filter((member) => member.pot_id === pot.id),
      active = potMembers.filter((member) => member.player_status === "active");
    const bar = document.createElement("div");
    bar.className = "tournament-controls";
    const label = document.createElement("strong");
    label.textContent = "Pot status";
    const status = document.createElement("select");
    [
      ["draft", "Draft"],
      ["open", "Open for entries"],
      ["active", "Active"],
      ["complete", "Complete"],
    ].forEach(([value, text]) => {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = text;
      option.selected = pot.status === value;
      option.disabled = value === "complete" && pot.status !== "complete";
      status.append(option);
    });
    status.disabled = ["active", "complete"].includes(pot.status);
    const save = document.createElement("button");
    save.type = "button";
    save.className = "fill-weeks-button";
    save.textContent = "Save status";
    save.disabled = ["active", "complete"].includes(pot.status);
    save.addEventListener("click", () => savePotStatus(pot.id, status, save));
    bar.append(label, status, save);
    if (pot.test_mode && pot.status === "draft") {
      const reset = document.createElement("button");
      reset.type = "button";
      reset.className = "pot-danger-button";
      reset.dataset.original = "Reset all test rounds";
      reset.textContent = reset.dataset.original;
      reset.addEventListener("click", () =>
        armAction(reset, "Click again to wipe test progress", () =>
          resetTestPot(pot, reset),
        ),
      );
      bar.append(reset);
    }
    if (active.length === 1 && pot.status !== "complete") {
      const player = allPlayers.find((item) => item.id === active[0].player_id),
        finish = document.createElement("button");
      finish.type = "button";
      finish.className = "winner-button";
      finish.dataset.original = `Crown ${player ? playerName(player) : "winner"}`;
      finish.textContent = finish.dataset.original;
      finish.addEventListener("click", () =>
        armAction(finish, "Click again to complete pot", () =>
          completePot(pot, active[0].player_id, finish),
        ),
      );
      bar.append(finish);
    }
    card.prepend(bar);
  });
}
async function loadPots() {
  message.textContent = "Loading pots…";
  const [potsResult, weeksResult, membersResult] = await Promise.all([
    supabase.from("pots").select("*").order("created_at", { ascending: false }),
    supabase.from("pot_gameweeks").select("pot_id,gameweek_number"),
    supabase
      .from("pot_players")
      .select("pot_id,player_id,payment_status,player_status,buy_back_status"),
  ]);
  const error = potsResult.error || weeksResult.error || membersResult.error;
  if (error) {
    message.textContent = `Couldn’t load pots: ${error.message}. Run 06 — Pot and payment setup in Supabase.`;
    return;
  }
  message.textContent = "";
  renderPots(potsResult.data, weeksResult.data, membersResult.data);
  addBuyBackControls(potsResult.data, membersResult.data);
  addPotManagement(potsResult.data, membersResult.data);
  addTournamentControls(potsResult.data, membersResult.data);
}
function setPayment(potId, playerId, select) {
  const row = select.closest(".pot-member"),
    oldConfirmation = row.querySelector(".payment-confirmation");
  if (oldConfirmation) oldConfirmation.remove();
  select.disabled = true;
  const confirmation = document.createElement("div");
  confirmation.className = "payment-confirmation";
  const prompt = document.createElement("span");
  prompt.textContent = `Save as “${paymentLabel(select.value)}”?`;
  const save = document.createElement("button");
  save.type = "button";
  save.className = "payment-save-button";
  save.textContent = "Save change";
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "payment-cancel-button";
  cancel.textContent = "Cancel";
  save.addEventListener("click", () =>
    applyPayment(potId, playerId, select, confirmation, save),
  );
  cancel.addEventListener("click", () => {
    select.value = select.dataset.saved;
    select.disabled = false;
    confirmation.remove();
    message.textContent = "Payment change cancelled.";
  });
  confirmation.append(prompt, save, cancel);
  row.append(confirmation);
  message.textContent = "Review the payment change, then save or cancel.";
}
async function applyPayment(potId, playerId, select, confirmation, button) {
  button.disabled = true;
  message.textContent = `Saving payment as “${paymentLabel(select.value)}”…`;
  const { error } = await supabase.rpc("set_pot_player_payment", {
    selected_pot_id: potId,
    selected_player_id: playerId,
    new_payment_status: select.value,
  });
  if (error) {
    message.textContent = error.message;
    button.disabled = false;
    return;
  }
  select.dataset.saved = select.value;
  select.disabled = false;
  confirmation.remove();
  message.textContent = "Payment status saved.";
}
async function setBuyBack(potId, playerId, approved, button) {
  button.disabled = true;
  message.textContent = approved
    ? "Confirming the buy-back payment…"
    : "Rejecting the buy-back claim…";
  const { error } = await supabase.rpc("set_buy_back_decision", {
    selected_pot_id: potId,
    selected_player_id: playerId,
    approved,
  });
  if (error) {
    message.textContent = `${error.message}. Run 14 — One-time buy-back workflow in Supabase.`;
    button.disabled = false;
    return;
  }
  message.textContent = approved
    ? "Buy-back confirmed. The player is active again."
    : "Buy-back claim rejected.";
  await loadPots();
}
async function addPlayerToPot(potId, select, button) {
  if (!select.value) {
    message.textContent = "Select a player to add.";
    return;
  }
  button.disabled = true;
  message.textContent = "Adding the player…";
  const { error } = await supabase.rpc("add_player_to_pot", {
    selected_pot_id: potId,
    selected_player_id: select.value,
  });
  if (error) {
    message.textContent = `${error.message}. Run 15 — Edit pot players and delete draft pots in Supabase.`;
    button.disabled = false;
    return;
  }
  message.textContent = "Player added to the pot.";
  await loadPots();
}
async function removePlayerFromPot(potId, playerId, name, button) {
  button.disabled = true;
  message.textContent = `Removing ${name}…`;
  const { error } = await supabase.rpc("remove_player_from_pot", {
    selected_pot_id: potId,
    selected_player_id: playerId,
  });
  if (error) {
    message.textContent = `${error.message}. Run 15 — Edit pot players and delete draft pots in Supabase.`;
    button.disabled = false;
    return;
  }
  message.textContent = `${name} was removed from the pot.`;
  await loadPots();
}
async function deletePot(pot, button) {
  button.disabled = true;
  message.textContent = `Deleting ${pot.name}…`;
  const { error } = await supabase.rpc("delete_draft_pot", {
    selected_pot_id: pot.id,
    confirmation_name: pot.name,
  });
  if (error) {
    message.textContent = `${error.message}. Run 15 — Edit pot players and delete draft pots in Supabase.`;
    button.disabled = false;
    return;
  }
  message.textContent = `${pot.name} was deleted.`;
  await loadPots();
}
async function savePotStatus(potId, select, button) {
  button.disabled = true;
  message.textContent = "Saving pot status…";
  const { error } = await supabase.rpc("set_pot_status", {
    selected_pot_id: potId,
    new_status: select.value,
  });
  if (error) {
    message.textContent = `${error.message}. Run 18 — Tournament lifecycle, history and test reset in Supabase.`;
    button.disabled = false;
    return;
  }
  message.textContent = "Pot status saved.";
  await loadPots();
}
async function resetTestPot(pot, button) {
  button.disabled = true;
  message.textContent = `Resetting all test progress for ${pot.name}…`;
  const { error } = await supabase.rpc("reset_draft_test_pot", {
    selected_pot_id: pot.id,
  });
  if (error) {
    message.textContent = `${error.message}. Run 18 — Tournament lifecycle, history and test reset in Supabase.`;
    button.disabled = false;
    return;
  }
  message.textContent = `${pot.name} is back at round one. Payments and assigned players were kept.`;
  await loadPots();
}
async function completePot(pot, winnerId, button) {
  button.disabled = true;
  message.textContent = `Completing ${pot.name}…`;
  const { error } = await supabase.rpc("complete_pot_with_winner", {
    selected_pot_id: pot.id,
    selected_winner_id: winnerId,
  });
  if (error) {
    message.textContent = `${error.message}. Run 18 — Tournament lifecycle, history and test reset in Supabase.`;
    button.disabled = false;
    return;
  }
  message.textContent = `${pot.name} is complete and the winner is recorded.`;
  await loadPots();
}
function fixtureTeam(team, isAway = false) {
  const wrapper = document.createElement("div");
  wrapper.className = `fixture-team${isAway ? " away" : ""}`;
  const image = addImage(wrapper, team.emblem_url);
  const name = document.createElement("span");
  name.textContent = team.short_name;
  wrapper.replaceChildren(...(isAway ? [name, image] : [image, name]));
  return wrapper;
}
function renderFixtures(fixtures, teams) {
  fixtureList.replaceChildren();
  playerCount.textContent = fixtures.length;
  countLabel.textContent = fixtures.length === 1 ? "fixture" : "fixtures";
  if (!fixtures.length) {
    const empty = document.createElement("p");
    empty.className = "fixture-empty";
    empty.textContent = "No fixtures imported yet. Use Sync FPL data above.";
    fixtureList.append(empty);
    return;
  }
  const teamMap = new Map(teams.map((team) => [team.id, team]));
  fixtures.slice(0, 30).forEach((fixture) => {
    const home = teamMap.get(fixture.home_team_id),
      away = teamMap.get(fixture.away_team_id);
    if (!home || !away) return;
    const row = document.createElement("article");
    row.className = "fixture-row";
    const gameweek = document.createElement("span");
    gameweek.className = "fixture-gameweek";
    gameweek.textContent = fixture.gameweek_number
      ? `GW${fixture.gameweek_number}`
      : "TBC";
    const score = document.createElement("strong");
    score.className = "fixture-score";
    score.textContent = fixture.finished
      ? `${fixture.home_score} – ${fixture.away_score}`
      : "v";
    const time = document.createElement("time");
    time.className = "fixture-time";
    if (fixture.kickoff_at) {
      const kickoff = new Date(fixture.kickoff_at);
      time.dateTime = fixture.kickoff_at;
      time.textContent = kickoff.toLocaleString("en-GB", {
        weekday: "short",
        day: "numeric",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      });
    } else time.textContent = "Time TBC";
    row.append(
      gameweek,
      fixtureTeam(home),
      score,
      fixtureTeam(away, true),
      time,
    );
    fixtureList.append(row);
  });
}
async function loadFixtures() {
  message.textContent = "Loading fixtures…";
  const [fixturesResult, teamsResult] = await Promise.all([
    supabase
      .from("football_fixtures")
      .select("*")
      .eq("season", CURRENT_SEASON)
      .order("kickoff_at", { ascending: true, nullsFirst: false }),
    supabase.from("football_teams").select("id,name,short_name,emblem_url"),
  ]);
  const error = fixturesResult.error || teamsResult.error;
  if (error) {
    message.textContent = `Couldn’t load fixtures: ${error.message}. Run 09 — FPL clubs and fixture import in Supabase.`;
    fixtureList.replaceChildren();
    return;
  }
  message.textContent = "";
  fixtureSyncDetail.textContent = fixturesResult.data.length
    ? `${fixturesResult.data.length} fixtures saved for ${CURRENT_SEASON}. The list below shows the first 30.`
    : "No football data has been synced yet.";
  renderFixtures(fixturesResult.data, teamsResult.data);
}
async function syncFplData() {
  syncFplButton.disabled = true;
  message.textContent = "Downloading the latest FPL clubs and fixtures…";
  try {
    const fplResponse = await fetch("/api/fpl");
    const fpl = await fplResponse.json();
    if (!fplResponse.ok)
      throw new Error(
        fpl.error || "The FPL feed did not respond. Try again shortly.",
      );
    const { data, error } = await supabase.rpc("sync_fpl_data", {
      selected_season: CURRENT_SEASON,
      fpl_teams: fpl.teams,
      fpl_fixtures: fpl.fixtures,
    });
    if (error) throw error;
    message.textContent = `FPL sync complete: ${data.teams} clubs and ${data.fixtures} fixtures updated.`;
    await loadFixtures();
  } catch (error) {
    message.textContent = `Couldn’t sync FPL data: ${error.message}`;
  } finally {
    syncFplButton.disabled = false;
  }
}
function renderAdminPicks(data) {
  adminPickList.replaceChildren();
  const players = data?.players || [],
    picked = players.filter((player) => player.pick);
  testModeToggle.dataset.enabled = String(Boolean(data?.test_mode));
  testModeToggle.textContent = data?.test_mode
    ? "Disable test mode"
    : "Enable test mode";
  testModeToggle.disabled = data?.pot_status !== "draft";
  testModeNote.hidden = !data?.test_mode;
  pickSummary.replaceChildren();
  [
    ["Players", players.length],
    ["Locked in", picked.length],
    ["No pick", players.length - picked.length],
  ].forEach(([label, value]) => renderMetric(pickSummary, label, value));
  playerCount.textContent = picked.length;
  countLabel.textContent = "locked picks";
  if (!players.length) {
    addText(
      adminPickList,
      "p",
      "No players are assigned to this pot.",
      "empty-list",
    );
    return;
  }
  players.forEach((player) => {
    const row = document.createElement("article");
    row.className = `admin-pick-row ${player.pick ? "has-pick" : "missing-pick"}`;
    const identity = document.createElement("div");
    identity.className = "admin-pick-player";
    renderAdminPickIdentity(identity, player);
    const choice = document.createElement("div");
    choice.className = "admin-pick-choice";
    if (player.pick) {
      addImage(choice, player.pick.emblem_url);
      const details = document.createElement("span");
      const kickoff = new Date(player.pick.kickoff_at).toLocaleString("en-GB", {
        weekday: "short",
        day: "numeric",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      });
      addText(details, "strong", player.pick.team_name);
      addText(
        details,
        "small",
        `${player.pick.home_name} v ${player.pick.away_name} · ${kickoff}`,
      );
      choice.append(details);
    } else {
      addText(choice, "strong", "Awaiting pick");
      addText(choice, "small", "No team has been locked in");
    }
    const controls = document.createElement("div");
    controls.className = "admin-pick-controls";
    const badges = document.createElement("div");
    badges.className = "admin-pick-badges";
    if (player.pick) {
      const shownOutcome = player.pick.preview_outcome || player.pick.outcome;
      addText(badges, "span", player.pick.selection_source, "pick-source");
      addText(
        badges,
        "span",
        `${data.test_mode ? "Preview: " : ""}${shownOutcome}`,
        `pick-outcome ${shownOutcome}`,
      );
      if (data.test_mode) {
        const scenario = document.createElement("select");
        scenario.className = "test-scenario";
        scenario.setAttribute("aria-label", `Test result for ${player.name}`);
        [
          ["", "Set test result"],
          ["won", "Selected team wins"],
          ["drawn", "Draw"],
          ["lost", "Selected team loses"],
          ["postponed", "Postponed"],
        ].forEach(([value, label]) => {
          const option = document.createElement("option");
          option.value = value;
          option.textContent = label;
          scenario.append(option);
        });
        scenario.addEventListener("change", () =>
          setTestScenario(player.pick.id, scenario),
        );
        controls.append(scenario);
      }
    } else addText(badges, "span", "Missing", "pick-outcome missing");
    controls.prepend(badges);
    row.append(identity, choice, controls);
    adminPickList.append(row);
  });
}
async function setTestScenario(pickId, select) {
  if (!select.value) return;
  select.disabled = true;
  message.textContent = "Saving the simulated result…";
  const { error } = await supabase.rpc("set_test_pick_scenario", {
    selected_pot_id: pickPot.value,
    selected_pick_id: pickId,
    scenario: select.value,
  });
  if (error) {
    message.textContent = error.message;
    select.disabled = false;
    return;
  }
  message.textContent =
    "Test result saved. This has not changed the FPL fixture.";
  await loadAdminPicks();
}
async function toggleTestMode() {
  testModeToggle.disabled = true;
  const enabled = testModeToggle.dataset.enabled !== "true";
  message.textContent = `${enabled ? "Enabling" : "Disabling"} test mode…`;
  const { error } = await supabase.rpc("set_pot_test_mode", {
    selected_pot_id: pickPot.value,
    enabled,
  });
  if (error) {
    message.textContent = `${error.message}. Run 12 — Draft pot result testing in Supabase.`;
    testModeToggle.disabled = false;
    return;
  }
  message.textContent = enabled
    ? "Test mode enabled for this draft pot."
    : "Test mode disabled. Saved simulations were cleared.";
  await loadAdminPicks();
}
function renderAdminDeadline(data) {
  const deadline = data?.deadline ? new Date(data.deadline) : null;
  pickDeadline.hidden = !deadline;
  pickDeadline.className = `pick-deadline${data?.deadline_passed ? " passed" : ""}`;
  pickDeadline.replaceChildren();
  if (deadline) {
    addText(
      pickDeadline,
      "strong",
      data.deadline_passed ? "Deadline passed" : "Pick deadline",
    );
    addText(
      pickDeadline,
      "span",
      `${deadline.toLocaleString("en-GB", { weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" })}${data.test_mode ? " · test mode override active" : ""}`,
    );
  }
  randomPickButton.disabled = !data?.test_mode && !data?.deadline_passed;
  randomPickButton.title = randomPickButton.disabled
    ? "Random picks unlock after the first gameweek fixture begins"
    : "";
}
async function loadAdminPicks() {
  if (!pickPot.value || !pickGameweek.value) return;
  message.textContent = "Loading locked selections…";
  const [overview, deadline] = await Promise.all([
    supabase.rpc("get_admin_pick_overview", {
      selected_pot_id: pickPot.value,
      selected_gameweek: Number(pickGameweek.value),
    }),
    supabase.rpc("get_gameweek_deadline", {
      selected_pot_id: pickPot.value,
      selected_gameweek: Number(pickGameweek.value),
    }),
  ]);
  const error = overview.error || deadline.error;
  if (error) {
    message.textContent = `Couldn’t load selections: ${error.message}. Run 20 — Pick deadlines and random assignment audit in Supabase.`;
    adminPickList.replaceChildren();
    return;
  }
  message.textContent = "";
  renderAdminPicks(overview.data);
  renderAdminDeadline(deadline.data);
}
async function loadPickFilters() {
  message.textContent = "Loading pots…";
  const [potsResult, weeksResult] = await Promise.all([
    supabase
      .from("pots")
      .select("id,name,season,status")
      .order("created_at", { ascending: false }),
    supabase.from("pot_gameweeks").select("pot_id,gameweek_number"),
  ]);
  const error = potsResult.error || weeksResult.error;
  if (error) {
    message.textContent = `Couldn’t load pots: ${error.message}`;
    return;
  }
  pickPot.replaceChildren();
  potsResult.data.forEach((pot) => {
    const option = document.createElement("option");
    option.value = pot.id;
    option.textContent = `${pot.name} · ${pot.season}`;
    pickPot.append(option);
  });
  const updateWeeks = () => {
    pickGameweek.replaceChildren();
    weeksResult.data
      .filter((week) => week.pot_id === pickPot.value)
      .sort((a, b) => a.gameweek_number - b.gameweek_number)
      .forEach((week) => {
        const option = document.createElement("option");
        option.value = week.gameweek_number;
        option.textContent = `GW${week.gameweek_number}`;
        pickGameweek.append(option);
      });
    loadAdminPicks();
  };
  pickPot.onchange = updateWeeks;
  pickGameweek.onchange = loadAdminPicks;
  if (potsResult.data.length) updateWeeks();
  else {
    message.textContent = "Create a pot before reviewing selections.";
    adminPickList.replaceChildren();
  }
}
function renderStandings(data) {
  standingsBoard.replaceChildren();
  standingsSummary.replaceChildren();
  const players = data?.players || [],
    gameweeks = data?.gameweeks || [],
    active = players.filter(
      (player) => player.player_status === "active",
    ).length;
  [
    ["Players", players.length],
    ["Still standing", active],
    [
      "Eliminated",
      players.filter((player) => player.player_status === "eliminated").length,
    ],
  ].forEach(([label, value]) => renderMetric(standingsSummary, label, value));
  playerCount.textContent = players.length;
  countLabel.textContent = players.length === 1 ? "player" : "players";
  if (!players.length) {
    addText(
      standingsBoard,
      "p",
      "No players are assigned to this pot.",
      "standings-empty",
    );
    return;
  }
  const table = document.createElement("table");
  table.className = "standings-table";
  const head = document.createElement("thead"),
    headRow = document.createElement("tr"),
    playerHead = document.createElement("th");
  playerHead.className = "standings-player";
  playerHead.textContent = "Player";
  headRow.append(playerHead);
  gameweeks.forEach((gameweek) => {
    const th = document.createElement("th");
    th.textContent = `GW${gameweek}`;
    headRow.append(th);
  });
  head.append(headRow);
  const body = document.createElement("tbody");
  players.forEach((player) => {
    const row = document.createElement("tr"),
      identity = document.createElement("td");
    identity.className = "standings-player";
    renderIdentity(
      identity,
      player.name,
      `${paymentLabel(player.payment_status)} · Buy-back ${player.buy_back_status}`,
      player.player_status,
    );
    row.append(identity);
    const pickMap = new Map(
      (player.picks || []).map((pick) => [pick.gameweek_number, pick]),
    );
    let eliminated = false;
    gameweeks.forEach((gameweek) => {
      const cell = document.createElement("td"),
        pick = pickMap.get(gameweek);
      cell.className = "standings-cell";
      if (pick) {
        cell.classList.add(pick.outcome);
        renderStandingPick(cell, pick, true);
        if (pick.outcome === "lost") eliminated = true;
      } else if (
        eliminated ||
        (player.player_status === "eliminated" &&
          [...(player.picks || [])].some(
            (item) =>
              item.outcome === "lost" && item.gameweek_number < gameweek,
          ))
      ) {
        cell.classList.add("after-elimination");
        cell.textContent = "×";
      } else {
        cell.classList.add("empty");
        cell.textContent = "—";
      }
      row.append(cell);
    });
    body.append(row);
  });
  table.append(head, body);
  standingsBoard.append(table);
}
async function loadStandings() {
  if (!standingsPot.value) return;
  message.textContent = "Loading standings…";
  const { data, error } = await supabase.rpc("get_pot_standings", {
    selected_pot_id: standingsPot.value,
  });
  if (error) {
    message.textContent = `Couldn’t load standings: ${error.message}. Run 19 — Pot standings board in Supabase.`;
    standingsBoard.replaceChildren();
    return;
  }
  message.textContent = "";
  renderStandings(data);
}
async function loadStandingsFilters() {
  message.textContent = "Loading pots…";
  const { data, error } = await supabase
    .from("pots")
    .select("id,name,season")
    .order("created_at", { ascending: false });
  if (error) {
    message.textContent = `Couldn’t load pots: ${error.message}`;
    return;
  }
  standingsPot.replaceChildren();
  data.forEach((pot) => {
    const option = document.createElement("option");
    option.value = pot.id;
    option.textContent = `${pot.name} · ${pot.season}`;
    standingsPot.append(option);
  });
  standingsPot.onchange = loadStandings;
  if (data.length) loadStandings();
  else {
    message.textContent = "Create a pot before viewing standings.";
    standingsBoard.replaceChildren();
  }
}
function switchView(view) {
  playersView.hidden = view !== "players";
  potsView.hidden = view !== "pots";
  fixturesView.hidden = view !== "fixtures";
  picksView.hidden = view !== "picks";
  standingsView.hidden = view !== "standings";
  adminTitle.textContent =
    view === "pots"
      ? "Pots"
      : view === "fixtures"
        ? "Fixtures"
        : view === "picks"
          ? "Picks"
          : view === "standings"
            ? "Standings"
            : "Players";
  document
    .querySelectorAll(".admin-tab")
    .forEach((tab) =>
      tab.classList.toggle("active", tab.dataset.view === view),
    );
  if (view === "pots") {
    renderPotPlayerOptions();
    loadPots();
  } else if (view === "fixtures") loadFixtures();
  else if (view === "picks") loadPickFilters();
  else if (view === "standings") loadStandingsFilters();
  else {
    playerCount.textContent = allPlayers.length;
    countLabel.textContent = "registered";
  }
}
async function initialise() {
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (!session) {
    window.location.replace("/");
    return;
  }
  const { data: isAdmin, error } = await supabase.rpc("is_current_user_admin");
  if (error) {
    loading.hidden = true;
    denied.hidden = false;
    denied.querySelector(".intro").textContent =
      `Admin check failed: ${error.message}`;
    return;
  }
  if (!isAdmin) {
    showDenied();
    return;
  }
  loading.hidden = true;
  content.hidden = false;
  const { data, error: playersError } = await supabase
    .from("profiles")
    .select(
      "id,email,display_name,first_name,last_name,approved,is_admin,created_at",
    )
    .order("created_at", { ascending: false });
  if (playersError) {
    message.textContent = `Couldn’t load players: ${playersError.message}`;
    return;
  }
  allPlayers = data;
  renderPlayers(allPlayers);
  buildGameweekGrid();
}
document
  .querySelectorAll(".admin-tab")
  .forEach((tab) =>
    tab.addEventListener("click", () => switchView(tab.dataset.view)),
  );
showPotFormButton.addEventListener("click", () => {
  potForm.hidden = false;
  showPotFormButton.hidden = true;
  potForm.querySelector("input").focus();
});
cancelPotButton.addEventListener("click", () => {
  potForm.hidden = true;
  showPotFormButton.hidden = false;
});
potForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const submit = potForm.querySelector("button[type='submit']"),
    data = new FormData(potForm),
    startGameweek = Number(data.get("startGameweek")),
    playerIds = data.getAll("playerIds");
  if (!startGameweek) {
    message.textContent = "Select the starting gameweek.";
    return;
  }
  if (!playerIds.length) {
    message.textContent = "Assign at least one approved player.";
    return;
  }
  const gameweeks = Array.from(
    { length: 39 - startGameweek },
    (_, index) => startGameweek + index,
  );
  submit.disabled = true;
  message.textContent = "Creating the pot…";
  const poundsToPence = (value) => Math.round(Number(value) * 100);
  const { error } = await supabase.rpc("create_pot", {
    pot_name: data.get("potName"),
    pot_season: data.get("season"),
    entry_fee_pence: poundsToPence(data.get("entryFee")),
    buy_back_fee_pence: poundsToPence(data.get("buyBackFee")),
    gameweek_numbers: gameweeks,
    player_ids: playerIds,
  });
  submit.disabled = false;
  if (error) {
    message.textContent = error.message;
    return;
  }
  potForm.reset();
  potForm.querySelector("[name='season']").value = "2026/27";
  potForm.querySelector("[name='entryFee']").value = "10";
  potForm.querySelector("[name='buyBackFee']").value = "10";
  potForm.hidden = true;
  showPotFormButton.hidden = false;
  message.textContent = "Draft pot created with every gameweek through GW38.";
  await loadPots();
});
signOutButton.addEventListener("click", async () => {
  signOutButton.disabled = true;
  await supabase.auth.signOut();
  window.location.replace("/");
});
initialise();
syncFplButton.addEventListener("click", syncFplData);
testModeToggle.addEventListener("click", toggleTestMode);
