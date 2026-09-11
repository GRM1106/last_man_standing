import { fetchFplData, ProviderError } from "./fpl-provider.js";

export async function runSchedulerPipeline({ source, season, operations, fetchOptions = {} }) {
  const claim = await operations.claim(source);
  // The database decides why a claim was refused — overlap, a disabled switch, or a
  // future reason — so carry its answer through rather than assuming one. Every
  // unacquired claim_lms_provider_run path supplies `reason`, making the fallback
  // purely defensive; it must stay neutral so an unknown reason is never mislabelled.
  if (!claim?.acquired) return { status: "skipped", reason: claim?.reason || "unavailable", runId: claim?.run_id };
  const runId = claim.run_id;
  try {
    const payload = await fetchFplData(fetchOptions);
    return await operations.ingestAndScan(runId, season, payload);
  } catch (error) {
    const classification = error instanceof ProviderError ? error.classification : "platform";
    await operations.fail(runId, classification, error instanceof ProviderError && error.retryable);
    throw error;
  }
}
