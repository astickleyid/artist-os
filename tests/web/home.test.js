require(require('path').join(__dirname,'../../docs/core.js'));
const C = globalThis.AOSCore;
const assert = require('assert');

const NOW = 1_000_000_000_000;
const day = 86400000;

// helpers
const song = (id, title) => ({ id, title, era: '2026', status: 'In Assembly', progress: 0, qualityScore: 0, risk: 'low', sections: [], masterAssetId: null });
const asset = (id, songId, extra={}) => ({ id, songId, title: id, file: id+'.wav', role: 'fullMix', created: NOW - day, modifiedAt: NOW - day, version: null, vOrder: null, ...extra });
const evt = (songId, t, summary) => ({ id: 'e'+Math.random(), songId, target: 'Song', op: 'Imported', summary, t, observed: true });

// --- momentum: recent song ranks above stale song ---
(function () {
  const s1 = song('s1', 'Fresh'), s2 = song('s2', 'Stale');
  const assets = [asset('a1','s1',{modifiedAt: NOW - day}), asset('a2','s2',{modifiedAt: NOW - day*30})];
  const events = [evt('s1', NOW - day, 'recent'), evt('s2', NOW - day*30, 'old')];
  const feed = C.buildHomeFeed([s2, s1], assets, events, { now: NOW });
  assert.equal(feed.inMotion[0].song.id, 's1', 'fresher song ranks first regardless of input order');
  assert(feed.inMotion[0].recency > feed.inMotion[1].recency, 'recency scores ordered');
  console.log('✓ momentum orders songs by recent activity');
})();

// --- needs-you floats a song up even if slightly staler ---
(function () {
  const s1 = song('s1', 'Quiet but blocked');
  const s2 = song('s2', 'Busy no decisions');
  // two full-mix versions on s1 with no master => a master decision
  const assets = [
    asset('v1','s1',{version:'v1',vOrder:1,modifiedAt: NOW - day*3}),
    asset('v2','s1',{version:'v2',vOrder:2,modifiedAt: NOW - day*3}),
    asset('a2','s2',{modifiedAt: NOW - day})
  ];
  const events = [evt('s2', NOW - day, 'busy')];
  const feed = C.buildHomeFeed([s1, s2], assets, events, { now: NOW });
  assert(feed.counts.decisions >= 1, 'decision detected');
  assert.equal(feed.inMotion[0].song.id, 's1', 'song needing a decision floats above a busier song');
  assert.equal(feed.inMotion[0].needsYou, true);
  console.log('✓ needs-you songs float to the top of In Motion');
})();

// --- just happened: only events after lastSeen, newest first, capped ---
(function () {
  const s1 = song('s1', 'S');
  const events = [];
  for (let i = 0; i < 12; i++) events.push(evt('s1', NOW - i*1000, 'evt'+i));
  const feed = C.buildHomeFeed([s1], [], events, { now: NOW, lastSeen: NOW - 5000, recentLimit: 6 });
  assert(feed.recentEvents.length <= 6, 'capped at recentLimit');
  assert(feed.recentEvents.every(e => e.t > NOW - 5000), 'only events after lastSeen');
  assert(feed.recentEvents[0].t >= feed.recentEvents[1].t, 'newest first');
  console.log('✓ just-happened filters by lastSeen, newest-first, capped');
})();

// --- empty catalog: no crash, empty sections ---
(function () {
  const feed = C.buildHomeFeed([], [], [], { now: NOW });
  assert.equal(feed.decisions.length, 0);
  assert.equal(feed.inMotion.length, 0);
  assert.equal(feed.recentEvents.length, 0);
  console.log('✓ empty catalog produces empty feed without error');
})();

console.log('home feed tests passed');
