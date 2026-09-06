// Which Supabase project may a remote operation touch?
//
// Companion to lms-deploy-target.mjs, which answers the same question for Vercel.
// Project refs are NOT redefined here — they are imported from that module so the
// repository keeps one environment mapping.
//
// This module never contacts Supabase. It reads its own registry, the requested
// environment, and (when present) the gitignored .vercel-equivalent link that the
// Supabase CLI writes at supabase/.temp/linked-project.json.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { SUPABASE_REF } from "./lms-deploy-target.mjs";

export { SUPABASE_REF };

export const SUPABASE_ENVIRONMENTS = Object.freeze(["production", "staging"]);

// Whether this repository's guarded commands may mutate each environment.
//
// Both refs are known — production's appears in vercel.json's CSP and in the Vite
// production build — so a checkout linked to production is *identified* as production
// rather than dismissed as unknown. Knowing the ref is not the same as being allowed
// to use it: production remote operations have never been authorised in this
// repository (every Phase 2K record states production was not contacted), so they are
// refused here regardless of what the operator passes.
export const REMOTE_OPERATIONS = Object.freeze({
  staging: Object.freeze({ allowed: true }),
  production: Object.freeze({
    allowed: false,
    blockedReason:
      "no production Supabase operation has been authorised in this repository, and\n" +
      "                          none is recorded in the Phase 2K evidence",
    prerequisite:
      "Registering production as an approved operation target is a prerequisite: it needs an\n" +
      "  explicit operator decision, a production backup/restore gate, and a change to\n" +
      "  REMOTE_OPERATIONS in scripts/lms-supabase-target.mjs. Knowing the project ref is not\n" +
      "  sufficient on its own.",
  }),
});

// Edge Functions this repository is allowed to deploy or delete remotely.
export const EDGE_FUNCTIONS = Object.freeze(["lms-scheduler"]);

// Function secrets this repository is allowed to set or unset. Platform-provided values
// (SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY) are deliberately absent:
// Supabase injects them and they must never be overwritten from here.
export const MANAGED_SECRETS = Object.freeze([
  "LMS_SCHEDULER_SECRET",
  "LMS_SEASON",
  "LMS_PROVIDER_TIMEOUT_MS",
  "LMS_PROVIDER_RETRIES",
]);

export class SupabaseTargetError extends Error {
  constructor(message) {
    super(message);
    this.name = "SupabaseTargetError";
  }
}

const token = (value) => (typeof value === "string" ? value.trim().toLowerCase() : "");

/** The environment a project ref belongs to, or null when unrecognised. */
export function environmentForRef(ref, refs = SUPABASE_REF) {
  const candidate = token(ref);
  if (!candidate) return null;
  return SUPABASE_ENVIRONMENTS.find((name) => token(refs[name]) === candidate) ?? null;
}

/**
 * Read the project the Supabase CLI is currently linked to.
 *
 * Returns null when the file is absent, unreadable or malformed. It is gitignored and
 * does not exist in a fresh clone or in CI, so its absence is normal. Never written to.
 */
export function readLinkedProject(rootDir) {
  try {
    const parsed = JSON.parse(readFileSync(join(rootDir, "supabase", ".temp", "linked-project.json"), "utf8"));
    if (!parsed || typeof parsed !== "object") return null;
    const ref = typeof parsed.ref === "string" ? parsed.ref : null;
    const name = typeof parsed.name === "string" ? parsed.name : null;
    return ref ? { ref, name } : null;
  } catch {
    return null;
  }
}

/** Reject an environment this repository may not mutate. */
export function assertRemoteOperationAllowed(environment) {
  if (!SUPABASE_ENVIRONMENTS.includes(environment)) {
    throw new SupabaseTargetError(
      [
        `Refusing the operation: unknown Supabase environment "${environment}".`,
        "",
        `  Supported environments : ${SUPABASE_ENVIRONMENTS.join(", ")}`,
      ].join("\n"),
    );
  }
  const policy = REMOTE_OPERATIONS[environment];
  if (policy.allowed) return policy;

  throw new SupabaseTargetError(
    [
      `Refusing the operation: ${environment} Supabase operations are not permitted from this repository.`,
      "",
      `  Requested environment : ${environment}`,
      `  Why this is blocked   : ${policy.blockedReason}`,
      "",
      `  ${policy.prerequisite}`,
    ].join("\n"),
  );
}

/** Reject an Edge Function this repository does not own. */
export function assertEdgeFunction(name) {
  if (!EDGE_FUNCTIONS.includes(name)) {
    throw new SupabaseTargetError(
      [
        `Refusing the operation: "${name}" is not an Edge Function this repository manages.`,
        "",
        `  Managed functions : ${EDGE_FUNCTIONS.join(", ")}`,
      ].join("\n"),
    );
  }
  return name;
}

/** Reject a secret name outside the managed set. Values are never inspected here. */
export function assertManagedSecret(name) {
  if (!MANAGED_SECRETS.includes(name)) {
    throw new SupabaseTargetError(
      [
        `Refusing the operation: "${name}" is not a secret this repository manages.`,
        "",
        `  Managed secrets : ${MANAGED_SECRETS.join(", ")}`,
        "  Platform values (SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY) are",
        "  injected by Supabase and must not be set from here.",
      ].join("\n"),
    );
  }
  return name;
}

function contradiction({ environment, ref, linked, linkedEnvironment }) {
  const identity = linkedEnvironment
    ? `is the ${linkedEnvironment} project`
    : "is not a project this repository recognises";
  return [
    "Refusing the operation: the linked Supabase project contradicts the requested target.",
    "",
    `  Requested environment : ${environment} (${ref})`,
    `  Linked project        : ${linked.name ? `${linked.name} ` : ""}(${linked.ref}) ${identity}`,
    "  Why this is unsafe    : a link pointing somewhere else is strong evidence this shell is",
    "                          in the wrong checkout or context. Proceeding risks operating on",
    "                          a project you did not intend, even though --project-ref is passed.",
    "",
    "  Safe options:",
    `    - work in a checkout linked to the ${environment} project; or`,
    "    - run `npx supabase unlink` so no ambient project is inherited, then retry —",
    "      the guarded commands pass --project-ref explicitly and do not need a link.",
  ].join("\n");
}

/**
 * Prove which Supabase project a remote operation will touch, or refuse.
 *
 * Order matters: the environment must be permitted before anything else is considered,
 * so a production request is refused on policy rather than on link state.
 *
 * Link policy:
 *   matching link      -> pass, and record it as corroborating evidence
 *   absent link        -> pass; the explicit registered --project-ref is positive proof
 *   contradicting link -> refuse, including a link to an unrecognised project
 *
 * Returns { environment, ref, evidence } for reporting.
 */
export function resolveRemoteTarget({ environment, rootDir, linkedProject, refs = SUPABASE_REF } = {}) {
  assertRemoteOperationAllowed(environment);

  const ref = refs[environment];
  if (!ref) {
    throw new SupabaseTargetError(
      `Refusing the operation: no Supabase project ref is registered for "${environment}".`,
    );
  }

  const linked =
    linkedProject !== undefined ? linkedProject : rootDir ? readLinkedProject(rootDir) : null;
  const evidence = [{ source: "requested environment", value: `${environment} (${ref})` }];

  if (linked) {
    const linkedEnvironment = environmentForRef(linked.ref, refs);
    if (linkedEnvironment !== environment) {
      throw new SupabaseTargetError(contradiction({ environment, ref, linked, linkedEnvironment }));
    }
    evidence.push({
      source: "linked project (supabase/.temp/linked-project.json)",
      value: `${linked.name ?? linked.ref} (${linked.ref})`,
    });
  } else {
    evidence.push({ source: "linked project", value: "none present; explicit --project-ref is authoritative" });
  }

  return { environment, ref, evidence };
}
