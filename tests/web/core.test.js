require(require('path').join(__dirname,'../../docs/core.js'));
const C = globalThis.AOSCore;
const assert = require('assert');
let n = 0; const t = (name, fn) => { fn(); n++; };

t('audio detection', () => {
  assert(C.isAudioName('take1.WAV')); assert(C.isAudioName('a.m4a'));
  assert(!C.isAudioName('notes.txt')); assert(!C.isAudioName('noext'));
});
t('titleize', () => {
  assert.equal(C.titleize('beat_is-m9.wav'), 'beat is m9');
  assert.equal(C.titleize('Song A', false), 'Song A');
  assert.equal(C.titleize('  spaced   out  .mp3'), 'spaced out');
});
t('role inference', () => {
  assert.equal(C.inferRole('trap beat v3.wav'), 'beat');
  assert.equal(C.inferRole('Chorus idea.mp3'), 'hook');
  assert.equal(C.inferRole('verse 1 vox.m4a'), 'leadVocal');
  assert.equal(C.inferRole('final bounce.wav'), 'fullMix');
});
t('grouping matches native rule', () => {
  assert.equal(C.groupForPath('Career/Song A/take.wav', 'Career'), 'Song A');
  assert.equal(C.groupForPath('Career/Song A/stems/beat.wav', 'Career'), 'Song A');
  assert.equal(C.groupForPath('Career/loose.wav', 'Career'), 'Career');
  assert.equal(C.groupForPath('loose.wav', 'Career'), 'Career');
});
t('assign state machine', () => {
  const s = { assetId: null, state: 'open', conf: 0 };
  let r = C.applyAssign(s, 'x');
  assert(r.changed && r.promoted && s.state === 'candidate' && s.conf === 0.5);
  r = C.applyAssign(s, 'x');
  assert(!r.changed);
  assert(C.applyState(s, 'locked') && s.conf === 0.9);
  assert(!C.applyState(s, 'locked'));
  assert.equal(C.opForState('locked'), 'Approved');
  assert.equal(C.opForState('needsDecision'), 'Needs Decision');
});
t('progress + risk', () => {
  const song = { sections: [{state:'locked',name:'Intro'},{state:'open',name:'Hook'},{state:'needsDecision',name:'Bridge'}] };
  assert(Math.abs(C.progressOf(song) - 1/3) < 1e-9);
  assert(C.riskOf(song).includes('Bridge'));
});
t('dedup partition', () => {
  const r = C.partitionDuplicates(
    [{hash:'a'},{hash:'a'},{hash:'b'},{hash:null},{hash:'c'}], new Set(['b']));
  assert.equal(r.unique.length, 3);
  assert.equal(r.duplicateCount, 2);
});
t('targets', () => {
  assert.equal(C.targetForName('Verse 2'), 'Verse');
  assert.equal(C.targetForRole('fullMix'), 'Mix');
});
t('time helpers', () => {
  assert.equal(C.mmss(199), '3:19');
  assert.equal(C.agoFrom(1000000, 1000000 - 5*36e5), '5h ago');
  assert.equal(C.agoFrom(1000000, 999999), 'now');
});
console.log(n + ' core test groups passed');

// ---- version intelligence ----
(function(){
  const C = globalThis.AOSCore;
  const assert = require('assert');
  const pv = n => C.parseVersion(n);

  assert.deepEqual(pv('baddest times v1.m4a'), { canonical:'baddest times', label:'v1', order:1 });
  assert.equal(pv('baddest times v2.m4a').order, 2);
  assert.deepEqual(pv('baddest times(3).m4a'), { canonical:'baddest times', label:'3', order:3 });
  assert.equal(pv('baddest times final.m4a').canonical, 'baddest times');
  assert.equal(pv('baddest times final.m4a').label, 'final');
  assert.equal(pv('baddest times FINAL final.wav').canonical, 'baddest times');
  assert.equal(pv('baddest times mix2.wav').order, 2);
  assert.equal(pv('candidcamera(apple master)_1.m4a').canonical, 'candidcamera');
  assert.equal(pv('candidcamera(apple master)_1.m4a').order, 1);
  assert.equal(pv('golden state - master 3.wav').canonical, 'golden state');
  assert.equal(pv('golden state - master 3.wav').order, 3);
  // don't over-strip: short/numeric bases keep original
  assert.equal(pv('0412.m4a').canonical, '0412');
  assert.equal(pv('v2.wav').canonical, 'v2');
  // role words are NOT versions
  assert.equal(pv('golden hook take2.m4a').canonical, 'golden hook');

  const groups = C.clusterByCanonical([
    'night drive v1.wav','night drive v2.wav','Night Drive final.wav',
    'other song.wav','0412.m4a'
  ]);
  assert.equal(groups.length, 3);
  const nd = groups.find(g => g.title.toLowerCase() === 'night drive');
  assert.equal(nd.indices.length, 3);
  assert.equal(nd.versions, 3);
  console.log('version intelligence tests passed');
})();

// ---- decision engine ----
(function(){
  const C = globalThis.AOSCore;
  const assert = require('assert');
  const slot = (name, state) => ({ id: name, name, state, conf: 0 });
  const asset = (role, v, o) => ({ id: Math.random()+'', role, version: v, vOrder: o, created: 1, modifiedAt: 1 });

  // D1: two hooks escalate an open Hook slot, exactly once
  let song = { id:'s', title:'T', sections:[slot('Intro','locked'), slot('Hook','open')], masterAssetId:null };
  let assets = [asset('hook','v1',1), asset('hook','v2',2)];
  let fired = C.applyAutoDecisions(song, assets);
  assert.equal(fired.length, 1);
  assert.equal(song.sections[1].state, 'needsDecision');
  assert.equal(C.applyAutoDecisions(song, assets).length, 0); // idempotent
  // locked slots never touched
  song.sections[1].state = 'locked';
  assert.equal(C.applyAutoDecisions(song, assets).length, 0);

  // one hook only -> nothing
  song = { id:'s', title:'T', sections:[slot('Hook','open')], masterAssetId:null };
  assert.equal(C.applyAutoDecisions(song, [asset('hook','v1',1)]).length, 0);

  // D2: two versions, no master -> pending; pin latest -> resolved
  const v1 = asset('fullMix','v1',1), v2 = asset('fullMix','v2',2);
  song = { id:'s', title:'T', sections:[], masterAssetId:null };
  let d = C.decisionsFor(song, [v1, v2]);
  assert.equal(d.length, 1); assert.equal(d[0].kind, 'master');
  song.masterAssetId = v2.id;
  assert.equal(C.decisionsFor(song, [v1, v2]).length, 0);
  // newer version challenges pinned older master
  song.masterAssetId = v1.id;
  d = C.decisionsFor(song, [v1, v2]);
  assert.equal(d.length, 1);
  assert(d[0].detail.includes('challenges'));

  // stack ordering: vOrder desc, then modified
  const s = C.versionStack([asset('fullMix','v1',1), asset('fullMix','final',null), asset('fullMix','v3',3)]);
  assert.equal(s[0].version, 'v3');
  console.log('decision engine tests passed');
})();

// master stack requires fullMix role
(function(){
  const C = globalThis.AOSCore; const assert = require('assert');
  const a = (role, v, o) => ({ id: role+v, role, version: v, vOrder: o, created: 1, modifiedAt: 1 });
  const song = { id:'s', title:'T', sections:[], masterAssetId:null };
  // hook + beat "versions" are NOT a master decision
  assert.equal(C.decisionsFor(song, [a('hook','take1',1), a('beat','v1',1)]).length, 0);
  // two full mixes ARE
  assert.equal(C.decisionsFor(song, [a('fullMix','v1',1), a('fullMix','v2',2)]).length, 1);
  console.log('master-stack role gating passed');
})();
