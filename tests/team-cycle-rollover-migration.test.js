import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  new URL("../supabase/migrations/20260824000800_lms_phase_2k_team_cycle_rollover.sql", import.meta.url),
  "utf8",
);
const verification = readFileSync(
  new URL("../supabase/verification/lms_phase_2k_team_cycle_rollover_verification.sql", import.meta.url),
  "utf8",
);
const phase2c = readFileSync(
  new URL("../supabase/migrations/20260823000400_lms_phase_2c_team_cycles.sql", import.meta.url),
  "utf8",
);
const cycleDocumentation = readFileSync(new URL("../PHASE_2C_TEAM_CYCLES.md", import.meta.url), "utf8");

const ROLLOVER_HELPERS = [
  "pot_eligible_team_count",
  "team_cycle_is_exhausted",
  "active_team_cycle_id",
  "ensure_current_team_cycle",
  "link_pick_to_team_cycle",
  "roll_team_cycle_after_pick",
];

function functionBody(name) {
  const match = migration.match(new RegExp(`create or replace function public\\.${name}\\b([\\s\\S]*?)\\$\\$;`, "i"));
  expect(match, `${name} should exist`).not.toBeNull();
  return match[0];
}

describe("Phase 2K team-cycle rollover migration", () => {
  it("is a forward-only migration that leaves Phase 2C in place", () => {
    expect(migration.trimStart()).toMatch(/^-- Phase 2K: reset a player's team pool/);
    expect(migration).toMatch(/\bbegin\s*;/i);
    expect(migration).toMatch(/\bcommit\s*;/i);
    expect(migration).not.toMatch(/drop table\s+public\.pot_player_team_cycles/i);
    expect(migration).not.toMatch(/drop index[^;]*pot_player_team_cycles_one_active/i);
    expect(migration).not.toMatch(/delete from public\.pot_player_team_cycles/i);
    // Phase 2C stays untouched on disk: this migration must not have edited history.
    expect(phase2c).toContain("create unique index pot_player_team_cycles_one_active");
  });

  it("keeps every rollover helper hardened and unreachable from the client roles", () => {
    for (const name of ROLLOVER_HELPERS) {
      const body = functionBody(name);
      expect(body, `${name} should be SECURITY DEFINER with an empty search_path`).toMatch(
        /security definer set search_path\s*=\s*''/i,
      );
      expect(migration).toMatch(new RegExp(`revoke all on function public\\.${name}\\b[^;]*from public,anon,authenticated`, "i"));
    }
    expect(migration).not.toMatch(/grant execute on function public\.(ensure_current_team_cycle|active_team_cycle_id)/i);
    expect(migration).toMatch(/must not be directly executable/i);
  });

  it("gives rollover a single owner that both pick paths reach through the insert trigger", () => {
    const linker = functionBody("link_pick_to_team_cycle");
    expect(linker).toContain("public.ensure_current_team_cycle(new.pot_id,new.player_id)");
    expect(linker).not.toContain("public.current_team_cycle_id(");

    const roller = functionBody("roll_team_cycle_after_pick");
    expect(roller).toContain("public.ensure_current_team_cycle(new.pot_id,new.player_id)");

    // Only ensure_current_team_cycle may write the cycle table.
    const writers = [...migration.matchAll(/create or replace function public\.(\w+)\b([\s\S]*?)\$\$;/gi)]
      .filter(([, , body]) => /insert into public\.pot_player_team_cycles|update public\.pot_player_team_cycles/i.test(body))
      .map(([, name]) => name);
    expect(writers).toEqual(["ensure_current_team_cycle"]);
  });

  it("closes the exhausted cycle and opens exactly the next number", () => {
    const owner = functionBody("ensure_current_team_cycle");
    expect(owner).toMatch(/closed_at\s*=\s*now\(\)/i);
    expect(owner).toContain("open_cycle.cycle_number+1");
    expect(owner).toMatch(/closed_at is null/i);
    expect(owner).toMatch(/for update/i);
    expect(owner).toMatch(/pg_advisory_xact_lock/i);
    // A non-exhausted cycle is returned untouched, which is what makes repeat calls safe.
    expect(owner).toContain("if not public.team_cycle_is_exhausted(open_cycle.id) then return open_cycle.id; end if;");
    expect(owner).toContain("Player has no active team-use cycle");
  });

  it("measures exhaustion against the pot's own season rather than a hardcoded twenty", () => {
    const universe = functionBody("pot_eligible_team_count");
    expect(universe).toContain("pot.season=fixture.season");
    expect(migration).not.toMatch(/>=\s*20\b/);

    const exhausted = functionBody("team_cycle_is_exhausted");
    expect(exhausted).toContain("count(distinct pick.team_id)");
    // An empty universe must never read as exhausted, or a pot would roll cycles forever.
    expect(exhausted).toMatch(/when universe\.count_value<=0 then false/i);
  });

  it("routes every eligibility filter at the rollover-aware helper", () => {
    for (const target of [
      "public.confirm_team_pick(uuid,bigint,bigint)",
      "public.assign_random_missing_picks(uuid,integer,boolean)",
      "public.get_pot_selection(uuid)",
      "public.get_my_team_availability(uuid)",
    ]) {
      expect(migration).toContain(`'${target}'`);
    }
    expect(migration).toContain("replace(definition,'public.current_team_cycle_id(','public.active_team_cycle_id(')");
    // The rewrite must fail closed if a baseline ever stops matching.
    expect(migration).toMatch(/raise exception 'Expected % to filter used teams by the current team cycle'/);
    expect(migration).toMatch(/raise exception 'Unreplaced team-cycle reference remains in %'/);
  });

  it("asserts its own postconditions before committing", () => {
    expect(migration).toMatch(/must keep SECURITY DEFINER and an empty search_path/i);
    expect(migration).toMatch(/Team-cycle rollover trigger is missing/i);
    expect(migration).toMatch(/requires the single-open-cycle unique index/i);
    expect(migration).toMatch(/requires the unique cycle number constraint/i);
  });
});

describe("Phase 2K team-cycle rollover verification", () => {
  it("proves exhaustion through the real domain functions rather than seeded cycles", () => {
    expect(verification).toContain("public.confirm_team_pick(");
    expect(verification).toContain("public.process_pot_gameweek(");
    expect(verification).toContain("public.assign_random_missing_picks(");
    // Cycle rows must never be manufactured to fake exhaustion. The single insert the
    // script performs is the negative test that a second open cycle is refused.
    const cycleInserts = [...verification.matchAll(/insert into public\.pot_player_team_cycles/gi)];
    expect(cycleInserts).toHaveLength(1);
    expect(verification).toContain("raise exception 'A second open cycle was accepted'");
    expect(verification).not.toMatch(/update public\.pot_player_team_cycles/i);
    expect(verification.trimEnd().endsWith("rollback;")).toBe(true);
  });

  it("covers the required rollover scenarios", () => {
    const expectations = [
      "Every player must start in cycle 1 only",
      "No rollover may occur before the pool is exhausted (gameweek 19)",
      "Cycle 1 must close once all 20 teams are used",
      "Cycle 2 must open when cycle 1 closes",
      "Exactly one next cycle may be created",
      "Cycle 1 must retain all 20 historical picks",
      "All 20 teams must be available again in cycle 2",
      "The pick after reset must belong to cycle 2",
      "A cycle-1 team must be selectable again in cycle 2",
      "Buy-back must not open a new cycle",
      "Buy-back must preserve the three teams already used",
      "Player B must remain in a single open cycle 1",
      "Random assignment must succeed after a pool reset",
      "Assigned pick must be marked random",
      "Randomly assigned pick must belong to cycle 2",
      "Repeated rollover calls created cycles",
      "Automation failed after a pool reset",
      "Exhaustion opened a progression_failure review case",
      "Expected three cycles after two exhaustions",
      "Team-cycle helpers must not be callable by players",
      "Players must not be able to write team cycles",
    ];
    for (const message of expectations) {
      expect(verification, `missing assertion: ${message}`).toContain(message);
    }
  });

  it("documents the rule where the cycle model is described", () => {
    expect(cycleDocumentation).toMatch(/a cycle closes as soon as its pool is exhausted/i);
    expect(cycleDocumentation).toMatch(/next numbered cycle opens/i);
    expect(cycleDocumentation).toMatch(/remain immutable/i);
    expect(cycleDocumentation).toMatch(/per player and per pot/i);
    // The stale "no automatic Cycle 2 transition" scope note must be gone.
    expect(cycleDocumentation).not.toMatch(/No automatic Cycle 2 transition/i);
  });
});
