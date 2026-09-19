import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertOwnedContainer, OWNER_LABEL, TEST_IMAGE } from './disposable-db.mjs';

const PURPOSE_LABEL = 'com.lms.disposable-db.purpose';
const PURPOSE = 'acl-recovery';
const fullId = /^[0-9a-f]{64}$/;
const executeDocker = (args, options = {}) => execFileSync('docker', args, {
  encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 120_000, ...options,
});

// The state file is private to a fresh mktemp directory. It is evidence from
// docker create, never a user-selected container to adopt or reuse.
export function manageAclContainer(operation, statePath, args = [], {
  docker = executeDocker, log = console.error,
} = {}) {
  if (operation === 'create') {
    const token = randomUUID();
    const state = { token, name: `lms-db-test-${token}`, id: null };
    // Refuse reuse even if a previous invocation left an incomplete state file.
    writeFileSync(statePath, JSON.stringify(state), { flag: 'wx', mode: 0o600 });
    log(`CREATE ACL test container: name=${state.name} run=${token}`);
    const id = docker(['create', '--pull', 'never', '--name', state.name,
      '--label', `${OWNER_LABEL}=${token}`, '--label', `${PURPOSE_LABEL}=${PURPOSE}`,
      '--network', 'none', '--tmpfs', '/var/lib/postgresql/data:rw',
      '--env', `POSTGRES_PASSWORD=${randomBytes(32).toString('hex')}`, TEST_IMAGE]).trim();
    if (!fullId.test(id)) throw new Error('REFUSED: Docker did not return a full created container ID; inspect for an orphan');
    state.id = id;
    // If recording fails, do not guess by name. Report the exact orphan identity.
    log(`CREATED ACL test container: id=${id} name=${state.name} run=${token}`);
    writeFileSync(statePath, JSON.stringify(state), { mode: 0o600 });
    prove(state);
    return;
  }

  let state;
  try { state = JSON.parse(readFileSync(statePath, 'utf8')); }
  catch (error) {
    if (operation === 'cleanup' && error.code === 'ENOENT') return;
    throw error;
  }
  if (!state || typeof state !== 'object' || !Object.hasOwn(state, 'id')
    || state.name !== `lms-db-test-${state.token}`) {
    throw new Error('REFUSED: invalid ACL resource state');
  }
  if (state.id === null && operation === 'cleanup') return;
  if (!fullId.test(state.id || '')) throw new Error('REFUSED: no full created container identity');

  prove(state);
  if (operation === 'start') {
    docker(['start', state.id]);
  } else if (operation === 'exec') {
    if (!['psql', 'pg_isready'].includes(args[0])) throw new Error('REFUSED: only PostgreSQL test commands are allowed');
    docker(['exec', '-i', state.id, ...args], { stdio: 'inherit' });
  } else if (operation === 'cleanup') {
    log(`REMOVE ACL test container: id=${state.id} name=${state.name} run=${state.token}`);
    docker(['rm', '--force', '--volumes', state.id]);
    // Only mark removed after Docker reports success. Repeated cleanup is a no-op.
    state.id = null;
    writeFileSync(statePath, JSON.stringify(state), { mode: 0o600 });
  } else if (operation === 'keep') {
    log(`KEEP ACL test container: id=${state.id} name=${state.name} run=${state.token}; ownership record: ${statePath}`);
  } else {
    throw new Error('REFUSED: unknown ACL resource operation');
  }

  function prove(spec) {
    const info = JSON.parse(docker(['inspect', spec.id]))[0];
    assertOwnedContainer(info, spec);
    const ports = info.HostConfig.PortBindings;
    if (info.Config.Labels[PURPOSE_LABEL] !== PURPOSE
      || !(ports === null || (ports && typeof ports === 'object'
        && !Array.isArray(ports) && Object.keys(ports).length === 0))) {
      throw new Error('REFUSED: ACL purpose or port isolation could not be proven');
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [operation, statePath, ...args] = process.argv.slice(2);
    if (!statePath) throw new Error('An invocation-local ownership record is required');
    manageAclContainer(operation, statePath, args);
  } catch (error) {
    // Avoid dumping docker-create arguments: they contain the temporary password.
    console.error(error.stderr?.toString() || (error.message?.startsWith('REFUSED:')
      ? error.message : 'ACL resource operation failed; inspect the ownership record before retrying.'));
    process.exitCode = 1;
  }
}

