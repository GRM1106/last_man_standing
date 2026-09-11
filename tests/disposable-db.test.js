import { describe, expect, it, vi } from 'vitest';
import { assertOwnedContainer, DisposableDatabase, OWNER_LABEL, TEST_IMAGE } from '../scripts/lib/disposable-db.mjs';

const token = '12345678-1234-1234-1234-123456789abc';
const id = 'a'.repeat(64);
const spec = { token, id };
const owned = () => ({ Id: id, Name: `/lms-db-test-${token}`, Config: { Image: TEST_IMAGE, Labels: { [OWNER_LABEL]: token } }, HostConfig: { NetworkMode: 'none', Binds: null, Tmpfs: { '/var/lib/postgresql/data': 'rw' } }, Mounts: [] });
const unsafeMetadata = [
  ['missing bind metadata', i => { delete i.HostConfig.Binds; }],
  ['mistyped bind metadata', i => { i.HostConfig.Binds = {}; }],
  ['host bind', i => { i.HostConfig.Binds = ['/normal/db:/data']; }],
  ['missing tmpfs metadata', i => { delete i.HostConfig.Tmpfs; }],
  ['mistyped tmpfs metadata', i => { i.HostConfig.Tmpfs = []; }],
  ['unexpected tmpfs destination', i => { i.HostConfig.Tmpfs = { '/normal/db': 'rw' }; }],
  ['missing mount metadata', i => { delete i.Mounts; }],
  ['null mount metadata', i => { i.Mounts = null; }],
  ['mistyped mount metadata', i => { i.Mounts = {}; }],
  ['incomplete mount entry', i => { i.Mounts = [{}]; }],
  ['array mount entry', i => { i.Mounts = [Object.assign([], { Type: 'volume', Name: id })]; }],
  ['tmpfs represented as an unexpected mount', i => { i.Mounts = [{ Type: 'tmpfs', Destination: '/var/lib/postgresql/data' }]; }],
  ['bind mount', i => { i.Mounts = [{ Type: 'bind', Source: '/normal/db' }]; }],
  ['unexpected mount type', i => { i.Mounts = [{ Type: 'npipe' }]; }],
  ['unnamed volume', i => { i.Mounts = [{ Type: 'volume' }]; }],
  ['non-string anonymous volume name', i => { i.Mounts = [{ Type: 'volume', Name: [id] }]; }],
  ['anonymous volume at an unexpected destination', i => { i.Mounts = [{ Type: 'volume', Name: id, Destination: '/normal/db' }]; }],
  ['named development volume', i => { i.Mounts = [{ Type: 'volume', Name: 'supabase_db_last_man_standing' }]; }],
];

describe('disposable database ownership guard', () => {
  it('accepts only the exact runner-created identity', () => expect(() => assertOwnedContainer(owned(), spec)).not.toThrow());
  it('accepts only conventionally named volume metadata at the database path', () => {
    const info = owned();
    info.Mounts = [{ Type: 'volume', Name: id, Destination: '/var/lib/postgresql/data' }];
    expect(() => assertOwnedContainer(info, spec)).not.toThrow();
  });
  it.each([
    ['different ID', i => { i.Id = 'b'.repeat(64); }],
    ['development container name', i => { i.Name = '/supabase_db_last_man_standing'; }],
    ['missing owner label', i => { i.Config.Labels = {}; }],
    ['another runner label', i => { i.Config.Labels[OWNER_LABEL] = 'other'; }],
    ['wrong image', i => { i.Config.Image = 'postgres:latest'; }],
    ['host network', i => { i.HostConfig.NetworkMode = 'host'; }],
    ...unsafeMetadata,
  ])('refuses %s', (_, change) => {
    const info = owned(); change(info);
    expect(() => assertOwnedContainer(info, spec)).toThrow('REFUSED');
  });
  it('refuses missing creation identity and never performs fallback cleanup', () => {
    const docker = vi.fn(); const db = new DisposableDatabase({ docker, log: vi.fn() });
    expect(() => db.sql('drop schema public cascade')).toThrow('REFUSED');
    db.cleanup(); expect(docker).not.toHaveBeenCalled();
  });
  it('refuses cleanup after ownership changes, without running rm', () => {
    const docker = vi.fn(() => JSON.stringify([owned()]));
    const db = new DisposableDatabase({ docker, log: vi.fn() }); db.id = id;
    expect(() => db.cleanup()).toThrow('REFUSED');
    expect(docker.mock.calls.map(([args]) => args[0])).toEqual(['inspect']);
  });
  it.each(unsafeMetadata)('refuses cleanup with %s and never runs rm', (_, change) => {
    const db = new DisposableDatabase({ log: vi.fn() });
    const info = owned();
    info.Name = `/${db.name}`;
    info.Config.Labels[OWNER_LABEL] = db.token;
    change(info);
    db.id = id;
    db.docker = vi.fn(() => JSON.stringify([info]));
    expect(() => db.cleanup()).toThrow('REFUSED');
    expect(db.docker.mock.calls.map(([args]) => args[0])).toEqual(['inspect']);
  });
  it('refuses SQL when the database marker is wrong', () => {
    const db = new DisposableDatabase({ log: vi.fn() });
    const info = owned(); info.Name = `/${db.name}`; info.Config.Labels[OWNER_LABEL] = db.token;
    db.id = id; db.ready = true;
    db.docker = vi.fn(args => args[0] === 'inspect' ? JSON.stringify([info]) : 'wrong_database');
    expect(() => db.sql('drop schema public cascade')).toThrow('marker mismatch');
    expect(db.docker.mock.calls).toHaveLength(2);
  });
  it('cleanup targets only its created full ID and reports it first', () => {
    const log = vi.fn(); const db = new DisposableDatabase({ log });
    const info = owned(); info.Name = `/${db.name}`; info.Config.Labels[OWNER_LABEL] = db.token;
    db.id = id;
    db.docker = vi.fn(args => args[0] === 'inspect' ? JSON.stringify([info]) : '');
    db.cleanup();
    expect(db.docker.mock.calls[1][0]).toEqual(['rm', '--force', '--volumes', id]);
    expect(log).toHaveBeenCalledWith(expect.stringContaining(`id=${id}`));
    expect(log.mock.invocationCallOrder[0]).toBeLessThan(db.docker.mock.invocationCallOrder[1]);
    expect(db.id).toBeNull();
  });
  it('refuses a shortened container ID', () => expect(() => assertOwnedContainer(owned(), { token, id: id.slice(0, 12) })).toThrow('REFUSED'));
});
