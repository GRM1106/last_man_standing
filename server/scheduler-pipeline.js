import { fetchFplData, ProviderError } from "./fpl-provider.js";

export class SchedulerFailurePersistenceError extends Error {
  constructor(processingError, persistenceError, runId) {
    super('Scheduler processing failed and its failure could not be recorded.', { cause: processingError });
    this.name = 'SchedulerFailurePersistenceError';
    this.persistenceError = persistenceError;
    this.runId = runId;
  }
}

// Never log raw errors, provider response bodies, request headers or credentials.
export function schedulerFailureReport(error) {
  const processing = error instanceof SchedulerFailurePersistenceError ? error.cause : error;
  const classification = processing instanceof ProviderError ? processing.classification : 'platform';
  const safeClass = /^(provider|validation|malformed_json|timeout|network|platform|http_[1-5][0-9]{2})$/.test(classification)
    ? classification : 'platform';
  const report = { event: 'lms_scheduler_failure', processing_class: safeClass,
    retryable: processing instanceof ProviderError && processing.retryable === true,
    failure_recording_failed: error instanceof SchedulerFailurePersistenceError };
  if (error instanceof SchedulerFailurePersistenceError && typeof error.runId === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(error.runId)) report.run_id = error.runId;
  return report;
}

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
    try {
      await operations.fail(runId, classification, error instanceof ProviderError && error.retryable);
    } catch (persistenceError) {
      throw new SchedulerFailurePersistenceError(error, persistenceError, runId);
    }
    throw error;
  }
}
