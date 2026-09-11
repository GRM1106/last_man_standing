import { execFile, execFileSync } from 'node:child_process';
import { randomUUID, randomBytes } from 'node:crypto';

export const TEST_IMAGE = 'public.ecr.aws/supabase/postgres:17.6.1.165';
export const OWNER_LABEL = 'com.lms.disposable-db.run';
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const idPattern = /^[0-9a-f]{64}$/;
const dataPath = '/var/lib/postgresql/data';
const executeDocker = (args, options = {}) => execFileSync('docker', args, {
  encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 120_000, ...options,
});

export function assertOwnedContainer(info, spec) {
  const binds = info?.HostConfig?.Binds;
  const tmpfs = info?.HostConfig?.Tmpfs;
  const mounts = info?.Mounts;
  const bindsAreProven = binds === null || (Array.isArray(binds) && binds.length === 0);
  const tmpfsIsProven = tmpfs && typeof tmpfs === 'object' && !Array.isArray(tmpfs)
    && Object.keys(tmpfs).length === 1 && tmpfs[dataPath] === 'rw';
  const mountsAreProven = Array.isArray(mounts) && mounts.every(mount => mount
    && typeof mount === 'object' && !Array.isArray(mount)
    && mount.Type === 'volume' && mount.Destination === dataPath
    && typeof mount.Name === 'string' && idPattern.test(mount.Name));
  if (!uuidPattern.test(spec.token) || !idPattern.test(spec.id || '')
    || info?.Id !== spec.id || info?.Name !== `/lms-db-test-${spec.token}`
    || info?.Config?.Labels?.[OWNER_LABEL] !== spec.token
    || info?.Config?.Image !== TEST_IMAGE || info?.HostConfig?.NetworkMode !== 'none'
    || !bindsAreProven || !tmpfsIsProven || !mountsAreProven) {
    throw new Error('REFUSED: disposable container ownership/isolation could not be proven');
  }
}

export class DisposableDatabase {
  constructor({ docker = executeDocker, log = console.log } = {}) {
    // No caller-supplied target, connection string, container name, or cleanup prefix.
    this.token = randomUUID();
    this.name = `lms-db-test-${this.token}`;
    this.database = `lms_test_${this.token.replaceAll('-', '')}`;
    this.id = null;
    this.docker = docker;
    this.log = log;
    this.ready = false;
  }
  proveOwnership() {
    if (!this.id) throw new Error('REFUSED: this runner has not created a container');
    const info = JSON.parse(this.docker(['inspect', this.id]))[0];
    assertOwnedContainer(info, this);
    return info;
  }
  target(operation) {
    this.log(`TARGET ${operation}: container=${this.name} id=${this.id || '(new)'} database=${this.database} run=${this.token}`);
  }
  async start() {
    if (this.id) throw new Error('REFUSED: a disposable container was already created');
    this.target('create isolated PostgreSQL');
    const id = this.docker(['create', '--pull', 'never', '--name', this.name,
      '--label', `${OWNER_LABEL}=${this.token}`, '--network', 'none',
      '--tmpfs', '/var/lib/postgresql/data:rw',
      '--env', `POSTGRES_PASSWORD=${randomBytes(32).toString('hex')}`, TEST_IMAGE]).trim();
    if (!idPattern.test(id)) throw new Error('REFUSED: docker did not return a full created container ID');
    this.id = id;
    this.proveOwnership();
    this.docker(['start', this.id]);
    let available = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      try {
        this.docker(['exec', this.id, 'psql', '-XqAt', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres', '-c',
          "select 1/(case when count(*)=3 then 1 else 0 end) from pg_roles where rolname in ('anon','authenticated','service_role')"], { timeout: 2000 });
        available = true;
        break;
      } catch { await new Promise(resolve => setTimeout(resolve, 500)); }
    }
    if (!available) throw new Error('Disposable PostgreSQL did not become ready');
    this.proveOwnership();
    this.target('create test database');
    this.docker(['exec', '-i', this.id, 'psql', '-Xq', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], {
      input: `create database ${this.database};\ncomment on database ${this.database} is 'lms-db-test:${this.token}';\n`,
    });
    this.ready = true;
  }
  proveDatabase() {
    this.proveOwnership();
    if (!this.ready || this.database !== `lms_test_${this.token.replaceAll('-', '')}`) {
      throw new Error('REFUSED: disposable database identity is unproven');
    }
    const marker = this.docker(['exec', this.id, 'psql', '-XqAt', '-U', 'postgres', '-d', this.database, '-c',
      "select current_database() || ':' || shobj_description(oid,'pg_database') from pg_database where datname=current_database()" ]).trim();
    if (marker !== `${this.database}:lms-db-test:${this.token}`) throw new Error('REFUSED: disposable database marker mismatch');
  }
  sql(statement) {
    this.proveDatabase();
    return this.docker(['exec', '-i', this.id, 'psql', '-XqAt', '-U', 'postgres', '-d', this.database, '-v', 'ON_ERROR_STOP=1'], { input: statement });
  }
  async sqlAsync(statement) {
    this.proveDatabase();
    return new Promise((resolve, reject) => {
      const child = execFile('docker', ['exec', '-i', this.id, 'psql', '-XqAt', '-U', 'postgres', '-d', this.database, '-v', 'ON_ERROR_STOP=1'],
        { encoding: 'utf8', timeout: 120_000 }, (error, stdout, stderr) => {
          if (error) { error.stderr = stderr; reject(error); } else resolve(stdout);
        });
      child.stdin.end(statement);
    });
  }
  cleanup() {
    if (!this.id) return;
    // No fallback by name, pruning, Supabase stop/reset, or separately named volume.
    this.proveOwnership();
    this.target('destroy runner-owned container and its anonymous volumes only');
    this.docker(['rm', '--force', '--volumes', this.id]);
    this.id = null;
    this.ready = false;
  }
}
