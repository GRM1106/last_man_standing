import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  new URL("../supabase/migrations/20260824000900_lms_phase_2k_align_winner_preview.sql", import.meta.url),
  "utf8",
);
const verification = readFileSync(
  new URL("../supabase/verification/lms_phase_2k_winner_preview_alignment_verification.sql", import.meta.url),
  "utf8",
);
const phase2h = readFileSync(
  new URL("../supabase/migrations/20260824000100_lms_phase_2h_governed_review.sql", import.meta.url),
  "utf8",
);
const reviewDocumentation = readFileSync(new URL("../PHASE_2H_GOVERNED_REVIEW.md", import.meta.url), "utf8");

function functionBody(name) {
  const match = migration.match(new RegExp(`create or replace function public\\.${name}\\b([\\s\\S]*?)\\$\\$;`, "i"));
  expect(match, `${name} should exist`).not.toBeNull();
  return match[0];
}

describe("Phase 2K winner-preview alignment migration", () => {
  it("is a forward-only migration that leaves Phase 2H in place", () => {
    expect(migration.trimStart()).toMatch(/^-- Phase 2K: make the governed review preview project/);
    expect(migration).toMatch(/\bbegin\s*;/i);
    expect(migration).toMatch(/\bcommit\s*;/i);
    for (const table of ["pot_completion_adjudications", "pot_adjudicated_winners", "pot_winners", "pot_completions"]) {
      expect(migration).not.toMatch(new RegExp(`drop table\\s+public\\.${table}`, "i"));
    }
    // Phase 2H is untouched on disk: this migration must not have edited history.
    expect(phase2h).toContain("preview_lms_review_resolution");
  });

  it("computes the revised winner set in exactly one place", () => {
    const projection = functionBody("lms_revised_winner_projection");
    const preview = functionBody("preview_lms_review_resolution");
    const apply = functionBody("resolve_lms_review_case");

    // Both paths delegate; neither derives a winner set of its own.
    expect(preview).toContain("public.lms_revised_winner_projection(c.pot_id,selected_player_ids)");
    expect(apply).toContain("public.lms_revised_winner_projection(c.pot_id,selected_player_ids)");

    // The split arithmetic exists only inside the projection helper.
    expect(projection).toContain("(total/nominated)");
    expect(projection).toContain("(total%nominated)");
    expect(preview).not.toMatch(/total\s*\/\s*(nominated|cardinality)/);
    expect(apply).not.toMatch(/base:=|remainder:=/);

    // The defect itself: proposed_winner_count must never be the caller's array length.
    expect(preview).not.toMatch(/coalesce\(cardinality\(selected_player_ids\),0\)/);
    expect(preview).toContain("'proposed_winner_count',(projection->>'winner_count')::integer");
  });

  it("keeps the split rule and ordering the apply path already used", () => {
    const projection = functionBody("lms_revised_winner_projection");
    expect(projection).toContain("row_number() over(order by m.joined_at,u)");
    expect(projection).toMatch(/case when row_number\(\) over\(order by m\.joined_at,u\)<=\(total%nominated\) then 1 else 0 end/);
  });

  it("closes the null-cardinality hole that let an empty revision apply", () => {
    const projection = functionBody("lms_revised_winner_projection");
    expect(projection).toContain("nominated:=coalesce(cardinality(selected_player_ids),0)");
    expect(projection).toContain("A completed pot and at least one winner are required");
    expect(projection).toContain("A winner was nominated more than once");
    expect(projection).toContain("Every nominated winner must be a member of this pot");

    const apply = functionBody("resolve_lms_review_case");
    expect(apply).toContain("if not (projection->>'valid')::boolean then raise exception '%',projection->>'problem'");
    // The old null-unsafe guard must be gone.
    expect(apply).not.toMatch(/cardinality\(selected_player_ids\)<1/);
  });

  it("surfaces the proposed set, shares and validity to the operator", () => {
    const preview = functionBody("preview_lms_review_resolution");
    for (const key of ["proposed_winners", "proposed_winner_count", "proposed_prize_total", "proposed_valid", "proposed_problem"]) {
      expect(preview, `preview should expose ${key}`).toContain(`'${key}'`);
    }
    // Existing consumers keep the keys they already relied on.
    for (const key of ["case_id", "status", "version_token", "action", "original_winners", "prize_total", "pot_after"]) {
      expect(preview).toContain(`'${key}'`);
    }
  });

  it("leaves stale-preview protection and the token composition untouched", () => {
    const preview = functionBody("preview_lms_review_resolution");
    expect(preview).toContain(
      "token:=md5(c.id::text||':'||c.version||':'||c.status||':'||(select count(*) from public.lms_review_cases where pot_id=c.pot_id and status='open')||':'||coalesce((select completed_at::text from public.pot_completions where pot_id=c.pot_id),'none'));",
    );
    const apply = functionBody("resolve_lms_review_case");
    expect(apply).toContain("if preview->>'version_token'<>expected_version_token then raise exception 'Review state changed; preview again.'");
  });

  it("keeps preview read-only and the original completion immutable", () => {
    const preview = functionBody("preview_lms_review_resolution");
    expect(preview).toMatch(/language plpgsql stable security definer/i);
    for (const write of ["insert into", "update public.", "delete from"]) {
      expect(preview.toLowerCase()).not.toContain(write);
    }
    const projection = functionBody("lms_revised_winner_projection");
    expect(projection).toMatch(/language plpgsql stable security definer/i);
    for (const write of ["insert into", "update public.", "delete from"]) {
      expect(projection.toLowerCase()).not.toContain(write);
    }
    // Phase 2H's design: a revision is ledgered, the Phase 2G completion is not rewritten.
    const apply = functionBody("resolve_lms_review_case");
    expect(apply).not.toMatch(/(update|delete from)\s+public\.pot_winners/i);
    expect(apply).not.toMatch(/(update|delete from)\s+public\.pot_completions/i);
  });

  it("preserves signatures, hardening and grants", () => {
    for (const name of ["lms_revised_winner_projection", "preview_lms_review_resolution", "resolve_lms_review_case"]) {
      expect(functionBody(name)).toMatch(/security definer set search_path\s*=\s*''/i);
    }
    expect(migration).toMatch(/revoke all on function public\.lms_revised_winner_projection\(uuid,uuid\[\]\) from public,anon,authenticated/i);
    expect(migration).toMatch(/grant execute on function public\.preview_lms_review_resolution\(uuid,text,uuid\[\]\) to authenticated/i);
    expect(migration).toMatch(/grant execute on function public\.resolve_lms_review_case\(uuid,text,text,text,uuid\[\]\) to authenticated/i);
    // Public RPC signatures are unchanged, so callers are unaffected.
    expect(migration).toContain("preview_lms_review_resolution(selected_case_id uuid,selected_action text,selected_player_ids uuid[] default null)");
    expect(migration).toContain("resolve_lms_review_case(selected_case_id uuid,selected_action text,resolution_reason text,expected_version_token text,selected_player_ids uuid[] default null)");
  });

  it("asserts its own postconditions before committing", () => {
    expect(migration).toMatch(/must keep SECURITY DEFINER and an empty search_path/i);
    expect(migration).toMatch(/must remain available to administrators/i);
    expect(migration).toMatch(/must not be reachable anonymously/i);
    expect(migration).toMatch(/winner projection helper must stay internal/i);
    expect(migration).toMatch(/preview_lms_review_resolution must remain STABLE/i);
    expect(migration).toMatch(/lms_revised_winner_projection must remain STABLE/i);
  });
});

describe("Phase 2K winner-preview alignment verification", () => {
  it("compares winner sets, not counts", () => {
    expect(verification).toContain("if projected is distinct from persisted then");
    expect(verification).toContain("Preview/apply winner set disagreed");
    expect(verification).toContain("Preview/apply split disagreed");
    expect(verification.trimEnd().endsWith("rollback;")).toBe(true);
  });

  it("uses non-zero prizes including one that does not divide evenly", () => {
    expect(verification).toContain("total_prize_pence=3000");
    expect(verification).toContain("total_prize_pence=2000");
    expect(verification).toContain("(w->>'prize_share_pence')::integer=667");
    expect(verification).toContain("(w->>'prize_share_pence')::integer=666");
    expect(verification).toContain("Adjudicated shares did not conserve the prize");
  });

  it("covers the required W-2 scenarios", () => {
    const expectations = [
      "Preview accepted a revision with no nominated winners",
      "Apply accepted a revision with no nominated winners",
      "Preview accepted a non-member nominee",
      "Apply accepted a non-member nominee",
      "Preview accepted a duplicated nominee",
      "Preview mutated persistent state",
      "Stale preview token accepted",
      "Adjudication audit fields missing",
      "Resolution event missing",
      "Original Phase 2G winners were rewritten",
      "Adjudication revision numbering did not increment",
      "GW38 survivor rule or prize changed for pot one",
      "close_without_change must project the winners that remain",
      "Player previewed a governed resolution",
      "Player resolved a governed case",
      "Winner projection helper or governed RPCs are over-exposed",
    ];
    for (const message of expectations) {
      expect(verification, `missing assertion: ${message}`).toContain(message);
    }
  });

  it("documents the preview contract where governed review is described", () => {
    expect(reviewDocumentation).toMatch(/read-only projection/i);
    expect(reviewDocumentation).toMatch(/same winner derivation/i);
    expect(reviewDocumentation).toMatch(/stale/i);
  });
});
