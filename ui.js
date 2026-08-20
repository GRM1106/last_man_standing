const SAFE_IMAGE_ORIGINS = new Set([
  window.location.origin,
  "https://resources.premierleague.com"
]);

export function addText(parent, tag, value, className = "") {
  const element = document.createElement(tag);
  if (className) element.className = className;
  element.textContent = value == null ? "" : String(value);
  parent.append(element);
  return element;
}

export function safeImageUrl(value) {
  if (!value) return "";
  try {
    const url = new URL(value, window.location.origin);
    return url.protocol === "https:" && SAFE_IMAGE_ORIGINS.has(url.origin) ? url.href : "";
  } catch {
    return "";
  }
}

export function addImage(parent, value, className = "") {
  const image = document.createElement("img");
  if (className) image.className = className;
  const safeUrl = safeImageUrl(value);
  if (safeUrl) image.src = safeUrl;
  image.alt = "";
  parent.append(image);
  return image;
}

export function renderMetric(parent, label, value) {
  const item = document.createElement("div");
  addText(item, "span", label);
  addText(item, "strong", value);
  parent.append(item);
  return item;
}

export function renderIdentity(parent, name, detail, status, includeDetail = true) {
  addText(parent, "strong", name);
  if (includeDetail && detail != null) addText(parent, "small", detail);
  if (status) addText(parent, "span", status, `standings-status ${status}`);
}

export function renderAdminPickIdentity(parent, player) {
  renderIdentity(parent, player.name, player.email);
}

export function renderPlayerStandingIdentity(parent, player) {
  renderIdentity(parent, player.name, null, player.player_status, false);
}

export function renderStandingPick(cell, pick, showSource = false) {
  const wrapper = document.createElement("div");
  wrapper.className = "standings-pick";
  addImage(wrapper, pick.emblem_url);
  const name = addText(wrapper, "span", pick.short_name || pick.team_name);
  name.title = String(pick.team_name || "");
  if (showSource) {
    const source = pick.selection_source === "random" ? "R" : pick.selection_source === "admin" ? "A" : "";
    if (source) {
      const badge = addText(wrapper, "b", source, "standings-source");
      badge.title = `${pick.selection_source} pick`;
    }
  }
  cell.append(wrapper);
  addText(cell, "small", pick.outcome, "standings-result");
}
