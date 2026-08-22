import { addImage, addText } from "./ui.js";

export function resultScore(result) {
  return result?.home_score == null || result?.away_score == null
    ? "No score"
    : `${result.home_score} – ${result.away_score}`;
}

const expectedCorrectionErrors = new Map([
  ["A correction reason is required", "Enter a reason for this correction."],
  ["Scores cannot be negative", "Scores cannot be negative."],
  ["Both scores must be supplied together", "Enter both scores or leave both blank."],
  ["Finished fixtures require both scores", "A finished result requires both scores."],
  ["The proposed correction does not change the effective result", "This correction does not change the effective result."],
  ["Unsupported fixture status transition", "That result status change is not permitted."],
  ["Administrators cannot set that fixture status", "That fixture status cannot be set manually."],
  ["Result changed; preview again", "The result or its impact changed. Preview the correction again."],
]);

export function correctionErrorMessage(error) {
  return expectedCorrectionErrors.get(error?.message) || "The correction could not be completed. Preview again or try later.";
}

export async function loadAdminFixtureResults(client, season) {
  const { data, error } = await client.rpc("get_admin_fixture_results", {
    selected_season: season,
  });
  if (error) return { fixtures: [], errorMessage: "Couldn’t load fixture results. Try again." };
  return { fixtures: Array.isArray(data) ? data : [], errorMessage: null };
}

export function filterAdminFixtures(fixtures, gameweek, search) {
  const query = String(search || "").trim().toLocaleLowerCase("en-GB");
  return fixtures.filter((fixture) => (!gameweek || fixture.gameweek_number === Number(gameweek)) && (!query ||
    [fixture.home_team?.name, fixture.home_team?.short_name, fixture.away_team?.name, fixture.away_team?.short_name]
      .some((value) => String(value || "").toLocaleLowerCase("en-GB").includes(query))));
}

function teamBlock(team, away = false) {
  const block = document.createElement("div");
  block.className = `fixture-team${away ? " away" : ""}`;
  const image = addImage(block, team?.emblem_url);
  const name = addText(block, "span", team?.short_name || team?.name || "Unknown");
  block.replaceChildren(...(away ? [name, image] : [image, name]));
  return block;
}

function resultBlock(label, result, className) {
  const block = document.createElement("div");
  block.className = `fixture-result-block ${className}`;
  addText(block, "span", label, "fixture-result-label");
  addText(block, "strong", resultScore(result));
  addText(block, "small", result?.status || "unknown");
  return block;
}

export function renderAdminFixtureResults(container, fixtures, onCorrect) {
  container.replaceChildren();
  if (!fixtures.length) {
    addText(container, "p", "No fixtures imported yet. Use Sync FPL data above.", "fixture-empty");
    return;
  }
  fixtures.forEach((fixture) => {
    const card = document.createElement("article");
    card.className = "fixture-result-card";
    const heading = document.createElement("div");
    heading.className = "fixture-result-heading";
    addText(heading, "span", fixture.gameweek_number ? `GW${fixture.gameweek_number}` : "TBC", "fixture-gameweek");
    const kickoff = document.createElement("time");
    kickoff.className = "fixture-time";
    if (fixture.kickoff_at) {
      kickoff.dateTime = fixture.kickoff_at;
      kickoff.textContent = new Date(fixture.kickoff_at).toLocaleString("en-GB", {
        weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit",
      });
    } else kickoff.textContent = "Time TBC";
    heading.append(kickoff);
    const matchup = document.createElement("div");
    matchup.className = "fixture-result-matchup";
    matchup.append(teamBlock(fixture.home_team), teamBlock(fixture.away_team, true));
    const comparison = document.createElement("div");
    comparison.className = "fixture-result-comparison";
    comparison.append(
      resultBlock("Provider raw", fixture.raw, "raw"),
      resultBlock("Effective", fixture.effective, fixture.effective?.override_id ? "overridden" : "provider"),
    );
    const footer = document.createElement("div");
    footer.className = "fixture-result-footer";
    const source = fixture.effective?.override_id
      ? `Authoritative override · ${fixture.effective.source}`
      : "Effective result follows provider raw data";
    addText(footer, "span", source, "fixture-result-source");
    if (fixture.overrides?.length) {
      addText(footer, "small", `${fixture.overrides.length} append-only correction${fixture.overrides.length === 1 ? "" : "s"}`);
    }
    const correct = document.createElement("button");
    correct.type = "button";
    correct.className = "fill-weeks-button";
    correct.textContent = fixture.effective?.override_id ? "Add superseding correction" : "Correct result";
    correct.addEventListener("click", () => onCorrect(fixture));
    footer.append(correct);
    card.append(heading, matchup, comparison, footer);
    container.append(card);
  });
}
