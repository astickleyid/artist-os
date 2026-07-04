require('/home/claude/artist-os/docs/core.js');
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
