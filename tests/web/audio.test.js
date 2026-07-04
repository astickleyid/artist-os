require(require('path').join(__dirname,'../../docs/audio-intel.js'));
const A = globalThis.AOSAudio;
const assert = require('assert');
const SR = 22050;

// --- synthesize a 120 BPM click track (8s) ---
const clicks = new Float32Array(SR * 8);
for (let beat = 0; beat < 16; beat++) {
  const at = Math.floor(beat * 0.5 * SR);
  for (let i = 0; i < 400; i++) {
    clicks[at + i] = Math.sin(2 * Math.PI * 1000 * i / SR) * Math.exp(-i / 60);
  }
}
const tempo = A.detectBPM(clicks, SR);
assert(tempo, 'tempo detected');
assert(Math.abs(tempo.bpm - 120) <= 2, '120 BPM click detected, got ' + tempo.bpm);
assert(tempo.confidence > 0.1, 'confident on clean clicks: ' + tempo.confidence);
console.log('✓ BPM: ' + tempo.bpm + ' (conf ' + tempo.confidence + ')');

// --- 92 BPM as octave-fold check ---
const c2 = new Float32Array(SR * 8);
for (let beat = 0; beat < 12; beat++) {
  const at = Math.floor(beat * (60 / 92) * SR);
  for (let i = 0; i < 400; i++) c2[at + i] = Math.sin(2 * Math.PI * 900 * i / SR) * Math.exp(-i / 60);
}
const t2 = A.detectBPM(c2, SR);
assert(t2 && Math.abs(t2.bpm - 92) <= 2, '92 BPM detected, got ' + (t2 && t2.bpm));
console.log('✓ BPM: ' + t2.bpm);

// --- A minor triad (A3 220, C4 261.63, E4 329.63), 6s ---
const triad = new Float32Array(SR * 6);
for (const f of [220, 261.63, 329.63]) {
  for (let i = 0; i < triad.length; i++) triad[i] += Math.sin(2 * Math.PI * f * i / SR) / 3;
}
const key = A.detectKey(triad, SR);
assert(key, 'key detected');
assert(['A minor', 'C major'].includes(key.name), 'Am triad -> A minor (or relative C major), got ' + key.name);
console.log('✓ Key: ' + key.name + ' (conf ' + key.confidence + ')');

// --- G major triad (G3 196, B3 246.94, D4 293.66) ---
const g = new Float32Array(SR * 6);
for (const f of [196, 246.94, 293.66]) {
  for (let i = 0; i < g.length; i++) g[i] += Math.sin(2 * Math.PI * f * i / SR) / 3;
}
const gk = A.detectKey(g, SR);
assert(gk && ['G major', 'E minor'].includes(gk.name), 'G triad -> G major, got ' + (gk && gk.name));
console.log('✓ Key: ' + gk.name);

// --- silence/noise rejects gracefully ---
assert.equal(A.detectBPM(new Float32Array(SR * 4), SR), null, 'silence -> null tempo');
console.log('audio intelligence tests passed');
