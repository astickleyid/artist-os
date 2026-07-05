require(require('path').join(__dirname,'../../docs/comp.js'));
const C = globalThis.AOSComp;
const assert = require('assert');
const segs = c => c.segments.map(s=>`${s.sourceId}[${s.start}-${s.end}]`).join(' ');

// start: one default source across the whole timeline
let comp = C.makeComp(100, 'v1');
assert.equal(comp.segments.length, 1);
assert.equal(C.sourceAt(comp, 50), 'v1');
console.log('✓ new comp is one default source over the timeline');

// swipe v2 across the middle -> v1 | v2 | v1
comp = C.applySwipe(comp, 'v2', 30, 60);
assert.equal(comp.segments.length, 3, segs(comp));
assert.deepEqual(comp.segments.map(s=>s.sourceId), ['v1','v2','v1']);
assert.equal(C.sourceAt(comp, 45), 'v2');
assert.equal(C.sourceAt(comp, 20), 'v1');
console.log('✓ swipe splits into v1|v2|v1:', segs(comp));

// swipe v3 overlapping the v2 region and beyond -> last swipe wins
comp = C.applySwipe(comp, 'v3', 50, 80);
assert.equal(C.sourceAt(comp, 55), 'v3', 'v3 overrides where it was swiped');
assert.equal(C.sourceAt(comp, 40), 'v2', 'earlier v2 survives outside overlap');
assert.equal(C.sourceAt(comp, 90), 'v1');
console.log('✓ overlapping swipe: last wins:', segs(comp));

// adjacent same-source merges (swipe v1 back over a spot next to v1)
let m = C.makeComp(100,'v1');
m = C.applySwipe(m,'v2',0,50);
m = C.applySwipe(m,'v2',50,100); // two v2 spans should merge into one
assert.equal(m.segments.length, 1, 'adjacent identical sources merge: '+segs(m));
assert.equal(m.segments[0].sourceId,'v2');
console.log('✓ adjacent same-source segments merge');

// boundaries reported at interior transitions
let b = C.makeComp(100,'v1');
b = C.applySwipe(b,'v2',30,60);
assert.deepEqual(C.boundaries(b), [30,60]);
console.log('✓ boundaries at 30 and 60 (crossfade points)');

// coverage + sourcesUsed
let cov = C.coverage(b);
assert.equal(cov.v1, 70); assert.equal(cov.v2, 30);
assert.equal(C.sourcesUsed(b), 2);
console.log('✓ coverage v1=70 v2=30, 2 sources used');

// full-range swipe replaces everything
let f = C.makeComp(100,'v1');
f = C.applySwipe(f,'v2',30,60);
f = C.applySwipe(f,'v3',0,100);
assert.equal(f.segments.length,1); assert.equal(f.segments[0].sourceId,'v3');
console.log('✓ full-range swipe replaces the whole comp');

// clamping + zero-length swipe is a no-op
let z = C.makeComp(100,'v1');
let z2 = C.applySwipe(z,'v2',50,50);
assert.equal(z2.segments.length,1,'zero-length swipe = no-op');
let z3 = C.applySwipe(z,'v2',-20,200); // clamps to 0..100
assert.equal(z3.segments[0].start,0); assert.equal(z3.segments[0].end,100);
console.log('✓ zero-length no-op + out-of-range clamps');

// loudness gains normalize to the loudest, capped
const g = C.loudnessGains({v1:0.1, v2:0.2, v3:0.05});
assert.equal(g.v2, 1, 'loudest = gain 1');
assert(Math.abs(g.v1-2)<1e-9, 'quieter v1 boosted x2');
assert(Math.abs(g.v3-4)<1e-9, 'much quieter capped at x4');
console.log('✓ loudness gains normalize to loudest, capped at ~+12dB');

console.log('\ncomp engine tests passed');
