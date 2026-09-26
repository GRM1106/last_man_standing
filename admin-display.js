// Match the permanent membership lock, including a deadline not yet persisted as a lock.
export function membershipClosed(pot, gameweeks, now = Date.now()) {
  return Boolean(pot.membership_locked_at) || !["setup", "open"].includes(pot.lifecycle_status)
    || gameweeks.some(week => week.pot_id === pot.id && week.pick_deadline_at
      && new Date(week.pick_deadline_at).getTime() <= now);
}

// A historical loss does not override current eligibility after re-entry.
// For earlier gaps, use the latest preceding pick rather than a sticky loss flag.
export function standingGap(player, gameweek, currentGameweek) {
  if (gameweek >= currentGameweek && ["active", "winner"].includes(player.player_status)) return "empty";
  const previous = (player.picks || []).filter(pick => pick.gameweek_number < gameweek)
    .sort((a, b) => b.gameweek_number - a.gameweek_number)[0];
  return previous?.outcome === "lost" ? "eliminated" : "empty";
}

export function playerName(player) {
  const name = [player.first_name, player.last_name].filter(Boolean).join(" ").trim();
  const nickname = String(player.display_name || "").trim();
  return name || (nickname.toLowerCase() !== String(player.email || "").trim().toLowerCase() ? nickname : "") || "Player";
}
