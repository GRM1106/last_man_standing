#!/usr/bin/env node
// Guarded Supabase remote operations.
//
//   node scripts/supabase-remote.mjs <operation> <environment> [options]
//
//   operations : check | deploy-function | delete-function | set-secrets | unset-secrets
//   options    : --dry-run            validate and print the command, run nothing
//                --env-file <path>    set-secrets only; where the values are read from
//                --secret <NAME>      unset-secrets only; repeatable
//
// The target is proven BEFORE the Supabase CLI is invoked, and the CLI arguments are
// constructed here rather than accepted from the caller, so no arbitrary flag can be
// injected. Every remote command is given an explicit --project-ref; the local link is
// used only as a contradiction check.
//
// This script never reads, echoes or logs a secret value.

import { execFileSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  EDGE_FUNCTIONS,
  MANAGED_SECRETS,
  SUPABASE_ENVIRONMENTS,
  SupabaseTargetError,
  assertEdgeFunction,
  assertManagedSecret,
  resolveRemoteTarget,
} from "./lms-supabase-target.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const OPERATIONS = ["check", "deploy-function", "delete-function", "set-secrets", "unset-secrets"];
const DEFAULT_FUNCTION = EDGE_FUNCTIONS[0];

function fail(message) {
  console.error(`\n${message}\n`);
  process.exit(1);
}

function usage(problem) {
  fail(
    [
      `Refusing the operation: ${problem}.`,
      "",
      `  Operations   : ${OPERATIONS.join(", ")}`,
      `  Environments : ${SUPABASE_ENVIRONMENTS.join(", ")}`,
      "",
      "  Usage: node scripts/supabase-remote.mjs <operation> <environment> [--dry-run]",
      "                                          [--env-file <path>] [--secret <NAME>]",
    ].join("\n"),
  );
}

// ---- parse, accepting only what this wrapper understands -------------------------
const argv = process.argv.slice(2);
const positional = argv.filter((arg) => !arg.startsWith("--"));
const [operation, environment] = positional;
let envFile = null;
const secrets = [];
let dryRun = false;

for (let index = 0; index < argv.length; index += 1) {
  const arg = argv[index];
  if (!arg.startsWith("--")) continue;
  if (arg === "--dry-run") dryRun = true;
  else if (arg === "--env-file") envFile = argv[++index] ?? null;
  else if (arg === "--secret") secrets.push(argv[++index] ?? "");
  else usage(`unsupported option "${arg}"`);
}

if (!OPERATIONS.includes(operation)) usage(`unknown operation "${operation ?? "(none)"}"`);
if (!SUPABASE_ENVIRONMENTS.includes(environment)) usage(`unknown environment "${environment ?? "(none)"}"`);

// ---- prove the target before anything else ---------------------------------------
let target;
try {
  target = resolveRemoteTarget({ environment, rootDir: root });
} catch (error) {
  fail(error instanceof SupabaseTargetError ? error.message : String(error));
}

console.log(`Supabase ${operation} -> ${target.environment}`);
for (const item of target.evidence) console.log(`  proof: ${item.source}: ${item.value}`);

// ---- build the exact CLI arguments -----------------------------------------------
function secretsEnvFile() {
  if (!envFile) {
    fail(
      [
        "Refusing the operation: set-secrets needs --env-file.",
        "",
        "  Secret values are never held in package.json, in this repository, or in a command",
        "  line. Supply them in a local env file that git ignores, then pass its path.",
        "",
        `  Managed secrets : ${MANAGED_SECRETS.join(", ")}`,
        "  Example         : --env-file ../lms-staging-secrets.env   (outside the repository)",
      ].join("\n"),
    );
  }
  const path = resolve(process.cwd(), envFile);
  if (!existsSync(path) || !statSync(path).isFile()) fail(`Refusing the operation: no env file at ${envFile}.`);

  // A secrets file inside the repository must be ignored, or it can be committed.
  const inside = !relative(root, path).startsWith("..");
  if (inside) {
    let ignored = false;
    try {
      execFileSync("git", ["check-ignore", "--quiet", path], { cwd: root, stdio: "ignore" });
      ignored = true;
    } catch {
      ignored = false;
    }
    if (!ignored) {
      fail(
        [
          "Refusing the operation: the env file is inside the repository and is not gitignored.",
          "",
          `  File : ${relative(root, path)}`,
          "  Why  : an unignored secrets file can be committed. Move it outside the repository,",
          "         or add it to .gitignore first.",
        ].join("\n"),
      );
    }
  }
  return path;
}

let cliArgs;
switch (operation) {
  case "check":
    console.log(`\nPASS: ${target.environment} (${target.ref}) is a permitted target for guarded operations.`);
    console.log("No Supabase command was run.");
    process.exit(0);
    break;
  case "deploy-function":
    cliArgs = ["functions", "deploy", assertEdgeFunction(DEFAULT_FUNCTION), "--project-ref", target.ref];
    break;
  case "delete-function":
    cliArgs = ["functions", "delete", assertEdgeFunction(DEFAULT_FUNCTION), "--project-ref", target.ref];
    break;
  case "set-secrets":
    cliArgs = ["secrets", "set", "--project-ref", target.ref, "--env-file", secretsEnvFile()];
    break;
  case "unset-secrets": {
    if (!secrets.length) usage("unset-secrets needs at least one --secret NAME");
    try {
      secrets.forEach(assertManagedSecret);
    } catch (error) {
      fail(error instanceof SupabaseTargetError ? error.message : String(error));
    }
    cliArgs = ["secrets", "unset", "--project-ref", target.ref, ...secrets];
    break;
  }
}

// The env-file path is printed; its contents are not read here and never logged.
console.log(`\ncommand: npx supabase ${cliArgs.join(" ")}`);

if (dryRun) {
  console.log("--dry-run: validated only. Nothing was sent to Supabase.");
  process.exit(0);
}

if (operation === "delete-function") {
  console.log(`\nThis removes ${DEFAULT_FUNCTION} from the ${target.environment} project.`);
}

try {
  execFileSync("npx", ["supabase", ...cliArgs], { cwd: root, stdio: "inherit" });
} catch {
  // The CLI prints its own diagnostics; do not re-echo anything that may carry values.
  fail(`The Supabase CLI failed during ${operation}. Nothing further was attempted.`);
}
