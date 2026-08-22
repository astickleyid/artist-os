const fs = require('fs');
const vm = require('vm');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, '../../docs/canonical-web.js'), 'utf8');
const sandbox = { globalThis: {}, console };
sandbox.globalThis = sandbox;
vm.runInNewContext(source, sandbox, { filename: 'canonical-web.js' });

const C = sandbox.AOSCanonicalWeb;
function assert(cond, msg) { if (!cond) throw new Error(msg); }

(function mapsCanonicalKinds() {
  assert(C.STORE_BY_KIND.decision === 'decisions', 'decision store mapping');
  assert(C.STORE_BY_KIND.masterComposition === 'masterCompositions', 'master composition store mapping');
})();

(function keepsCanonicalKindsOutOfLegacyPull() {
  const changes = [
    { kind: 'decision', id: 'd1', updatedAt: 10, data: { id: 'd1', songId: 's1' } },
    { kind: 'masterComposition', id: 'm1', updatedAt: 11, data: { id: 'm1', songId: 's1' } },
    { kind: 'asset', id: 'a1', updatedAt: 12, data: { id: 'a1', songId: 's1' } }
  ];
  const out = C.normalizeIncomingChanges(changes, []);
  assert(out.canonical.length === 3, 'all canonical changes remain durable');
  assert(out.legacy.length === 1 && out.legacy[0].kind === 'asset', 'legacy app only sees supported kinds');
})();

(function convertsKnownSongTombstoneToArchive() {
  const song = { id: 's1', title: 'Song', status: 'review', updatedAt: 5 };
  const out = C.normalizeIncomingChanges([
    { kind: 'song', id: 's1', updatedAt: 20, deleted: true }
  ], [song]);
  assert(out.legacy.length === 1, 'known song tombstone is retained as compatibility update');
  assert(out.legacy[0].deleted !== true, 'known song tombstone is non-destructive');
  assert(out.legacy[0].data.status === 'archived', 'known song tombstone archives song');
  assert(out.legacy[0].data.updatedAt === 20, 'remote LWW timestamp is preserved');
})();

(function ignoresUnknownSongTombstone() {
  const out = C.normalizeIncomingChanges([
    { kind: 'song', id: 'missing', updatedAt: 20, deleted: true }
  ], []);
  assert(out.legacy.length === 0, 'unknown song tombstone is not invented locally');
  assert(out.canonical.length === 0, 'unknown song tombstone is not persisted as destructive truth');
})();

(function cacheMergeUsesNewestEntity() {
  const local = [{ id: 'a', updatedAt: 20, title: 'local' }, { id: 'b', updatedAt: 5 }];
  const cached = [{ id: 'a', updatedAt: 10, title: 'old' }, { id: 'b', updatedAt: 15, title: 'new' }];
  const merged = C.mergeByUpdatedAt(local, cached);
  assert(merged.find(x => x.id === 'a').title === 'local', 'newer local entity wins');
  assert(merged.find(x => x.id === 'b').title === 'new', 'newer cached entity wins');
})();

(function tombstoneOnlySuppressesOlderEntity() {
  const list = [{ id: 'a', updatedAt: 10 }, { id: 'b', updatedAt: 30 }];
  const tombstones = [
    { id: 'asset:a', kind: 'asset', entityId: 'a', updatedAt: 20 },
    { id: 'asset:b', kind: 'asset', entityId: 'b', updatedAt: 20 }
  ];
  const out = C.applyTombstones(list, tombstones, 'asset');
  assert(!out.some(x => x.id === 'a'), 'newer tombstone suppresses stale entity');
  assert(out.some(x => x.id === 'b'), 'newer local entity survives older tombstone');
})();

console.log('canonical-web tests passed');
