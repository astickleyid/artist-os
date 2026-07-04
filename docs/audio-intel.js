/* Artist OS — audio intelligence (pure DSP, testable; mirrors AudioAnalysis.swift) */
(function (g) {
  "use strict";

  /* ---------- tempo: onset-energy flux + autocorrelation ---------- */
  function detectBPM(samples, sampleRate) {
    const HOP = 512;
    const nFrames = Math.floor(samples.length / HOP);
    if (nFrames < 32) return null;

    // energy per hop, positive flux
    const flux = new Float32Array(nFrames);
    let prev = 0;
    for (let i = 0; i < nFrames; i++) {
      let e = 0;
      const off = i * HOP;
      for (let j = 0; j < HOP; j++) { const s = samples[off + j]; e += s * s; }
      flux[i] = Math.max(0, e - prev);
      prev = e;
    }
    // normalize
    let mean = 0;
    for (let i = 0; i < nFrames; i++) mean += flux[i];
    mean /= nFrames;
    if (mean <= 0) return null;
    for (let i = 0; i < nFrames; i++) flux[i] /= mean;

    const fps = sampleRate / HOP;
    const minLag = Math.max(2, Math.floor(fps * 60 / 190)); // 190 BPM
    const maxLag = Math.min(nFrames - 2, Math.ceil(fps * 60 / 55)); // 55 BPM
    if (maxLag <= minLag) return null;

    let bestLag = minLag, bestScore = -1, total = 0, count = 0;
    for (let lag = minLag; lag <= maxLag; lag++) {
      let score = 0;
      for (let i = 0; i + lag < nFrames; i++) score += flux[i] * flux[i + lag];
      score /= (nFrames - lag);
      total += score; count++;
      if (score > bestScore) { bestScore = score; bestLag = lag; }
    }
    let bpm = 60 * fps / bestLag;
    while (bpm < 70) bpm *= 2;
    while (bpm > 180) bpm /= 2;
    const avg = total / count;
    const confidence = avg > 0 ? Math.min(1, (bestScore / avg - 1) / 4) : 0;
    if (confidence < 0.05) return null;
    return { bpm: Math.round(bpm * 10) / 10, confidence: Math.round(confidence * 100) / 100 };
  }

  /* ---------- key: chromagram via Goertzel + Krumhansl-Schmuckler ---------- */
  const KS_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
  const KS_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
  const PITCH_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];

  function goertzelMag(samples, offset, length, freq, sampleRate) {
    const w = 2 * Math.PI * freq / sampleRate;
    const coeff = 2 * Math.cos(w);
    let s0 = 0, s1 = 0, s2 = 0;
    for (let i = 0; i < length; i++) {
      s0 = samples[offset + i] + coeff * s1 - s2;
      s2 = s1; s1 = s0;
    }
    return Math.sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2);
  }

  function correlation(a, b) {
    const n = a.length;
    let ma = 0, mb = 0;
    for (let i = 0; i < n; i++) { ma += a[i]; mb += b[i]; }
    ma /= n; mb /= n;
    let num = 0, da = 0, db = 0;
    for (let i = 0; i < n; i++) {
      const x = a[i] - ma, y = b[i] - mb;
      num += x * y; da += x * x; db += y * y;
    }
    const den = Math.sqrt(da * db);
    return den > 0 ? num / den : 0;
  }

  function detectKey(samples, sampleRate) {
    const FRAME = 4096, HOP = 2048;
    if (samples.length < FRAME * 2) return null;

    // pitch-class frequencies across octaves (C2..B5)
    const freqs = [];
    for (let midi = 36; midi <= 83; midi++) {
      freqs.push({ pc: midi % 12, f: 440 * Math.pow(2, (midi - 69) / 12) });
    }
    const chroma = new Float64Array(12);
    const nFrames = Math.floor((samples.length - FRAME) / HOP) + 1;
    for (let i = 0; i < nFrames; i++) {
      const off = i * HOP;
      for (const { pc, f } of freqs) {
        if (f > sampleRate / 2 - 100) continue;
        chroma[pc] += goertzelMag(samples, off, FRAME, f, sampleRate);
      }
    }
    const max = Math.max(...chroma);
    if (max <= 0) return null;
    const norm = Array.from(chroma, v => v / max);

    let best = null;
    for (let root = 0; root < 12; root++) {
      const rotate = profile => norm.map((_, i) => profile[(i - root + 12) % 12]);
      const cMaj = correlation(norm, rotate(KS_MAJOR));
      const cMin = correlation(norm, rotate(KS_MINOR));
      if (!best || cMaj > best.corr) best = { root, mode: "major", corr: cMaj };
      if (cMin > best.corr) best = { root, mode: "minor", corr: cMin };
    }
    if (!best || best.corr < 0.35) return null;
    return {
      key: PITCH_NAMES[best.root],
      mode: best.mode,
      name: `${PITCH_NAMES[best.root]} ${best.mode}`,
      confidence: Math.round(best.corr * 100) / 100
    };
  }

  /* Downsample by stride + optional center window; keeps analysis fast. */
  function prepare(samples, sampleRate, maxSeconds = 45, targetRate = 11025) {
    const stride = Math.max(1, Math.round(sampleRate / targetRate));
    const outRate = sampleRate / stride;
    let start = 0, end = samples.length;
    const maxLen = Math.floor(maxSeconds * sampleRate);
    if (end - start > maxLen) {
      start = Math.floor((end - maxLen) / 2);
      end = start + maxLen;
    }
    const out = new Float32Array(Math.floor((end - start) / stride));
    for (let i = 0; i < out.length; i++) out[i] = samples[start + i * stride];
    return { samples: out, sampleRate: outRate };
  }

  function analyze(samples, sampleRate) {
    const p = prepare(samples, sampleRate);
    return {
      tempo: detectBPM(p.samples, p.sampleRate),
      key: detectKey(p.samples, p.sampleRate)
    };
  }

  g.AOSAudio = { detectBPM, detectKey, analyze, prepare, PITCH_NAMES };
})(typeof window !== "undefined" ? window : globalThis);
