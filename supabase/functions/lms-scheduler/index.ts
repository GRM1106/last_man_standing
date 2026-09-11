import { createClient } from "npm:@supabase/supabase-js@2.112.3";
import { runSchedulerPipeline } from "../../../server/scheduler-pipeline.js";
import { createSchedulerOperations } from "../../../server/scheduler-operations.js";

const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, apikey, content-type, x-scheduler-secret" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });

async function authorize(request: Request, source: string, url: string, anonKey: string) {
  if (source === "scheduler") {
    const supplied = request.headers.get("x-scheduler-secret");
    const expected = Deno.env.get("LMS_SCHEDULER_SECRET");
    return expected && supplied && supplied === expected ? { actorId: null } : null;
  }
  const authorization = request.headers.get("authorization") || "";
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: { user } } = await caller.auth.getUser();
  if (!user) return null;
  const { data } = await caller.from("profiles").select("is_admin").eq("id", user.id).single();
  return data?.is_admin === true ? { actorId: user.id } : null;
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
  const authorization = await authorize(request, source, url, anonKey);
  if (!authorization) return json({ error: "Administrator or scheduler authentication required." }, 403);
  const database = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const operations = createSchedulerOperations(database, authorization.actorId);
  try {
    const result = await runSchedulerPipeline({ source, season: body.season || Deno.env.get("LMS_SEASON") || "2026/27", operations, fetchOptions: {
      timeoutMs: Number(Deno.env.get("LMS_PROVIDER_TIMEOUT_MS") || 10_000), retries: Number(Deno.env.get("LMS_PROVIDER_RETRIES") || 2)
    } });
    return json(result, result.status === "skipped" ? 202 : 200);
  } catch { return json({ error: "Football data refresh failed safely." }, 502); }
});
