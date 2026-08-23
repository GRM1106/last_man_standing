import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(new URL("../supabase/migrations/20260823000100_lms_integrity_phase_1.sql", import.meta.url), "utf8");

describe("LMS Integrity Phase 1 migration guards", () => {
  it("is forward-only, transactional, and requires P1/P2", () => {
    expect(migration).toMatch(/^-- LMS Integrity Phase 1/m);
    expect(migration).toMatch(/begin;[\s\S]*commit;/);
    expect(migration).toContain("requires the complete P1 and P2 schema");
    expect(migration).toContain("has already been installed");
  });

  it("keeps resolved provenance immutable by deleting reset test picks", () => {
    expect(migration).toMatch(/create or replace function public\.reset_test_gameweek[\s\S]*delete from public\.player_picks where pot_id=selected_pot_id and gameweek_number=selected_gameweek/);
    expect(migration).not.toMatch(/set resolved_at=null/);
  });

  it("blocks dirty test disable and test winner completion", () => {
    expect(migration).toContain("Reset all test progress before disabling test mode");
    expect(migration).toContain("A pot in test mode cannot be completed");
    expect(migration).toContain("Only an active pot can be completed");
  });

  it("enforces the canonical current round", () => {
    expect(migration).toContain("current_gameweek:=public.current_pot_gameweek(selected_pot_id)");
    expect(migration).toContain("Selections are only accepted for the current gameweek");
    expect(migration).toContain("Random picks are only available for the current gameweek");
  });

  it("restricts random candidates to unstarted future fixtures", () => {
    const eligibility = /kickoff_at is not null and fixture\.kickoff_at>now\(\) and not fixture\.started and not fixture\.finished/g;
    expect(migration.match(eligibility)?.length).toBeGreaterThanOrEqual(4);
    expect(migration).toContain("No eligible unstarted fixture remains for random assignment");
  });

  it("persists deadlines and freezes them after closure", () => {
    expect(migration).toContain("add column pick_deadline_at timestamptz");
    expect(migration).toMatch(/pick_deadline_at is not null and gameweek\.pick_deadline_at<=now\(\)[\s\S]*then gameweek\.pick_deadline_at/);
  });

  it("snapshots and blocks changed fixture context", () => {
    for (const column of ["selected_fixture_gameweek", "selected_home_team_id", "selected_away_team_id", "selected_kickoff_at", "fixture_context_changed"])
      expect(migration).toContain(column);
    expect(migration).toContain("Referenced fixture context changed; administrator review is required before processing");
  });

  it("does not grant internal helpers to API roles", () => {
    expect(migration).toContain("revoke all on function public.current_pot_gameweek(uuid) from public");
    expect(migration).toContain("revoke all on function public.refresh_open_pot_gameweek_deadlines(text) from public");
    expect(migration).not.toMatch(/grant execute on function public\.(current_pot_gameweek|refresh_open_pot_gameweek_deadlines)/);
  });
});
