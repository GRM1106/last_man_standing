import { fetchFplData, ProviderError } from "./fpl-provider.js";

export async function runSchedulerPipeline({ source, season, operations, fetchOptions = {} }) {
  const claim = await operations.claim(source);
  if (!claim?.acquired) return { status: "skipped", reason: "already_running", runId: claim?.run_id };
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
