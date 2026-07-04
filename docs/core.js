/* Artist OS — core domain logic (pure, testable) */
(function (g) {
  "use strict";

  const ROLES = {
    beat: "Beat", leadVocal: "Lead Vocal", hook: "Hook",
    bridge: "Bridge", fullMix: "Full Mix", reference: "Reference"
  };

  const STATES = {
    locked: { label: "Locked", tint: "var(--green)" },
    candidate: { label: "Candidate", tint: "var(--gold)" },
    needsDecision: { label: "Needs Decision", tint: "var(--gold)" },
    experiment: { label: "Experiment", tint: "var(--blue)" },
    open: { label: "Open", tint: "var(--muted)" }
  };

  const OPS = ["Imported", "Source Selected", "Candidate Added", "Approved",
    "Needs Decision", "Recording Updated", "Structure Updated", "Archived"];
  const TARGETS = ["Song", "Intro", "Verse", "Hook", "Bridge", "Beat", "Lead Vocal", "Mix"];

  const AUDIO_EXT = new Set(["wav", "aif", "aiff", "mp3", "m4a", "flac", "caf", "ogg", "aac", "opus", "webm"]);

  function extOf(name) {
    const i = name.lastIndexOf(".");
    return i > 0 ? name.slice(i + 1).toLowerCase() : "";
  }

  function isAudioName(name) {
    return AUDIO_EXT.has(extOf(name));
  }

  function titleize(raw, stripExtension = true) {
    let base = raw;
    if (stripExtension) {
      const i = raw.lastIndexOf(".");
      if (i > 0 && !raw.slice(i + 1).includes(" ")) base = raw.slice(0, i);
    }
    const collapsed = base.replace(/[_-]+/g, " ").split(/\s+/).filter(Boolean).join(" ");
    return collapsed || raw;
  }

  function inferRole(filename) {
    const n = filename.toLowerCase();
    if (n.includes("beat") || n.includes("instrumental") || n.includes("inst.")) return "beat";
    if (n.includes("hook") || n.includes("chorus")) return "hook";
    if (n.includes("bridge")) return "bridge";
    if (n.includes("vocal") || n.includes("vox") || n.includes("acapella") || n.includes("verse")) return "leadVocal";
    if (n.includes("ref")) return "reference";
    return "fullMix";
  }

  /* Grouping rule (matches the macOS app): first path component under the
     picked root becomes the song; loose files group under the root name. */
  function groupForPath(relativePath, rootName) {
    const parts = String(relativePath || "").split("/").filter(Boolean);
    // webkitRelativePath includes the picked folder itself as parts[0]
    const inside = parts.length > 1 && parts[0] === rootName ? parts.slice(1) : parts;
    return inside.length > 1 ? inside[0] : rootName;
  }

  /* -------- filename intelligence: versions + canonical song titles -------- */
  const VERSION_WORDS = new Set(["final","master","mix","mixdown","bounce","bounced","draft","take",
    "rough","demo","version","ver","v","edit","export","render","copy","alt","revision","rev",
    "new","update","updated","latest","old","wip"]);

  function isVersionToken(w) {
    const t = w.toLowerCase().replace(/[()]/g, "");
    if (!t) return false;
    if (/^\d{1,3}$/.test(t)) return true;                    // 2, (3)
    if (/^v(er)?\.?\d{1,3}$/.test(t)) return true;           // v2, ver3
    if (VERSION_WORDS.has(t)) return true;                   // final, master
    const m = t.match(/^([a-z]+)(\d{1,3})$/);                // mix2, take1, final3
    return !!(m && VERSION_WORDS.has(m[1]));
  }
  function versionNumber(w) {
    const t = w.toLowerCase().replace(/[()]/g, "");
    let m = t.match(/^v(?:er)?\.?(\d{1,3})$/); if (m) return { n: +m[1], strength: 3 };
    m = t.match(/^([a-z]+)(\d{1,3})$/); if (m && VERSION_WORDS.has(m[1])) return { n: +m[2], strength: 2 };
    if (/^\d{1,3}$/.test(t)) return { n: +t, strength: 1 };
    return null;
  }

  /* Parse "baddest times (apple master)_2.m4a" ->
     { canonical:"baddest times", label:"apple master 2", order:2 } */
  function parseVersion(raw) {
    let base = titleize(raw); // extension stripped, separators normalized
    const labelParts = [];
    let order = null, strength = 0;

    // Interleave stripping of trailing loose tokens and trailing
    // parentheticals until neither applies (handles "name(apple master)_1").
    const noteNumber = t => { const v = versionNumber(t); if (v && v.strength >= strength) { order = v.n; strength = v.strength; } };
    let changed = true;
    while (changed) {
      changed = false;
      const m = base.match(/\(([^()]*)\)\s*$/);
      if (m) {
        const inner = m[1].trim();
        const toks = inner.split(/\s+/).filter(Boolean);
        const versionish = toks.length && (toks.every(t => /^\d{1,3}$/.test(t)) || toks.some(isVersionToken));
        if (versionish) {
          labelParts.unshift(inner);
          toks.forEach(noteNumber);
          base = base.slice(0, m.index).trim();
          changed = true;
          continue;
        }
      }
      const words = base.split(/\s+/).filter(Boolean);
      if (words.length > 1 && isVersionToken(words[words.length - 1])) {
        const w = words.pop();
        labelParts.unshift(w.replace(/[()]/g, ""));
        noteNumber(w);
        base = words.join(" ");
        changed = true;
      }
    }
    let canonical = base.replace(/[\s\-_.]+$/, "").trim();
    if (canonical.length < 2 || /^\d+$/.test(canonical)) {
      canonical = titleize(raw); // voice-memo style names: don't over-strip
      return { canonical, label: null, order: null };
    }
    return { canonical, label: labelParts.length ? labelParts.join(" ") : null, order };
  }

  /* Cluster filenames into proposed songs: [{title, files:[...]}] */
  function clusterByCanonical(names) {
    const map = new Map();
    names.forEach((name, i) => {
      const pv = parseVersion(name);
      const key = pv.canonical.toLowerCase();
      if (!map.has(key)) map.set(key, { title: pv.canonical, indices: [], versions: 0 });
      const g = map.get(key);
      g.indices.push(i);
      if (pv.label || pv.order != null) g.versions++;
    });
    return Array.from(map.values());
  }

  function targetForName(name) {
    const n = String(name).toLowerCase();
    if (n.includes("intro")) return "Intro";
    if (n.includes("verse")) return "Verse";
    if (n.includes("hook") || n.includes("chorus")) return "Hook";
    if (n.includes("bridge")) return "Bridge";
    return "Song";
  }

  function targetForRole(role) {
    return ({
      fullMix: "Mix", leadVocal: "Lead Vocal", beat: "Beat",
      hook: "Hook", bridge: "Bridge", reference: "Song"
    })[role] || "Song";
  }

  function opForState(stateKey) {
    return ({
      locked: "Approved", needsDecision: "Needs Decision",
      candidate: "Candidate Added", experiment: "Structure Updated", open: "Structure Updated"
    })[stateKey] || "Structure Updated";
  }

  function progressOf(song) {
    const n = song.sections.length;
    if (!n) return 0;
    return song.sections.filter(x => x.state === "locked").length / n;
  }

  function riskOf(song) {
    const und = song.sections.filter(x => x.state === "needsDecision").map(x => x.name);
    if (und.length) return und.join(", ") + " decision unresolved";
    return progressOf(song) === 1 ? "Master locked" : "In assembly";
  }

  /* Assign an asset to a section. Returns {changed, promoted}. Mutates section. */
  function applyAssign(section, assetId) {
    const before = section.assetId || null;
    const next = assetId || null;
    if (before === next) return { changed: false, promoted: false };
    section.assetId = next;
    let promoted = false;
    if (next && section.state === "open") {
      section.state = "candidate";
      section.conf = Math.max(section.conf || 0, 0.5);
      promoted = true;
    }
    return { changed: true, promoted };
  }

  function applyState(section, key) {
    if (section.state === key) return false;
    section.state = key;
    if (key === "locked") section.conf = Math.max(section.conf || 0, 0.9);
    return true;
  }

  /* Duplicate partition by content hash (assets without hash pass through). */
  function partitionDuplicates(items, existingHashes) {
    const seen = new Set(existingHashes);
    const unique = [];
    let duplicateCount = 0;
    for (const it of items) {
      if (it.hash) {
        if (seen.has(it.hash)) { duplicateCount++; continue; }
        seen.add(it.hash);
      }
      unique.push(it);
    }
    return { unique, duplicateCount };
  }

  function defaultSections(mkId) {
    return [
      { id: mkId(), name: "Intro", role: "Atmosphere", assetId: null, state: "open", conf: 0, note: "" },
      { id: mkId(), name: "Verse 1", role: "Lead vocal", assetId: null, state: "open", conf: 0, note: "" },
      { id: mkId(), name: "Hook", role: "Melody", assetId: null, state: "open", conf: 0, note: "" },
      { id: mkId(), name: "Bridge", role: "Alt pocket", assetId: null, state: "open", conf: 0, note: "" },
      { id: mkId(), name: "Outro", role: "Space", assetId: null, state: "open", conf: 0, note: "" }
    ];
  }

  function mmss(t) {
    t = Math.max(0, Math.round(t || 0));
    return (Math.floor(t / 60)) + ":" + String(t % 60).padStart(2, "0");
  }

  function agoFrom(nowMs, t) {
    const MIN = 6e4, HR = 36e5, DAY = 864e5;
    const d = nowMs - t;
    if (d < MIN) return "now";
    if (d < HR) return Math.floor(d / MIN) + "m ago";
    if (d < DAY) return Math.floor(d / HR) + "h ago";
    return Math.floor(d / DAY) + "d ago";
  }

  /* -------- version stack ordering (shared by all surfaces) -------- */
  function sortVersions(assets) {
    return [...assets].sort((a, b) => {
      const av = a.vOrder != null ? a.vOrder : -1, bv = b.vOrder != null ? b.vOrder : -1;
      if (av !== bv) return bv - av;
      if ((a.modifiedAt || 0) !== (b.modifiedAt || 0)) return (b.modifiedAt || 0) - (a.modifiedAt || 0);
      return (b.created || 0) - (a.created || 0);
    });
  }
  function versionStack(assets) {
    return sortVersions(assets.filter(a => a.version || a.vOrder != null));
  }
  /* Master decisions consider only full-mix bounces: a hook take and a beat
     both labeled "v1" are not versions of each other. */
  function masterStack(assets) {
    return versionStack(assets).filter(a => a.role === "fullMix");
  }

  /* -------- decision engine v1 --------
     The app proposes, the artist approves. Two deterministic rules:
     D1 — competing takes: >=2 assets of a decisive role escalate the matching
          slot to Needs Decision (escalate-only, fires once).
     D2 — master version: a stack of >=2 versions needs a pinned master; a
          newer version than the pinned master re-opens the question.      */
  const DECISIVE_ROLES = { hook: "Hook", bridge: "Bridge", leadVocal: "Verse" };

  function applyAutoDecisions(song, assets) {
    const fired = [];
    for (const [role, slotTarget] of Object.entries(DECISIVE_ROLES)) {
      const candidates = assets.filter(a => a.role === role);
      if (candidates.length < 2) continue;
      for (const slot of song.sections) {
        if (targetForName(slot.name) !== slotTarget) continue;
        if (!["open", "candidate", "experiment"].includes(slot.state)) continue;
        slot.state = "needsDecision";
        slot.conf = Math.max(slot.conf || 0, 0.5);
        fired.push({ slotId: slot.id, slotName: slot.name, role, count: candidates.length });
      }
    }
    return fired;
  }

  function decisionsFor(song, assets) {
    const out = [];
    for (const slot of song.sections) {
      if (slot.state === "needsDecision") {
        out.push({ kind: "slot", slotId: slot.id, songId: song.id,
          title: `${slot.name} — ${song.title}`, detail: "Candidates waiting on a call" });
      }
    }
    const stack = masterStack(assets);
    if (stack.length >= 2) {
      const top = stack[0];
      if (!song.masterAssetId) {
        out.push({ kind: "master", songId: song.id, title: `Current master — ${song.title}`,
          detail: `${stack.length} versions stacked, none pinned as master` });
      } else if (song.masterAssetId !== top.id && stack.some(a => a.id === song.masterAssetId)) {
        out.push({ kind: "master", songId: song.id, title: `New version — ${song.title}`,
          detail: `${top.version ? top.version : "A newer version"} challenges the pinned master` });
      }
    }
    return out;
  }

  g.AOSCore = {
    ROLES, STATES, OPS, TARGETS, AUDIO_EXT,
    extOf, isAudioName, titleize, inferRole, groupForPath,
    targetForName, targetForRole, opForState,
    progressOf, riskOf, applyAssign, applyState,
    partitionDuplicates, defaultSections, mmss, agoFrom,
    parseVersion, clusterByCanonical, isVersionToken,
    sortVersions, versionStack, masterStack, applyAutoDecisions, decisionsFor, DECISIVE_ROLES
  };
})(typeof window !== "undefined" ? window : globalThis);
