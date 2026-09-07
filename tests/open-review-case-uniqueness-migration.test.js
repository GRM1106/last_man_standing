import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  new URL("../supabase/migrations/20260824001000_lms_phase_2k_open_review_case_uniqueness.sql", import.meta.url),
  "utf8",
);
const verification = readFileSync(
  new URL("../supabase/verification/lms_phase_2k_open_review_case_uniqueness_verification.sql", import.meta.url),
  "utf8",
);
const phase2h = readFileSync(
  new URL("../supabase/migrations/20260824000100_lms_phase_2h_governed_review.sql", import.meta.url),
  "utf8",
);

const OPEN_CASE_FUNCTION = "open_lms_review_case";
const OLD_CONSTRAINT = "lms_review_cases_pot_id_case_type_fixture_id_player_id_stat_key";
const NEW_INDEX = "lms_review_cases_one_open_per_target";

function functionBody(name) {
  const match = migration.match(new RegExp(`create or replace function public\\.${name}\\b([\\s\\S]*?)\\$\\$;`, "i"));
  expect(match, `${name} should exist`).not.toBeNull();
  return match[0];
}

describe("Phase 2K open-review-case uniqueness migration", () => {
  it("is a forward-only migration that leaves Phase 2H history in place", () => {
    expect(migration.trimStart()).toMatch(/^-- Phase 2K: let a pot be corrected more than twice/);
    expect(migration).toMatch(/\bbegin\s*;/i);
    expect(migration).toMatch(/\bcommit\s*;/i);
    // Schema and function replacement only: no historical review data may be touched.
    expect(migration).not.toMatch(/delete from public\.lms_review_cases/i);
    expect(migration).not.toMatch(/update public\.lms_review_cases\s+set/i);
    expect(migration).not.toMatch(/drop table/i);
    expect(migration).not.toMatch(/truncate/i);
    // Phase 2H is untouched on disk.
    expect(phase2h).toContain("unique nulls not distinct(pot_id,case_type,fixture_id,player_id,status)");
  });

  it("drops the status-bearing constraint", () => {
    expect(migration).toMatch(
      new RegExp(`alter table public\\.lms_review_cases\\s+drop constraint ${OLD_CONSTRAINT}`, "i"),
    );
    expect(migration).toMatch(new RegExp(`raise exception 'The status-bearing review-case constraint is still present'`));
  });

  it("replaces it with open-only uniqueness over the target shape", () => {
    const index = migration.match(new RegExp(`create unique index ${NEW_INDEX}[\\s\\S]*?;`, "i"));
    expect(index, "the open-only index should be created").not.toBeNull();
    const definition = index[0];
    expect(definition).toMatch(/on public\.lms_review_cases \(pot_id, case_type, fixture_id, player_id\)/i);
    // Null targets must still deduplicate; PostgreSQL's default would treat them as distinct.
    expect(definition).toMatch(/nulls not distinct/i);
    expect(definition).toMatch(/where status = 'open'/i);
    // Terminal statuses must not be covered by the uniqueness predicate.
    expect(definition).not.toMatch(/resolved|dismissed/i);
    expect(definition).not.toMatch(/\bstatus\s*[,)]/i);
    // No sentinel-value workaround was needed on PostgreSQL 15+.
    expect(definition).not.toMatch(/coalesce/i);
  });

  it("keeps the upsert inferring the new partial index", () => {
    const opener = functionBody(OPEN_CASE_FUNCTION);
    // Inferring a partial index requires the predicate to be restated.
    expect(opener).toContain("on conflict(pot_id,case_type,fixture_id,player_id) where status='open' do update set");
    expect(opener).not.toContain("on conflict(pot_id,case_type,fixture_id,player_id,status)");
  });

  it("preserves the deduplication behaviour exactly", () => {
    const opener = functionBody(OPEN_CASE_FUNCTION);
    expect(opener).toContain("evidence=lms_review_cases.evidence||excluded.evidence");
    expect(opener).toContain("impact_snapshot=excluded.impact_snapshot");
    expect(opener).toContain("version=lms_review_cases.version+1");
    // opened_at/opened_by are never in the update list, so a merge keeps the original.
    expect(opener).not.toMatch(/do update set[^;]*opened_at/i);
    expect(opener).not.toMatch(/do update set[^;]*opened_by/i);
    // Unrelated review behaviour is unchanged.
    expect(opener).toContain("if selected_source='admin' and not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;");
    expect(opener).toContain("update public.pots set lifecycle_status='review',review_status='needs_review'");
    expect(opener).toContain("set_config('lms.review_case_opening'");
  });

  it("preserves the function signature, hardening and grants", () => {
    const opener = functionBody(OPEN_CASE_FUNCTION);
    expect(opener).toMatch(/security definer set search_path\s*=\s*''/i);
    expect(opener).toContain(
      "open_lms_review_case(selected_pot_id uuid,selected_case_type text,selected_summary text,selected_round_id uuid default null,selected_fixture_id bigint default null,selected_pick_id bigint default null,selected_player_id uuid default null,selected_evidence jsonb default '{}',selected_source text default 'system') returns uuid",
    );
    expect(migration).toMatch(
      /revoke all on function public\.open_lms_review_case\(uuid,text,text,uuid,bigint,bigint,uuid,jsonb,text\) from public,anon,authenticated/i,
    );
    expect(migration).not.toMatch(/grant execute on function public\.open_lms_review_case/i);
  });

  it("asserts its own preconditions and postconditions", () => {
    expect(migration).toMatch(/The Phase 2H review-case uniqueness constraint is missing/);
    expect(migration).toMatch(/Existing data already violates the open-case invariant/);
    expect(migration).toMatch(/The open-only review-case index is missing/);
    expect(migration).toMatch(/must treat null targets as equal/);
    expect(migration).toMatch(/must be restricted to open cases/);
    expect(migration).toMatch(/Status must not be part of the review-case uniqueness key/);
    expect(migration).toMatch(/must keep SECURITY DEFINER and an empty search_path/);
    expect(migration).toMatch(/must remain internal/);
  });
});

describe("Phase 2K open-review-case uniqueness verification", () => {
  it("exercises the lifecycle through the real domain function", () => {
    expect(verification).toContain("public.open_lms_review_case(");
    expect(verification).toContain("public.resolve_lms_review_case(");
    expect(verification).toContain("public.preview_lms_review_resolution(");
    expect(verification.trimEnd().endsWith("rollback;")).toBe(true);
  });

  it("covers the required uniqueness scenarios", () => {
    const expectations = [
      "Reopening an open shape must return the same case",
      "Reopening an open shape must not create a second row",
      "Reopening must increment version",
      "Evidence must merge",
      "Deduplication must preserve opened_at/opened_by",
      "Two resolved cases of the same shape must be able to coexist",
      "Two dismissed cases of the same shape must be able to coexist",
      "Expected four resolved and four dismissed",
      "A second open case of the same shape was accepted",
      "Terminal rows must not be constrained",
      "Null targets must be treated as equal for deduplication",
      "A different fixture must open its own case",
      "A null player target must not merge into a specific player case",
      "Different pots must not share a case",
    ];
    for (const message of expectations) {
      expect(verification, `missing assertion: ${message}`).toContain(message);
    }
  });

  it("re-proves the governed resolution lifecycle over the new index", () => {
    const expectations = [
      "confirm_existing did not resolve",
      "close_without_change should dismiss",
      "A case must not transition twice",
      "Stale preview token accepted",
      "Expected exactly two new resolution events",
      "Resolution events were mutable",
    ];
    for (const message of expectations) {
      expect(verification, `missing assertion: ${message}`).toContain(message);
    }
  });
});
