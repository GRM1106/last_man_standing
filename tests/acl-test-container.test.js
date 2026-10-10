import { describe, expect, it, vi, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { manageAclContainer } from '../scripts/lib/acl-test-container.mjs';
import { OWNER_LABEL, TEST_IMAGE } from '../scripts/lib/disposable-db.mjs';

const scratches = [];
const scratch = () => { const dir = mkdtempSync(join(tmpdir(), 'lms-acl-unit-')); scratches.push(dir); return dir; };
afterEach(() => scratches.splice(0).forEach(dir => rmSync(dir, { recursive: true, force: true })));
function fixture() {
  const statePath = join(scratch(), 'container.json');
  const resources = new Map();
  let counter = 0;
  const docker = vi.fn(args => {
    if (args[0] === 'create') {
      const id = (++counter).toString(16).padStart(64, '0');
      const labels = Object.fromEntries(args.flatMap((arg, index) => arg === '--label' ? [args[index + 1].split('=')] : []));
      resources.set(id, {
        Id: id, Name: '/' + args[args.indexOf('--name') + 1],
        Config: { Image: TEST_IMAGE, Labels: labels },
        HostConfig: { NetworkMode: 'none', Binds: null, Tmpfs: { '/var/lib/postgresql/data': 'rw' }, PortBindings: {} },
        Mounts: [],
      });
      return id;
    }
    if (args[0] === 'inspect') {
      if (!resources.has(args[1])) throw new Error('missing container');
      return JSON.stringify([resources.get(args[1])]);
    }
    if (args[0] === 'rm') resources.delete(args.at(-1));
    return '';
  });
  const run = (operation, args = [], path = statePath) => manageAclContainer(operation, path, args, { docker, log: vi.fn() });
  const state = () => JSON.parse(readFileSync(statePath, 'utf8'));
  return { statePath, resources, docker, run, state };
}

describe('ACL recovery resource lifecycle', () => {
  it('creates fresh, labelled, isolated resources without adopting or deleting existing names', () => {
    const f = fixture(); f.run('create');
    const args = f.docker.mock.calls[0][0];
    expect(args).toEqual(expect.arrayContaining(['--pull', 'never', '--network', 'none', '--tmpfs', '/var/lib/postgresql/data:rw']));
    expect(args).not.toContain('--volume');
    expect(args).not.toContain('--publish');
    expect(f.state().name).toMatch(/^lms-db-test-[0-9a-f-]{36}$/);
    expect(f.docker.mock.calls.map(([a]) => a[0])).toEqual(['create', 'inspect']);
    expect(() => f.run('create')).toThrow();
    expect(f.docker.mock.calls.filter(([a]) => a[0] === 'create')).toHaveLength(1);
  });
  it('starts and executes only by full ID after fresh inspection', () => {
    const f = fixture(); f.run('create'); const id = f.state().id;
    f.docker.mockClear(); f.run('start'); f.run('exec', ['psql', '-c', 'select 1']);
    expect(f.docker.mock.calls.map(([a]) => a)).toEqual([
      ['inspect', id], ['start', id], ['inspect', id], ['exec', '-i', id, 'psql', '-c', 'select 1'],
    ]);
  });
  it.each([
    ['ID', info => { info.Id = 'f'.repeat(64); }],
    ['name', info => { info.Name += '-other'; }],
    ['owner', info => { info.Config.Labels[OWNER_LABEL] = 'another-run'; }],
    ['purpose', info => { delete info.Config.Labels['com.lms.disposable-db.purpose']; }],
    ['image', info => { info.Config.Image = 'other'; }],
    ['network', info => { info.HostConfig.NetworkMode = 'host'; }],
    ['bind', info => { info.HostConfig.Binds = ['/host:/data']; }],
    ['volume', info => { info.Mounts = [{ Type: 'volume', Name: 'other-data', Destination: '/var/lib/postgresql/data' }]; }],
    ['ports', info => { info.HostConfig.PortBindings = { '5432/tcp': [{ HostPort: '5432' }] }; }],
    ['missing port metadata', info => { delete info.HostConfig.PortBindings; }],
  ])('refuses operations with changed %s evidence', (_, mutate) => {
    const f = fixture(); f.run('create'); mutate(f.resources.get(f.state().id));
    f.docker.mockClear();
    for (const operation of ['start', 'exec', 'cleanup', 'keep']) expect(() => f.run(operation, ['psql'])).toThrow('REFUSED');
    expect(f.docker.mock.calls.every(([a]) => a[0] === 'inspect')).toBe(true);
  });
  it('cleans partial setup after start failure and is idempotent', () => {
    const f = fixture(); f.run('create'); const id = f.state().id;
    const execute = f.docker.getMockImplementation();
    f.docker.mockImplementation(args => { if (args[0] === 'start') throw new Error('startup failed'); return execute(args); });
    expect(() => f.run('start')).toThrow('startup failed');
    f.run('cleanup'); f.run('cleanup');
    expect(f.docker.mock.calls.filter(([a]) => a[0] === 'rm').map(([a]) => a)).toEqual([['rm', '--force', '--volumes', id]]);
    expect(f.state().id).toBeNull();
  });
  it.each(['throw', 'short ID'])('never guesses cleanup identity after create returns %s', failure => {
    const f = fixture();
    f.docker.mockImplementation(() => { if (failure === 'throw') throw new Error('create failed'); return 'short'; });
    expect(() => f.run('create')).toThrow();
    f.run('cleanup');
    expect(f.docker).toHaveBeenCalledTimes(1);
    expect(f.state().id).toBeNull();
  });
  it('fails closed on inspect errors and malformed state', () => {
    const f = fixture(); f.run('create'); f.resources.clear(); f.docker.mockClear();
    expect(() => f.run('cleanup')).toThrow('missing container');
    expect(f.docker.mock.calls.map(([a]) => a[0])).toEqual(['inspect']);
    writeFileSync(f.statePath, '{');
    expect(() => f.run('cleanup')).toThrow();
    expect(f.docker).toHaveBeenCalledTimes(1);
  });
  it('retains identity after removal failure, then retries only after another proof', () => {
    const f = fixture(); f.run('create'); const id = f.state().id;
    const execute = f.docker.getMockImplementation();
    f.docker.mockImplementation(args => { if (args[0] === 'rm') throw new Error('remove failed'); return execute(args); });
    expect(() => f.run('cleanup')).toThrow('remove failed');
    expect(f.state().id).toBe(id);
    f.docker.mockImplementation(execute); f.docker.mockClear(); f.run('cleanup');
    expect(f.docker.mock.calls.map(([a]) => a[0])).toEqual(['inspect', 'rm']);
  });
  it('keeps resources only after proof and does not interfere with another or similarly named resource', () => {
    const f = fixture(); f.run('create'); const first = f.state();
    const secondPath = join(scratch(), 'container.json'); f.run('create', [], secondPath);
    const second = JSON.parse(readFileSync(secondPath, 'utf8'));
    expect(second.token).not.toBe(first.token); expect(second.name).not.toBe(first.name);
    const foreign = 'f'.repeat(64);
    f.resources.set(foreign, { Name: '/' + first.name + '-unrelated' });
    f.run('keep'); expect(f.resources.has(first.id)).toBe(true);
    f.run('cleanup');
    expect(f.resources.has(second.id)).toBe(true); expect(f.resources.has(foreign)).toBe(true);
    f.run('cleanup', [], secondPath);
    expect([...f.resources.keys()]).toEqual([foreign]);
  });
  it('does nothing before creation, but refuses execution without creation', () => {
    const f = fixture(); f.run('cleanup');
    expect(f.docker).not.toHaveBeenCalled();
    expect(() => f.run('exec', ['psql'])).toThrow();
  });
});

describe('ACL shell exit and signal handling with a fake Docker executable', () => {
  function shellFixture(mode, keep = '0') {
    const dir = scratch(), record = join(dir, 'record.json'), calls = join(dir, 'calls.jsonl'), waiting = join(dir, 'waiting');
    const fakeDocker = `#!/usr/bin/env node
const fs = require('node:fs');
const a = process.argv.slice(2), mode = process.env.ACL_TEST_MODE;
fs.appendFileSync(process.env.ACL_TEST_CALLS, JSON.stringify(a[0] === 'create' ? ['create'] : a) + '\\n');
if (a[0] === 'create') {
 const labels = Object.fromEntries(a.flatMap((x,i)=>x==='--label'?[a[i+1].split('=')]:[]));
 const info={Id:'a'.repeat(64),Name:'/'+a[a.indexOf('--name')+1],Config:{Image:a.at(-1),Labels:labels},HostConfig:{NetworkMode:'none',Binds:null,Tmpfs:{'/var/lib/postgresql/data':'rw'},PortBindings:{}},Mounts:[]};
 fs.writeFileSync(process.env.ACL_TEST_RECORD,JSON.stringify(info));console.log(info.Id);
} else if(a[0]==='inspect') console.log('['+fs.readFileSync(process.env.ACL_TEST_RECORD,'utf8')+']');
else if(a[0]==='start' && mode==='start-failure') { console.error('injected start failure');process.exit(19); }
else if(a[0]==='rm' && mode==='cleanup-failure') { console.error('injected cleanup failure');process.exit(20); }
else if(a[0]==='exec' && a.includes('psql')) {
 const sql=a[a.indexOf('-c')+1];
 if(a.includes('-c') && sql.includes('string_agg')) console.log('stable-roles');
 else if(a.includes('-c') && sql.includes('substring')) console.log('17');
 else if(mode==='signal') { fs.writeFileSync(process.env.ACL_TEST_WAITING,'ready');setInterval(()=>{},1000); }
 else { console.error('injected fixture failure');process.exit(21); }
}
`;
    writeFileSync(join(dir, 'docker'), fakeDocker, { mode: 0o700 });
    writeFileSync(join(dir, 'sleep'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    const script = fileURLToPath(new URL('../scripts/test_phase_2k_acl_recovery.sh', import.meta.url));
    const env = { ...process.env, PATH: dir + ':' + process.env.PATH, TMPDIR: dir, KEEP: keep, ACL_TEST_RECORD: record, ACL_TEST_CALLS: calls, ACL_TEST_MODE: mode, ACL_TEST_WAITING: waiting };
    const operations = () => readFileSync(calls, 'utf8').trim().split('\n').map(line => JSON.parse(line));
    return { script, env, operations, waiting };
  }
  it.each(['0', '1'])('cleans partial startup even with KEEP=%s', keep => {
    const f = shellFixture('start-failure', keep);
    let error;
    try { execFileSync('bash', [f.script], { env: f.env, stdio: 'pipe' }); } catch (caught) { error = caught; }
    expect(error?.status).toBe(1);
    expect(error.stderr.toString()).toContain('injected start failure');
    expect(f.operations().map(a => a[0])).toEqual(['create', 'inspect', 'inspect', 'start', 'inspect', 'rm']);
    expect(f.operations().at(-1)).toEqual(['rm', '--force', '--volumes', 'a'.repeat(64)]);
  });
  it.each(['fixture-failure', 'cleanup-failure'])('reports %s and never masks it with success', mode => {
    const f = shellFixture(mode);
    let error;
    try { execFileSync('bash', [f.script], { env: f.env, stdio: 'pipe' }); } catch (caught) { error = caught; }
    expect(error?.status).toBe(1);
    expect(error.stderr.toString()).toContain('injected fixture failure');
    expect(f.operations().at(-1)).toEqual(['rm', '--force', '--volumes', 'a'.repeat(64)]);
    if (mode === 'cleanup-failure') expect(error.stderr.toString()).toContain('Cleanup refused or failed');
  });
  it('retains a verified ready resource on test failure only when KEEP=1 is explicit', () => {
    const f = shellFixture('fixture-failure', '1');
    let error;
    try { execFileSync('bash', [f.script], { env: f.env, stdio: 'pipe' }); } catch (caught) { error = caught; }
    expect(error?.status).toBe(1);
    expect(error.stderr.toString()).toContain('KEEP ACL test container');
    expect(f.operations().some(a => a[0] === 'rm')).toBe(false);
    expect(f.operations().at(-1)[0]).toBe('inspect');
  });
  it.each([['SIGINT', 130], ['SIGTERM', 143]])('cleans on %s even with KEEP=1', async (signal, status) => {
    const f = shellFixture('signal', '1');
    const child = spawn('bash', [f.script], { env: f.env, detached: true, stdio: 'pipe' });
    let stderr = ''; child.stderr.on('data', chunk => { stderr += chunk; }); child.stdout.resume();
    const closed = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
    try {
      const deadline = Date.now() + 4000;
      while (!existsSync(f.waiting) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
      expect(existsSync(f.waiting), stderr).toBe(true);
      process.kill(-child.pid, signal);
      expect(await closed).toEqual({ code: status, signal: null });
      expect(f.operations().filter(a => a[0] === 'rm')).toEqual([['rm', '--force', '--volumes', 'a'.repeat(64)]]);
    } finally {
      if (child.exitCode === null && child.signalCode === null) { process.kill(-child.pid, 'SIGKILL'); await closed; }
    }
  }, 10_000);
});
