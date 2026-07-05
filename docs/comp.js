/* Artist OS — Quick Swipe Comp engine (pure, testable).
   Modeled on Logic Pro's Quick Swipe Comping: multiple source "takes" (here,
   full versions of a song) share ONE timeline; swiping a time-range on a source
   makes that source active over that range. The comp is the assembled result —
   an ordered list of non-overlapping segments covering the timeline, each
   pointing at the source that wins there. Last swipe wins (Logic behavior).
   Boundaries feed the audio engine's crossfades and the offline render. */
(function (g) {
  "use strict";

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  // A comp: { duration, segments: [{sourceId, start, end}...] } fully covering
  // [0, duration], sorted, non-overlapping, adjacent same-source merged.
  function makeComp(duration, defaultSourceId) {
    return { duration, segments: [{ sourceId: defaultSourceId, start: 0, end: duration }] };
  }

  function mergeAdjacent(segments) {
    const out = [];
    for (const s of segments) {
      const last = out[out.length - 1];
      if (last && last.sourceId === s.sourceId && Math.abs(last.end - s.start) < 1e-6) {
        last.end = s.end;
      } else {
        out.push({ sourceId: s.sourceId, start: s.start, end: s.end });
      }
    }
    return out;
  }

  // Assign [from,to] to sourceId, splitting overlapped segments. Pure.
  function applySwipe(comp, sourceId, from, to) {
    const dur = comp.duration;
    from = clamp(Math.min(from, to), 0, dur);
    to = clamp(Math.max(from, to), 0, dur);
    if (to - from < 1e-6) return { duration: dur, segments: comp.segments.slice() };

    const result = [];
    for (const seg of comp.segments) {
      if (seg.end <= from || seg.start >= to) { result.push({ ...seg }); continue; }
      // keep the non-overlapping remainders of this segment
      if (seg.start < from) result.push({ sourceId: seg.sourceId, start: seg.start, end: from });
      if (seg.end > to) result.push({ sourceId: seg.sourceId, start: to, end: seg.end });
    }
    result.push({ sourceId, start: from, end: to });
    result.sort((a, b) => a.start - b.start);
    return { duration: dur, segments: mergeAdjacent(result) };
  }

  // Which source is active at time t.
  function sourceAt(comp, t) {
    for (const s of comp.segments) if (t >= s.start && t < s.end) return s.sourceId;
    const last = comp.segments[comp.segments.length - 1];
    return last ? last.sourceId : null;
  }

  // Transition times (interior boundaries only) — where crossfades happen.
  function boundaries(comp) {
    const b = [];
    for (let i = 1; i < comp.segments.length; i++) b.push(comp.segments[i].start);
    return b;
  }

  // How much of the timeline each source occupies (for the comp strip legend).
  function coverage(comp) {
    const map = {};
    for (const s of comp.segments) map[s.sourceId] = (map[s.sourceId] || 0) + (s.end - s.start);
    return map;
  }

  // Count of distinct sources actually used in the comp.
  function sourcesUsed(comp) {
    return new Set(comp.segments.map(s => s.sourceId)).size;
  }

  /* ---- loudness matching: per-source gain so the take is compared, not the volume ----
     rms: { sourceId: rmsValue }. Returns { sourceId: gainMultiplier } normalizing
     every source to the loudest source's RMS (never boosts above ~+12 dB). */
  function loudnessGains(rms) {
    const vals = Object.values(rms).filter(v => v > 0);
    if (!vals.length) return {};
    const target = Math.max(...vals);
    const gains = {};
    for (const id in rms) {
      const r = rms[id];
      gains[id] = r > 0 ? Math.min(4, target / r) : 1; // cap ~+12 dB
    }
    return gains;
  }

  g.AOSComp = { makeComp, applySwipe, sourceAt, boundaries, coverage, sourcesUsed, loudnessGains, mergeAdjacent };
})(typeof window !== "undefined" ? window : globalThis);
