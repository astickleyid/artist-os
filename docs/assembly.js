/* Artist OS — cross-version assembly (the "verse from v1, hook from v3" engine).
   This file is the PURE recipe layer: it builds and validates an ordered plan
   of section-slices drawn from different versions, computes total duration,
   and flags seams (tempo/key mismatches between adjacent picks) so the artist
   picks with eyes open. The actual audio render (Web Audio) lives in app.js
   and consumes a validated plan from here. */
(function (g) {
  "use strict";

  // A "slot" is a structural position in the target master (Intro, Verse, Hook...).
  // A "pick" fills a slot with a specific section-slice from a specific asset:
  //   { slotId, label, assetId, start, end, bpm, keyName }
  // A "recipe" is an ordered list of picks.

  function sliceDuration(pick) {
    return Math.max(0, (pick.end || 0) - (pick.start || 0));
  }

  function totalDuration(recipe) {
    return recipe.reduce((n, p) => n + sliceDuration(p) + (p.crossfade || 0) * 0, 0);
  }

  // Detect seams between adjacent picks: a tempo jump or key change means the
  // rendered cut won't beat-match. We don't fix it in v1 (honest cuts +
  // crossfade), but we surface it so the pick is informed.
  function seamsFor(recipe, opts) {
    opts = opts || {};
    const bpmTolerance = opts.bpmTolerance != null ? opts.bpmTolerance : 2;
    const seams = [];
    for (let i = 1; i < recipe.length; i++) {
      const prev = recipe[i - 1], cur = recipe[i];
      const issues = [];
      if (prev.bpm && cur.bpm && Math.abs(prev.bpm - cur.bpm) > bpmTolerance) {
        issues.push({ type: "tempo", from: prev.bpm, to: cur.bpm,
          detail: `${Math.round(prev.bpm)} → ${Math.round(cur.bpm)} BPM` });
      }
      if (prev.keyName && cur.keyName && prev.keyName !== cur.keyName) {
        issues.push({ type: "key", from: prev.keyName, to: cur.keyName,
          detail: `${prev.keyName} → ${cur.keyName}` });
      }
      if (issues.length) seams.push({ betweenIndex: i - 1, at: i, issues });
    }
    return seams;
  }

  // Validate a recipe is renderable. Returns { ok, errors, warnings }.
  function validateRecipe(recipe, opts) {
    const errors = [], warnings = [];
    if (!Array.isArray(recipe) || recipe.length === 0) {
      errors.push("Add at least one section to build a version.");
      return { ok: false, errors, warnings };
    }
    recipe.forEach((p, i) => {
      if (!p.assetId) errors.push(`Section ${i + 1} has no source version selected.`);
      if (sliceDuration(p) <= 0) errors.push(`Section ${i + 1} (${p.label || "?"}) has zero length.`);
    });
    const seams = seamsFor(recipe, opts);
    for (const s of seams) {
      for (const issue of s.issues) {
        warnings.push(`Seam at section ${s.at + 1}: ${issue.detail} — cut will not beat-match.`);
      }
    }
    return { ok: errors.length === 0, errors, warnings, seams };
  }

  // Build a starting recipe from a set of proposed slots, defaulting each slot
  // to the best available source (the master/latest version that has it).
  function buildDefaultRecipe(slots) {
    return slots.map(slot => ({
      slotId: slot.slotId || slot.id,
      label: slot.label || slot.name,
      assetId: slot.defaultAssetId || null,
      start: slot.start || 0,
      end: slot.end || 0,
      bpm: slot.bpm || null,
      keyName: slot.keyName || null,
      crossfade: slot.crossfade != null ? slot.crossfade : 0.04
    }));
  }

  // Group all section-slices across versions by label, so the UI can present
  // "every Chorus, from every version, in one folder" (the unified folders).
  // slices: [{ assetId, assetTitle, version, label, start, end, bpm, keyName }]
  function unifiedFolders(slices) {
    const folders = new Map();
    for (const s of slices) {
      const key = s.label || "Section";
      if (!folders.has(key)) folders.set(key, { label: key, items: [] });
      folders.get(key).items.push(s);
    }
    // stable order: Intro, Verse, Hook/Chorus, Bridge, Outro, then others
    const order = ["Intro", "Verse", "Hook", "Chorus", "Bridge", "Outro"];
    return Array.from(folders.values()).sort((a, b) => {
      const ai = order.indexOf(a.label), bi = order.indexOf(b.label);
      return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi) || a.label.localeCompare(b.label);
    });
  }

  g.AOSAssembly = {
    sliceDuration, totalDuration, seamsFor, validateRecipe,
    buildDefaultRecipe, unifiedFolders
  };
})(typeof window !== "undefined" ? window : globalThis);
