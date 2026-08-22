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

(function canonicalCompositionOverridesStaleSongMirrors() {
  const song = {
    id: 's1', title: 'Song', masterAssetId: 'legacy-master', progress: 1, risk: 'Master locked',
    sections: [
      { id: 'sec1', name: 'Hook', role: 'Melody', assetId: 'legacy-source', state: 'locked', conf: 1, note: 'legacy' },
      { id: 'sec2', name: 'Bridge', role: 'Alt pocket', assetId: 'legacy-bridge', state: 'locked', conf: 1, note: '' }
    ]
  };
  const composition = {
    id: 'm1', songId: 's1', outputAssetId: 'canonical-master', updatedAt: 50,
    sections: [
      {
        id: 'sec1', name: 'Hook', role: 'hook', state: 'needsDecision', confidence: 0.4, note: 'canonical',
        selections: [{ kind: 'sourceAsset', referenceId: 'canonical-source' }]
      },
      {
        id: 'sec2', name: 'Bridge', role: 'bridge', state: 'open', confidence: 0.2, note: '', selections: []
      }
    ]
  };
  const projected = C.projectCanonicalSong(song, composition);
  assert(projected.masterAssetId === 'canonical-master', 'canonical output overrides stale Song master mirror');
  assert(projected.sections[0].assetId === 'canonical-source', 'canonical source overrides stale Song section mirror');
  assert(projected.sections[0].state === 'needsDecision', 'canonical state drives the compatibility decision view');
  assert(projected.sections[0].conf === 0.4, 'canonical confidence drives the compatibility view');
  assert(projected.sections[0].note === 'canonical', 'canonical note drives the compatibility view');
  assert(projected.sections[1].assetId === null, 'canonical nil source does not resurrect stale Song source');
  assert(projected.progress === 0, 'progress is derived from canonical section states');
  assert(projected.risk === 'Hook decision unresolved', 'risk is derived from canonical unresolved state');
})();

(function canonicalCompositionReconstructsClearedSongMirrors() {
  const song = {
    id: 's1', title: 'Song', masterAssetId: null, progress: 0, risk: 'In assembly',
    sections: [
      { id: 'sec1', name: 'Hook', role: 'hook', assetId: null, state: 'open', conf: 0, note: '' }
    ]
  };
  const composition = {
    id: 'm1', songId: 's1', outputAssetId: 'canonical-master', updatedAt: 60,
    sections: [
      {
        id: 'sec1', name: 'Hook', role: 'hook', state: 'locked', confidence: 0.9, note: 'approved source',
        selections: [{ kind: 'sourceAsset', referenceId: 'canonical-source' }]
      }
    ]
  };
  const projected = C.projectCanonicalSong(song, composition);
  assert(projected.masterAssetId === 'canonical-master', 'web current master reconstructs from canonical composition when Song mirror is cleared');
  assert(projected.sections[0].assetId === 'canonical-source', 'web section source reconstructs from canonical composition when Song mirror is cleared');
  assert(projected.sections[0].state === 'locked', 'web section state reconstructs from canonical composition');
  assert(projected.sections[0].conf === 0.9, 'web section confidence reconstructs from canonical composition');
  assert(projected.sections[0].note === 'approved source', 'web section note reconstructs from canonical composition');
  assert(projected.progress === 1, 'web progress reconstructs from canonical section state');
  assert(projected.risk === 'Master locked', 'web risk reconstructs from canonical section state');
})();

(function newestCompositionWinsRuntimeProjection() {
  const songs = [{ id: 's1', sections: [], masterAssetId: 'legacy' }];
  const compositions = [
    { id: 'old', songId: 's1', updatedAt: 10, outputAssetId: 'old-master', sections: [] },
    { id: 'new', songId: 's1', updatedAt: 20, outputAssetId: 'new-master', sections: [] }
  ];
  const projected = C.projectCanonicalSongs(songs, compositions);
  assert(projected[0].masterAssetId === 'new-master', 'newest canonical composition wins duplicate runtime cache entries');
})();

console.log('canonical-web tests passed');
