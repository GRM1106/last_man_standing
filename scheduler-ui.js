// Operator-facing wording for a provider sync result.
//
// The scheduler pipeline reports the database's own claim reason and no display text.
// Mapping that reason to a sentence belongs here, so an unrecognised reason falls back
// to neutral wording instead of being reported as something it is not.

const skipMessages = new Map([
  ["already_running", "Sync skipped safely because another provider run is active."],
  // Only the scheduled source is gated by this switch, so the wording says which one.
  // A manual admin sync is never refused for this reason.
  ["disabled", "Sync skipped because scheduled provider automation is disabled."],
]);

const NEUTRAL_SKIP = "Sync skipped safely. No football data was changed.";

/** Wording for a skipped claim. Unknown reasons stay neutral and are never echoed back. */
export function skipReasonMessage(reason) {
  return skipMessages.get(reason) || NEUTRAL_SKIP;
}

/** Wording for any provider sync result, skipped or completed. */
export function syncResultMessage(result) {
  if (result?.status === "skipped") return skipReasonMessage(result?.reason);
  const teams = result?.ingestion?.teams || 0;
  const fixtures = result?.ingestion?.fixtures || 0;
  return `Football data sync complete: ${teams} clubs and ${fixtures} fixtures updated; automation scan finished.`;
}
