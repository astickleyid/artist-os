require(require('path').join(__dirname,'../../docs/audio-intel.js'));
require(require('path').join(__dirname,'../../docs/segment.js'));
const S = globalThis.AOSSegment;
const assert = require('assert');
const SR = 8000; // low rate keeps the O(n^2) SSM fast in tests

// Build a synthetic song with KNOWN structure by giving each section a
// distinct chord (chroma signature). Recurring sections reuse the same chord.
// Structure: Intro | Verse | HOOK | Verse | HOOK | Bridge | HOOK
function chord(freqs, seconds) {
  const out = new Float32Array(Math.floor(SR * seconds));
  for (let i = 0; i < out.length; i++) {
    let s = 0;
    for (const f of freqs) s += Math.sin(2 * Math.PI * f * i / SR);
    out[i] = s / freqs.length * 0.8;
  }
  return out;
}
// distinct chords
const CIntro  = chord([131, 165, 196], 6);   // C major-ish, short
const CVerse  = chord([147, 175, 220], 10);  // D minor-ish
const CHook   = chord([196, 247, 294], 10);  // G major-ish (the recurring part)
const CBridge = chord([175, 208, 262], 8);   // F-ish, unique, late

function concat(arrs) {
  const total = arrs.reduce((n, a) => n + a.length, 0);
  const out = new Float32Array(total);
  let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
}

const song = concat([CIntro, CVerse, CHook, CVerse, CHook, CBridge, CHook]);
// section boundaries in seconds: 0,6,16,26,36,46,54,64
const result = S.segment(song, SR, { hopSeconds: 0.5, minSectionSeconds: 4 });

console.log('detected', result.sections.length, 'sections:');
result.sections.forEach(s => console.log(`  ${s.start.toFixed(1)}-${s.end.toFixed(1)}s  ${s.label} (conf ${s.confidence}, cluster ${s.cluster})`));

// --- assertions ---
// Should find roughly 7 sections (allow 5-9 given detection tolerance)
assert(result.sections.length >= 5 && result.sections.length <= 9,
  'finds a plausible number of sections (got ' + result.sections.length + ')');

// The recurring hook chord appears 3x — its cluster should have the most members.
const clusterCounts = {};
result.sections.forEach(s => clusterCounts[s.cluster] = (clusterCounts[s.cluster] || 0) + 1);
const maxCluster = Object.entries(clusterCounts).sort((a,b) => b[1]-a[1])[0];
assert(maxCluster[1] >= 2, 'the recurring section is detected as repeating (cluster appears >=2x)');
console.log('✓ recurring section clustered (' + maxCluster[1] + ' repeats)');

// At least one section proposed as Hook, and it should be the repeating one
const hooks = result.sections.filter(s => s.label === 'Hook');
assert(hooks.length >= 1, 'proposes at least one Hook');
assert(hooks.length >= 2, 'the repeated part is labeled Hook across its repeats');
console.log('✓ repeated part proposed as Hook (' + hooks.length + 'x)');

// Boundaries should be monotonic and cover the whole track
for (let i = 1; i < result.sections.length; i++) {
  assert(result.sections[i].start >= result.sections[i-1].start, 'sections ordered');
}
assert(Math.abs(result.sections[result.sections.length-1].end - song.length/SR) < 1, 'covers full track');
console.log('✓ sections ordered and cover the full track');

// Every section carries a confidence for the confirm-UI
assert(result.sections.every(s => typeof s.confidence === 'number'), 'confidence on every section');
console.log('✓ confidence present on every proposal');

// Silence / tiny input degrades gracefully
const tiny = S.segment(new Float32Array(SR * 1), SR, {});
assert(tiny.sections.length >= 1, 'tiny input yields at least one section without crashing');
console.log('✓ tiny input handled gracefully');

console.log('\nsegmentation tests passed');
