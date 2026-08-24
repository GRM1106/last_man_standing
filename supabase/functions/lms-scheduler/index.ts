import { createClient } from "npm:@supabase/supabase-js@2.112.3";
import { runSchedulerPipeline } from "../../../server/scheduler-pipeline.js";

const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, apikey, content-type, x-scheduler-secret" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });

async function authorize(request: Request, source: string, url: string, anonKey: string) {
  if (source === "scheduler") {
    const supplied = request.headers.get("x-scheduler-secret");
    const expected = Deno.env.get("LMS_SCHEDULER_SECRET");
    return Boolean(expected && supplied && supplied === expected);
  }
  const authorization = request.headers.get("authorization") || "";
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: { user } } = await caller.auth.getUser();
  if (!user) return false;
  const { data } = await caller.from("profiles").select("is_admin").eq("id", user.id).single();
  return data?.is_admin === true;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "Scheduler configuration is incomplete." }, 503);
  let body: { source?: string; season?: string };
  try { body = await request.json(); } catch { return json({ error: "Invalid request." }, 400); }
  const source = body.source === "scheduler" ? "scheduler" : body.source === "local_simulation" ? "local_simulation" : "admin";
  if (!(await authorize(request, source, url, anonKey))) return json({ error: "Administrator or scheduler authentication required." }, 403);
  const database = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const operations = {
    async claim(runSource: string) {
      const { data, error } = await database.rpc("claim_lms_provider_run", { run_source: runSource });
      if (error) throw error; return data;
    },
    async ingestAndScan(runId: string, season: string, payload: { teams: unknown[]; fixtures: unknown[] }) {
      const { data, error } = await database.rpc("complete_lms_provider_run", { run_id: runId, selected_season: season, fpl_teams: payload.teams, fpl_fixtures: payload.fixtures });
      if (error) throw error; return data;
    },
    async fail(runId: string, classification: string, retryable: boolean) {
      await database.rpc("fail_lms_provider_run", { run_id: runId, failure_class: classification, is_retryable: retryable });
    }
  };
  try {
    const result = await runSchedulerPipeline({ source, season: body.season || Deno.env.get("LMS_SEASON") || "2026/27", operations, fetchOptions: {
      timeoutMs: Number(Deno.env.get("LMS_PROVIDER_TIMEOUT_MS") || 10_000), retries: Number(Deno.env.get("LMS_PROVIDER_RETRIES") || 2)
    } });
    return json(result, result.status === "skipped" ? 202 : 200);
  } catch { return json({ error: "Football data refresh failed safely." }, 502); }
});
