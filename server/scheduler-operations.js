// actorId comes only from the Edge Function's verified administrator session.
export function createSchedulerOperations(database, actorId = null) {
  return {
    async claim(runSource) {
      const { data, error } = actorId
        ? await database.rpc('claim_lms_provider_run_for_admin', { run_source: runSource, administrator_id: actorId })
        : await database.rpc('claim_lms_provider_run', { run_source: runSource });
      if (error) throw error;
      return data;
    },
    async ingestAndScan(runId, season, payload) {
      const { data, error } = await database.rpc('complete_lms_provider_run', {
        run_id: runId, selected_season: season, fpl_teams: payload.teams, fpl_fixtures: payload.fixtures,
      });
      if (error) throw error;
      return data;
    },
    async fail(runId, classification, retryable) {
      await database.rpc('fail_lms_provider_run', { run_id: runId, failure_class: classification, is_retryable: retryable });
    },
  };
}
