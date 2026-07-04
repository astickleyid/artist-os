require(require('path').join(__dirname,'../../docs/sync.js'));
const S = globalThis.AOSSync;
const assert = require('assert');

// toChange: song
(function () {
  const song = { id: 's1', title: 'Night Drive', era: '2026', status: 'Review', progress: 0.5,
    qualityScore: 80, risk: 'low', sections: [{ id: 'x', name: 'Hook', state: 'open' }],
    masterAssetId: null, created: 1000, updatedAt: 1500, localOnlyJunk: 'nope' };
  const c = S.toChange('song', song);
  assert.equal(c.kind, 'song'); assert.equal(c.id, 's1'); assert.equal(c.updatedAt, 1500);
  assert.equal(c.data.title, 'Night Drive');
  assert.equal(c.data.localOnlyJunk, undefined, 'unlisted fields excluded');
  console.log('✓ toChange(song) picks known fields, drops junk');
})();

// toChange: falls back to created when no updatedAt
(function () {
  const c = S.toChange('event', { id: 'e1', t: 777, summary: 'x' });
  assert.equal(c.updatedAt, 777);
  console.log('✓ toChange falls back to t/created for updatedAt');
})();

// toChange: deletion tombstone
(function () {
  const c = S.toChange('asset', { id: 'a1' }, true);
  assert.equal(c.deleted, true);
  assert.equal(c.data, undefined);
  console.log('✓ toChange(deleted) produces a tombstone with no data');
})();

// applyRemoteChange: insert, update-if-newer, ignore-if-stale, delete
(function () {
  let list = [];
  list = S.applyRemoteChange(list, { kind: 'song', id: 's1', updatedAt: 100, data: { id: 's1', title: 'A' } });
  assert.equal(list.length, 1); assert.equal(list[0].title, 'A');

  list = S.applyRemoteChange(list, { kind: 'song', id: 's1', updatedAt: 50, data: { id: 's1', title: 'Stale' } });
  assert.equal(list[0].title, 'A', 'older remote update ignored');

  list = S.applyRemoteChange(list, { kind: 'song', id: 's1', updatedAt: 200, data: { id: 's1', title: 'B' } });
  assert.equal(list[0].title, 'B', 'newer remote update applied');

  list = S.applyRemoteChange(list, { kind: 'song', id: 's1', deleted: true });
  assert.equal(list.length, 0, 'tombstone removes the entity');

  list = S.applyRemoteChange(list, { kind: 'song', id: 's1', deleted: true });
  assert.equal(list.length, 0, 'deleting something already absent is a no-op');
  console.log('✓ applyRemoteChange: insert/newer-wins/stale-ignored/delete/delete-idempotent');
})();

// dirty tracker
(function () {
  const d = S.makeDirtyTracker();
  d.mark('song', 's1'); d.mark('asset', 'a1'); d.mark('song', 's1'); // dedup same key
  assert.equal(d.size, 2);
  const drained = d.drain();
  assert.equal(drained.length, 2);
  assert.equal(d.size, 0, 'drain clears the set');
  console.log('✓ dirty tracker dedups by kind:id and drains once');
})();

console.log('sync pure-logic tests passed');
