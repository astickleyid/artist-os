/* Artist OS — structural segmentation (pure DSP, testable).
   Finds section boundaries via a self-similarity matrix + Foote novelty,
   then clusters repeated sections so recurring parts (hook/chorus) are
   recognized. Proposes labels with confidence; the artist confirms.
   Mirrors the librosa/Foote approach used across MIR research. */
(function (g) {
  "use strict";

  const audio = g.AOSAudio; // reuse chroma primitives if present

  /* ---------- chroma feature sequence ---------- */
  // 12-bin chroma per frame. Reuses the same Goertzel pitch-class approach as
  // key detection, but keeps the time axis instead of collapsing it.
  function chromaSequence(samples, sampleRate, hopSeconds) {
    const frame = 4096;
    const hop = Math.max(1, Math.round((hopSeconds || 0.5) * sampleRate));
    const freqs = [];
    for (let midi = 36; midi <= 83; midi++) {
      freqs.push({ pc: midi % 12, f: 440 * Math.pow(2, (midi - 69) / 12) });
    }
    const frames = [];
    for (let start = 0; start + frame <= samples.length; start += hop) {
      const chroma = new Float64Array(12);
      for (const { pc, f } of freqs) {
        if (f > sampleRate / 2 - 100) continue;
        // Goertzel magnitude at f over this frame
        const w = 2 * Math.PI * f / sampleRate;
        const coeff = 2 * Math.cos(w);
        let s1 = 0, s2 = 0;
        for (let i = 0; i < frame; i++) {
          const s0 = samples[start + i] + coeff * s1 - s2;
          s2 = s1; s1 = s0;
        }
        chroma[pc] += Math.sqrt(Math.max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2));
      }
      // L2 normalize each frame so similarity is about shape, not loudness
      let norm = 0;
      for (let i = 0; i < 12; i++) norm += chroma[i] * chroma[i];
      norm = Math.sqrt(norm) || 1;
      for (let i = 0; i < 12; i++) chroma[i] /= norm;
      frames.push(chroma);
    }
    return frames;
  }

  function cosine(a, b) {
    let dot = 0;
    for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
    return dot; // frames are already L2-normalized
  }

  /* ---------- Foote novelty curve ---------- */
  // Correlate a checkerboard (Gaussian-tapered) kernel down the SSM diagonal.
  // Peaks mark where the music's self-similarity structure flips = boundaries.
  function noveltyCurve(frames, kernelHalf) {
    const n = frames.length;
    const L = kernelHalf || Math.max(4, Math.round(n * 0.06));
    // Precompute checkerboard kernel with Gaussian taper
    const size = 2 * L;
    const kernel = [];
    const sigma = L / 2;
    for (let i = 0; i < size; i++) {
      kernel[i] = [];
      for (let j = 0; j < size; j++) {
        const di = i - L + 0.5, dj = j - L + 0.5;
        const gauss = Math.exp(-(di * di + dj * dj) / (2 * sigma * sigma));
        const sign = ((i < L) === (j < L)) ? 1 : -1; // checkerboard
        kernel[i][j] = sign * gauss;
      }
    }
    const novelty = new Float64Array(n);
    for (let c = 0; c < n; c++) {
      let sum = 0;
      for (let i = 0; i < size; i++) {
        const fi = c - L + i;
        if (fi < 0 || fi >= n) continue;
        for (let j = 0; j < size; j++) {
          const fj = c - L + j;
          if (fj < 0 || fj >= n) continue;
          sum += kernel[i][j] * cosine(frames[fi], frames[fj]);
        }
      }
      novelty[c] = Math.max(0, sum);
    }
    // normalize 0..1
    let max = 0;
    for (let i = 0; i < n; i++) if (novelty[i] > max) max = novelty[i];
    if (max > 0) for (let i = 0; i < n; i++) novelty[i] /= max;
    return novelty;
  }

  /* ---------- peak picking -> boundaries ---------- */
  function pickPeaks(novelty, hopSeconds, opts) {
    opts = opts || {};
    const minGapFrames = Math.max(1, Math.round((opts.minSectionSeconds || 6) / hopSeconds));
    const threshold = opts.threshold != null ? opts.threshold : 0.22;
    const n = novelty.length;
    const peaks = [];
    for (let i = 1; i < n - 1; i++) {
      if (novelty[i] < threshold) continue;
      if (novelty[i] >= novelty[i - 1] && novelty[i] > novelty[i + 1]) {
        if (!peaks.length || i - peaks[peaks.length - 1] >= minGapFrames) {
          peaks.push(i);
        } else if (novelty[i] > novelty[peaks[peaks.length - 1]]) {
          peaks[peaks.length - 1] = i; // keep the stronger of two close peaks
        }
      }
    }
    return peaks;
  }

  /* ---------- segments + repetition clustering ---------- */
  function averageChroma(frames, from, to) {
    const avg = new Float64Array(12);
    for (let f = from; f < to; f++) for (let i = 0; i < 12; i++) avg[i] += frames[f][i];
    let norm = 0;
    for (let i = 0; i < 12; i++) norm += avg[i] * avg[i];
    norm = Math.sqrt(norm) || 1;
    for (let i = 0; i < 12; i++) avg[i] /= norm;
    return avg;
  }

  // Group segments whose average chroma is close => same recurring part.
  function clusterSegments(segments, simThreshold) {
    const thr = simThreshold != null ? simThreshold : 0.90;
    const clusters = [];
    for (const seg of segments) {
      let placed = false;
      for (const cl of clusters) {
        if (cosine(seg.chroma, cl.centroid) >= thr) {
          cl.members.push(seg);
          // update centroid (running mean, renormalized)
          for (let i = 0; i < 12; i++) cl.centroid[i] = (cl.centroid[i] * (cl.members.length - 1) + seg.chroma[i]) / cl.members.length;
          let norm = 0; for (let i = 0; i < 12; i++) norm += cl.centroid[i] * cl.centroid[i];
          norm = Math.sqrt(norm) || 1; for (let i = 0; i < 12; i++) cl.centroid[i] /= norm;
          seg.cluster = cl.id;
          placed = true;
          break;
        }
      }
      if (!placed) {
        const cl = { id: clusters.length, centroid: Float64Array.from(seg.chroma), members: [seg] };
        seg.cluster = cl.id;
        clusters.push(cl);
      }
    }
    return clusters;
  }

  /* ---------- label proposal heuristic ----------
     Honest: proposes, with confidence, for the artist to confirm.
     - The most-repeated cluster is very likely the hook/chorus.
     - First segment is usually an intro (esp. if short + unique).
     - Last unique segment is often an outro.
     - A unique segment late in the song (~60-80% through) is bridge-ish.
     - Remaining recurring-but-not-hook clusters read as verses. */
  function proposeLabels(segments, clusters, totalSeconds) {
    if (!segments.length) return segments;
    // rank clusters by repetition count
    const byCount = [...clusters].sort((a, b) => b.members.length - a.members.length);
    const hookCluster = byCount[0] && byCount[0].members.length >= 2 ? byCount[0].id : null;

    segments.forEach((seg, idx) => {
      const mid = (seg.start + seg.end) / 2;
      const posFrac = totalSeconds > 0 ? mid / totalSeconds : 0;
      const dur = seg.end - seg.start;
      const clusterSize = clusters[seg.cluster] ? clusters[seg.cluster].members.length : 1;

      let label = "Section", conf = 0.4;
      if (idx === 0 && dur < 20 && clusterSize === 1) { label = "Intro"; conf = 0.7; }
      else if (seg.cluster === hookCluster) { label = "Hook"; conf = 0.72; }
      else if (idx === segments.length - 1 && clusterSize === 1 && posFrac > 0.8) { label = "Outro"; conf = 0.6; }
      else if (clusterSize === 1 && posFrac >= 0.55 && posFrac <= 0.85) { label = "Bridge"; conf = 0.5; }
      else if (clusterSize >= 2) { label = "Verse"; conf = 0.55; }
      else { label = "Verse"; conf = 0.4; }

      seg.label = label;
      seg.confidence = conf;
    });
    return segments;
  }

  /* ---------- top-level ---------- */
  function segment(samples, sampleRate, opts) {
    opts = opts || {};
    const hopSeconds = opts.hopSeconds || 0.5;
    const frames = chromaSequence(samples, sampleRate, hopSeconds);
    if (frames.length < 8) {
      // too short to segment meaningfully
      const total = samples.length / sampleRate;
      return { sections: [{ start: 0, end: total, label: "Section", confidence: 0.3, cluster: 0 }],
               novelty: [], frameCount: frames.length };
    }
    const novelty = noveltyCurve(frames, opts.kernelHalf);
    const peakFrames = pickPeaks(novelty, hopSeconds, opts);
    const totalSeconds = samples.length / sampleRate;

    // boundaries -> [0, ...peaks, end]
    const bounds = [0, ...peakFrames.map(p => p * hopSeconds), totalSeconds];
    const segments = [];
    for (let i = 0; i < bounds.length - 1; i++) {
      const start = bounds[i], end = bounds[i + 1];
      const fromF = Math.floor(start / hopSeconds);
      const toF = Math.min(frames.length, Math.max(fromF + 1, Math.floor(end / hopSeconds)));
      segments.push({ start, end, chroma: averageChroma(frames, fromF, toF), cluster: 0 });
    }
    const clusters = clusterSegments(segments, opts.clusterThreshold);
    proposeLabels(segments, clusters, totalSeconds);

    // strip internal chroma from the returned shape (keep it lean/serializable)
    const sections = segments.map((s, i) => ({
      index: i, start: +s.start.toFixed(2), end: +s.end.toFixed(2),
      label: s.label, confidence: +s.confidence.toFixed(2), cluster: s.cluster
    }));
    return { sections, clusterCount: clusters.length, frameCount: frames.length };
  }

  g.AOSSegment = { segment, chromaSequence, noveltyCurve, pickPeaks, clusterSegments, proposeLabels };
})(typeof window !== "undefined" ? window : globalThis);
