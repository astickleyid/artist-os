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

  g.AOSCore = {
    ROLES, STATES, OPS, TARGETS, AUDIO_EXT,
    extOf, isAudioName, titleize, inferRole, groupForPath,
    targetForName, targetForRole, opForState,
    progressOf, riskOf, applyAssign, applyState,
    partitionDuplicates, defaultSections, mmss, agoFrom
  };
})(typeof window !== "undefined" ? window : globalThis);
