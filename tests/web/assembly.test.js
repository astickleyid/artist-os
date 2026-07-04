require(require('path').join(__dirname,'../../docs/assembly.js'));
const A = globalThis.AOSAssembly;
const assert = require('assert');

// --- unified folders: every chorus across versions in one place ---
(function () {
  const slices = [
    { assetId:'v1', version:'v1', label:'Hook', start:16, end:26, bpm:120 },
    { assetId:'v2', version:'v2', label:'Hook', start:15, end:25, bpm:120 },
    { assetId:'v1', version:'v1', label:'Verse', start:6, end:16, bpm:120 },
    { assetId:'v3', version:'v3', label:'Bridge', start:46, end:54, bpm:120 },
    { assetId:'v2', version:'v2', label:'Verse', start:5, end:15, bpm:120 },
  ];
  const folders = A.unifiedFolders(slices);
  const hook = folders.find(f => f.label === 'Hook');
  assert.equal(hook.items.length, 2, 'both hooks gathered into the Hook folder');
  const verse = folders.find(f => f.label === 'Verse');
  assert.equal(verse.items.length, 2, 'both verses gathered');
  // ordering: Intro/Verse/Hook/Bridge... => Verse before Hook before Bridge
  const labels = folders.map(f => f.label);
  assert(labels.indexOf('Verse') < labels.indexOf('Hook'), 'folder order canonical');
  assert(labels.indexOf('Hook') < labels.indexOf('Bridge'), 'folder order canonical 2');
  console.log('✓ unified folders group section-slices by label, canonically ordered');
})();

// --- recipe duration ---
(function () {
  const recipe = [
    { slotId:'s1', label:'Verse', assetId:'v1', start:6, end:16 },   // 10s
    { slotId:'s2', label:'Hook',  assetId:'v3', start:16, end:26 },  // 10s
  ];
  assert.equal(A.totalDuration(recipe), 20, 'total duration sums slice lengths');
  console.log('✓ recipe duration computed');
})();

// --- seam detection: tempo + key mismatches across versions ---
(function () {
  const recipe = [
    { slotId:'s1', label:'Verse', assetId:'v1', start:0, end:10, bpm:92,  keyName:'A minor' },
    { slotId:'s2', label:'Hook',  assetId:'v3', start:0, end:10, bpm:120, keyName:'A minor' }, // tempo jump
    { slotId:'s3', label:'Bridge',assetId:'v2', start:0, end:8,  bpm:120, keyName:'C major' }, // key change
  ];
  const seams = A.seamsFor(recipe);
  assert.equal(seams.length, 2, 'two seams detected');
  assert(seams[0].issues.some(i => i.type === 'tempo'), 'tempo seam flagged');
  assert(seams[1].issues.some(i => i.type === 'key'), 'key seam flagged');
  console.log('✓ seams: tempo + key mismatches flagged for informed picking');
})();

// --- validation: empty, missing source, zero-length ---
(function () {
  assert.equal(A.validateRecipe([]).ok, false, 'empty recipe invalid');
  const bad = A.validateRecipe([{ slotId:'s1', label:'Verse', assetId:null, start:0, end:10 }]);
  assert.equal(bad.ok, false); assert(bad.errors[0].includes('no source'), 'missing source flagged');
  const zero = A.validateRecipe([{ slotId:'s1', label:'Verse', assetId:'v1', start:5, end:5 }]);
  assert.equal(zero.ok, false); assert(zero.errors.some(e => e.includes('zero length')), 'zero-length flagged');
  const good = A.validateRecipe([{ slotId:'s1', label:'Verse', assetId:'v1', start:0, end:10, bpm:120, keyName:'A minor' }]);
  assert.equal(good.ok, true, 'valid single-section recipe ok');
  console.log('✓ validation catches empty / missing-source / zero-length; passes valid');
})();

// --- warnings surface seams without blocking render ---
(function () {
  const recipe = [
    { slotId:'s1', label:'Verse', assetId:'v1', start:0, end:10, bpm:92 },
    { slotId:'s2', label:'Hook',  assetId:'v3', start:0, end:10, bpm:120 },
  ];
  const v = A.validateRecipe(recipe);
  assert.equal(v.ok, true, 'seams are warnings, not errors — render still allowed');
  assert(v.warnings.length >= 1, 'seam surfaced as a warning');
  console.log('✓ seams warn but do not block (honest cuts allowed)');
})();

// --- buildDefaultRecipe from proposed slots ---
(function () {
  const slots = [
    { id:'sl1', name:'Verse', defaultAssetId:'v1', start:6, end:16, bpm:120, keyName:'A minor' },
    { id:'sl2', name:'Hook',  defaultAssetId:'v1', start:16, end:26, bpm:120, keyName:'A minor' },
  ];
  const recipe = A.buildDefaultRecipe(slots);
  assert.equal(recipe.length, 2);
  assert.equal(recipe[0].assetId, 'v1');
  assert(recipe[0].crossfade > 0, 'default crossfade applied');
  console.log('✓ default recipe built from proposed slots');
})();

console.log('\nassembly tests passed');
