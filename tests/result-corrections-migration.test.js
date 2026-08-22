import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(new URL("../supabase/result_corrections.sql", import.meta.url), "utf8");
const verification = readFileSync(new URL("../supabase/result_corrections_verification.sql", import.meta.url), "utf8");
const concurrencyA = readFileSync(new URL("../supabase/result_corrections_concurrency_override_a.sql", import.meta.url), "utf8");
const concurrencyB = readFileSync(new URL("../supabase/result_corrections_concurrency_override_b.sql", import.meta.url), "utf8");
const processA = readFileSync(new URL("../supabase/result_corrections_concurrency_process_a.sql", import.meta.url), "utf8");
const syncB = readFileSync(new URL("../supabase/result_corrections_concurrency_sync_b.sql", import.meta.url), "utf8");
const processCorrectionA = readFileSync(new URL("../supabase/result_corrections_concurrency_process_correction_a.sql", import.meta.url), "utf8");
const processCorrectionB = readFileSync(new URL("../supabase/result_corrections_concurrency_process_correction_b.sql", import.meta.url), "utf8");
const concurrencyVerification = readFileSync(new URL("../supabase/result_corrections_concurrency_verification.sql", import.meta.url), "utf8");
const phaseDocumentation = readFileSync(new URL("../DOMAIN_PHASE_P2.md", import.meta.url), "utf8");

function functionBody(name) {
  const match = migration.match(new RegExp(`create or replace function public\\.${name}\\b([\\s\\S]*?)\\$\\$;`, "i"));
  expect(match, `${name} should exist`).not.toBeNull();
  return match[0];
}

describe("Domain Phase P2 controlled result corrections", () => {
  it("ships one forward-only final migration without rewriting P1", () => {
    expect(migration.trimStart()).toMatch(/^-- 24 — Controlled fixture-result corrections/);
    expect(migration).toMatch(/\bbegin\s*;/i);
    expect(migration).toMatch(/\bcommit\s*;/i);
    expect(migration).not.toMatch(/drop table\s+public\.(?:fixture_result_overrides|admin_audit_events)/i);
  });

  it("exposes only administrator-checked, hardened mutation and preview RPCs", () => {
    expect(migration).toMatch(/revoke all on table public\.fixture_result_overrides,public\.admin_audit_events,public\.pot_player_status_history\s+from public,anon,authenticated/i);
    for (const name of ["preview_fixture_result_override", "create_fixture_result_override"]) {
      const body = functionBody(name);
      expect(body).toMatch(/security definer set search_path\s*=\s*''/i);
      expect(body).toContain("Administrator access required");
      expect(migration).toMatch(new RegExp(`revoke all on function public\\.${name}`));
      expect(migration).toMatch(new RegExp(`grant execute on function public\\.${name}[\\s\\S]*?to authenticated`));
    }
    expect(functionBody("preview_fixture_result_override")).toMatch(/security definer/i);
    expect(functionBody("preview_fixture_result_override")).not.toMatch(/\b(?:insert|update|delete)\s+(?:into|from|public\.)/i);
  });

  it("preserves raw provider facts and selects the unsuperseded effective override", () => {
    const effective = functionBody("get_effective_fixture_result");
    expect(effective).toMatch(/not exists[\s\S]*?successor\.supersedes_id\s*=\s*candidate\.id/i);
    expect(effective).toContain("fixture.home_score");
    expect(effective).toContain("current_override.new_home_score");
    const sync = functionBody("sync_fpl_data");
    expect(sync).toMatch(/home_score\s*=\s*excluded\.home_score/i);
    expect(sync).not.toMatch(/(?:update|delete|insert into)\s+public\.fixture_result_overrides/i);
    expect(effective).toContain("not fixture.finished_provisional");
    expect(effective).toContain("processable");
  });

  it("enforces one same-fixture chain and a shared deterministic lock protocol", () => {
    expect(migration).toContain("fixture_result_overrides_one_root_per_fixture");
    expect(migration).toContain("fixture_result_overrides_same_fixture_supersedes_fk");
    for (const name of ["sync_fpl_data", "preview_fixture_result_override", "create_fixture_result_override", "process_pot_gameweek"])
      expect(functionBody(name)).toContain("fixture_result_lock_key");
    expect(functionBody("process_pot_gameweek")).toMatch(/order by pick\.fixture_id[\s\S]*?fixture_result_lock_key[\s\S]*?pg_advisory_xact_lock\(hashtext\(selected_pot_id/i);
  });

  it("rejects invalid and no-op corrections and records reasoned supersession", () => {
    expect(migration).toContain("A correction reason is required");
    expect(migration).toContain("Finished fixtures require both scores");
    expect(migration).toContain("Both scores must be supplied together");
    expect(migration).toContain("The proposed correction does not change the effective result");
    expect(migration).toContain("Unsupported fixture status transition");
    expect(migration).toContain("Result changed; preview again");
    const create = functionBody("create_fixture_result_override");
    expect(create).toMatch(/supersedes_id[\s\S]*?effective\.override_id/i);
    expect(create).toContain("fixture_result_overridden");
    expect(create).toContain("pot_flagged_for_result_review");
    expect(create).toMatch(/review_status\s*=\s*'needs_review'/i);
    expect(create).not.toMatch(/update\s+public\.(?:player_picks|pot_players)/i);
  });

  it("processes effective results and atomically writes immutable snapshots", () => {
    const process = functionBody("process_pot_gameweek");
    expect(process).toMatch(/get_effective_fixture_result/i);
    for (const field of [
      "resolved_home_team_id", "resolved_away_team_id", "resolved_home_score", "resolved_away_score",
      "result_source", "resolved_at", "resolved_fixture_season", "resolved_fixture_status",
    ]) expect(process).toContain(field);
    expect(process).toMatch(/locked_result\.status\s*<>\s*'finished'/i);
    expect(process).toContain("authoritative_results");
    expect(process).toContain("A locked fixture result is not final; process the preview again");
    expect(process).not.toContain("recalculation");
  });

  it("provides rollback-only disposable verification for every P2 boundary", () => {
    expect(verification).toMatch(/\bbegin\s*;/i);
    expect(verification).toMatch(/\brollback\s*;/i);
    for (const evidence of [
      "Impact preview mutated provenance or audit rows",
      "Provisional provider result was considered final",
      "Stale preview was accepted",
      "Raw/effective result separation failed",
      "Provider synchronization overwrote the authoritative override",
      "Processing did not atomically snapshot the authoritative result",
      "Processed pot was not flagged for review",
      "Processed correction rewrote an immutable outcome or player state",
      "Completed pot was rewritten or not flagged",
      "Historical process summary changed",
      "No-op override was accepted",
      "Negative score override was accepted",
      "Partial score override was accepted",
      "Second override root was accepted",
      "Cross-fixture supersession was accepted",
      "Override supersession linkage is incorrect",
      "Non-admin correction was accepted",
      "Anonymous correction execution was accepted",
      "Phase P2 rollback left synthetic verification rows behind",
    ]) expect(verification).toContain(evidence);
  });

  it("ships genuine two-session lock and stale-version verification assets", () => {
    expect(concurrencyA).toContain("pg_sleep(10)");
    expect(concurrencyB).toContain("expected_effective_version");
    expect(processA).toContain("fixture_result_lock_key");
    expect(syncB).toContain("sync_fpl_data");
    expect(processCorrectionA).toContain("process_pot_gameweek");
    expect(processCorrectionB).toContain("expected_effective_version");
    expect(concurrencyVerification).toContain("all three two-session concurrency cases");
    expect(concurrencyVerification).not.toContain("both two-session cases");
    for (const race of [
      "Correction versus correction",
      "Processing versus provider synchronization",
      "Processing versus correction",
    ]) expect(phaseDocumentation).toContain(race);
    expect(phaseDocumentation).toContain("override_b_pid=$!");
    expect(phaseDocumentation).toContain("process_a_pid=$!");
    expect(phaseDocumentation).toContain("correction_b_pid=$!");
    expect(phaseDocumentation).toContain('wait "$override_b_pid"');
    expect(phaseDocumentation).toContain('test "$override_a_status" -eq 0 && test "$override_b_status" -eq 3');
    expect(phaseDocumentation).toContain('test "$process_a_status" -eq 0 && test "$sync_b_status" -eq 0');
    expect(phaseDocumentation).toContain('test "$correction_process_a_status" -eq 0 && test "$correction_b_status" -eq 3');
    expect(phaseDocumentation).toContain("result_corrections_concurrency_verification.sql");
  });
});
