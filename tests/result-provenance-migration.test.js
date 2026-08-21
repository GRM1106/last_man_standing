import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(new URL("../supabase/result_provenance_foundation.sql", import.meta.url), "utf8");
const verification = readFileSync(new URL("../supabase/result_provenance_foundation_verification.sql", import.meta.url), "utf8");
const seed = readFileSync(new URL("../supabase/result_provenance_pre_migration_seed.sql", import.meta.url), "utf8");
const preflight = readFileSync(new URL("../supabase/result_provenance_preflight.sql", import.meta.url), "utf8");
const failureSeed = readFileSync(new URL("../supabase/result_provenance_failure_seed.sql", import.meta.url), "utf8");
const failureVerification = readFileSync(new URL("../supabase/result_provenance_failure_verification.sql", import.meta.url), "utf8");

describe("Phase P1 result-provenance migration", () => {
  it("uses season-scoped provider identities and synchronization joins", () => {
    expect(migration).toMatch(/unique\s*\(season\s*,\s*fpl_team_id\)/i);
    expect(migration).toMatch(/unique\s*\(season\s*,\s*fpl_fixture_id\)/i);
    expect(migration).toMatch(/on conflict\s*\(season\s*,\s*fpl_team_id\)/i);
    expect(migration).toMatch(/on conflict\s*\(season\s*,\s*fpl_fixture_id\)/i);
    expect(migration).toMatch(/home\.season\s*=\s*normalized_season/i);
    expect(migration).toMatch(/away\.season\s*=\s*normalized_season/i);
    expect(migration).toMatch(/pot\.season\s*=\s*team\.season/i);
    expect(migration).not.toMatch(/on conflict\s*\(fpl_(?:team|fixture)_id\)/i);
  });

  it("adds constrained provider status and immutable pick provenance", () => {
    for (const status of ["scheduled", "live", "finished", "postponed", "abandoned", "void"]) {
      expect(migration).toContain(`'${status}'`);
    }
    for (const column of [
      "resolved_home_team_id", "resolved_away_team_id", "resolved_home_score",
      "resolved_away_score", "result_source", "resolved_at",
      "resolved_fixture_season", "resolved_fixture_status"
    ]) {
      expect(migration).toContain(column);
    }
    expect(migration).toMatch(/'survived'/);
    expect(migration).toMatch(/Resolved pick provenance is immutable/);
  });

  it("creates locked-down append-only audit tables", () => {
    for (const table of ["fixture_result_overrides", "admin_audit_events", "pot_player_status_history"]) {
      expect(migration).toMatch(new RegExp(`create table if not exists public\\.${table}`));
      expect(migration).toMatch(new RegExp(`alter table public\\.${table} enable row level security`));
    }
    expect(migration).toMatch(/revoke all on table public\.fixture_result_overrides,public\.admin_audit_events,public\.pot_player_status_history from public,authenticated/i);
    expect(migration).toMatch(/before update or delete/i);
    expect(migration).not.toMatch(/create policy/i);
  });

  it("does not redefine current processing or game-rule functions", () => {
    for (const functionName of [
      "process_pot_gameweek", "reset_test_gameweek", "claim_buy_back",
      "set_buy_back_decision", "complete_pot_with_winner"
    ]) {
      expect(migration).not.toMatch(new RegExp(`create or replace function public\\.${functionName}\\b`, "i"));
    }
  });

  it("ships a rollback-only database verification script", () => {
    expect(verification.trimStart()).toMatch(/^-- Phase P1 database verification/);
    expect(verification).toMatch(/\bbegin\s*;/i);
    expect(verification).toMatch(/\brollback\s*;/i);
    expect(verification).toContain("Season-B synchronization modified the season-A fixture");
    expect(verification).toContain("Normal legacy result backfill is incorrect");
    expect(verification).toContain("Authenticated audit insert was accepted");
    expect(verification).toMatch(/set local role anon/i);
    expect(verification).toContain("Anon audit insert was accepted");
  });

  it("ships a committed pre-migration fixture that exercises the actual backfill", () => {
    expect(seed).toMatch(/\bcommit\s*;/i);
    expect(seed).toContain("P1-SEED-2030");
    for (const pickId of ["-26101", "-26102", "-26103", "-26104", "-26105"]) {
      expect(seed).toContain(pickId);
      expect(verification).toContain(pickId);
    }
    expect(seed).not.toContain("resolved_home_team_id");
    expect(verification).toContain("Incomplete legacy result was not left safely unresolved");
    expect(verification).toContain("Pending legacy pick was incorrectly resolved");
    expect(migration).toContain("unresolved_score_rows");
    expect(migration).toMatch(/unresolved_score_rows[\s\S]*?home_score[\s\S]*?is null\s+or[\s\S]*?away_score[\s\S]*?is null/i);
  });

  it("documents Supabase prerequisites and supplies safe preflight and failure checks", () => {
    expect(verification).toMatch(/Supabase auth schema/i);
    expect(verification).toMatch(/Vanilla PostgreSQL is not[\s-]+sufficient/i);
    expect(preflight).toMatch(/Phase P1 read-only preflight/i);
    expect(preflight).not.toMatch(/\b(?:insert|update|delete|alter|drop|create)\b/i);
    expect(failureSeed).toMatch(/\bcommit\s*;/i);
    expect(failureVerification).toContain("Failure-path rollback left football_teams.season behind");
    expect(failureVerification).toContain("Failure-path rollback did not restore the original global fixture constraint");
  });
});
