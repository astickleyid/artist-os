/* Artist OS — web (local-first). All data stays on this device. */
(function () {
"use strict";
const C = window.AOSCore;
const $ = s => document.querySelector(s);
const $$ = s => Array.from(document.querySelectorAll(s));
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const uid = () => (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now().toString(36));
const now = () => Date.now();

/* ============================ IndexedDB ============================ */
const DB_NAME = "artist-os", DB_VER = 1;
let idb = null, memoryMode = false;

function openDB() {
  return new Promise(resolve => {
    if (!("indexedDB" in window)) { memoryMode = true; return resolve(null); }
    let req;
    try { req = indexedDB.open(DB_NAME, DB_VER); }
    catch (e) { memoryMode = true; return resolve(null); }
    req.onupgradeneeded = () => {
      const db = req.result;
      for (const store of ["songs", "assets", "events", "blobs", "kv"]) {
        if (!db.objectStoreNames.contains(store)) db.createObjectStore(store, { keyPath: store === "kv" ? "key" : "id" });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => { memoryMode = true; resolve(null); };
  });
}
function tx(store, mode, fn) {
  if (!idb) return Promise.resolve(undefined);
  return new Promise((resolve, reject) => {
    const t = idb.transaction(store, mode), s = t.objectStore(store);
    const out = fn(s);
    t.oncomplete = () => resolve(out && out.result !== undefined ? out.result : undefined);
    t.onerror = () => reject(t.error);
  });
}
const dbPut = (store, val) => tx(store, "readwrite", s => s.put(val)).catch(err => console.error("db put", store, err));
const dbDel = (store, key) => tx(store, "readwrite", s => s.delete(key)).catch(err => console.error("db del", store, err));
function dbAll(store) {
  if (!idb) return Promise.resolve([]);
  return new Promise(resolve => {
    const t = idb.transaction(store), req = t.objectStore(store).getAll();
    req.onsuccess = () => resolve(req.result || []);
    req.onerror = () => resolve([]);
  });
}
function dbGet(store, key) {
  if (!idb) return Promise.resolve(undefined);
  return new Promise(resolve => {
    const req = idb.transaction(store).objectStore(store).get(key);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => resolve(undefined);
  });
}

/* ============================ state ============================ */
const state = {
  songs: [], assets: [], events: [],
  tab: "songs", songId: null, songTab: "master",
  npAsset: null, importing: null, watchStatus: null
};
const song = () => state.songs.find(s => s.id === state.songId);
const byId = id => state.assets.find(a => a.id === id);
const songOf = a => state.songs.find(s => s.id === a.songId);
const assetsFor = id => C.sortVersions(state.assets.filter(a => a.songId === id));
const stackFor = id => C.versionStack(state.assets.filter(a => a.songId === id));
const masterStackFor = id => C.masterStack(state.assets.filter(a => a.songId === id));
const versionCount = id => masterStackFor(id).length;
const allDecisions = () => state.songs.flatMap(s => C.decisionsFor(s, state.assets.filter(a => a.songId === s.id)));
const existingHashes = () => new Set(state.assets.map(a => a.hash).filter(Boolean));

async function persistSong(s) { await dbPut("songs", s); }
async function persistAsset(a) { await dbPut("assets", a); }
function record(songId, target, op, summary, observed = false) {
  const e = { id: uid(), songId, target, op, summary, t: now(), observed };
  state.events.unshift(e);
  dbPut("events", e);
  return e;
}
function toast(msg) {
  const t = $("#toast"); t.textContent = msg; t.classList.add("show");
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("show"), 2600);
}

/* ============================ audio (real files) ============================ */
const blobURLs = new Map();
async function urlFor(asset) {
  if (asset.demo) return null;
  if (blobURLs.has(asset.id)) return blobURLs.get(asset.id);
  const rec = await dbGet("blobs", asset.id);
  if (!rec || !rec.blob) return null;
  const u = URL.createObjectURL(rec.blob);
  blobURLs.set(asset.id, u);
  return u;
}

/* Generative fallback synth — used only for demo-catalog assets that have no file. */
const DemoSynth = {
  ctx: null, nodes: [], timer: null, playing: false, startAt: 0, offset: 0,
  seedOf(a) { let h = 0; for (const c of a.id) h = (h * 33 + c.charCodeAt(0)) >>> 0; return h; },
  start(asset, offset) {
    if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (this.ctx.state === "suspended") this.ctx.resume();
    this.stop();
    this.offset = offset; this.startAt = this.ctx.currentTime; this.playing = true;
    const seed = this.seedOf(asset), bpm = 78 + seed % 18, spb = 60 / bpm;
    const root = [110, 98, 87.3, 123.5][seed % 4];
    const master = this.ctx.createGain(); master.gain.value = .2; master.connect(this.ctx.destination);
    const lp = this.ctx.createBiquadFilter(); lp.type = "lowpass"; lp.frequency.value = 1400; lp.connect(master);
    [1, 1.19, 1.5].forEach((m, i) => {
      const o = this.ctx.createOscillator(), g = this.ctx.createGain();
      o.type = "sawtooth"; o.frequency.value = root * 2 * m; o.detune.value = (i - 1) * 7;
      g.gain.value = .05; o.connect(g); g.connect(lp); o.start(); this.nodes.push(o, g);
    });
    let beat = 0;
    const tick = () => {
      if (!this.playing) return;
      const t = this.ctx.currentTime + .05;
      if (beat % 2 === 0) {
        const o = this.ctx.createOscillator(), g = this.ctx.createGain();
        o.frequency.setValueAtTime(120, t); o.frequency.exponentialRampToValueAtTime(40, t + .12);
        g.gain.setValueAtTime(.5, t); g.gain.exponentialRampToValueAtTime(.001, t + .16);
        o.connect(g); g.connect(master); o.start(t); o.stop(t + .2); this.nodes.push(o);
      }
      if (beat % 4 === 0) {
        const o = this.ctx.createOscillator(), g = this.ctx.createGain();
        o.type = "sine"; o.frequency.value = root;
        g.gain.setValueAtTime(.26, t); g.gain.exponentialRampToValueAtTime(.001, t + spb * 1.6);
        o.connect(g); g.connect(master); o.start(t); o.stop(t + spb * 1.8); this.nodes.push(o);
      }
      beat++;
    };
    tick(); this.timer = setInterval(tick, spb * 1000);
  },
  pos() { return this.playing ? this.offset + (this.ctx.currentTime - this.startAt) : this.offset; },
  stop() { this.nodes.forEach(n => { try { n.stop ? n.stop() : n.disconnect(); } catch (e) {} }); this.nodes = []; clearInterval(this.timer); this.playing = false; }
};

const Player = {
  el: new Audio(), mode: null, // "file" | "demo"
  init() {
    this.el.preload = "auto";
    this.el.addEventListener("ended", () => this.stop());
    this.el.addEventListener("timeupdate", () => renderNPTime());
    this.el.addEventListener("error", () => { if (this.mode === "file") { toast("Couldn't play this file"); this.stop(); } });
  },
  playing() { return this.mode === "demo" ? DemoSynth.playing : (this.mode === "file" && !this.el.paused); },
  pos() { return this.mode === "demo" ? DemoSynth.pos() : this.el.currentTime; },
  dur() { const a = state.npAsset; return a ? (a.dur || this.el.duration || 0) : 0; },
  async play(asset, offset = 0) {
    this.stopEngines();
    state.npAsset = asset;
    if (asset.demo) {
      this.mode = "demo";
      DemoSynth.start(asset, Math.min(offset, (asset.dur || 30) - .5));
    } else {
      this.mode = "file";
      const u = await urlFor(asset);
      if (!u) { toast("Audio file not found in library"); state.npAsset = null; this.mode = null; renderAll(false); return; }
      if (this.el.src !== u) this.el.src = u;
      const seek = () => { try { this.el.currentTime = offset; } catch (e) {} };
      if (this.el.readyState >= 1) seek();
      else this.el.addEventListener("loadedmetadata", seek, { once: true });
      const p = this.el.play();
      if (p && p.catch) p.catch(() => toast("Tap play again to start audio"));
    }
    renderAll(false);
  },
  pause() {
    if (this.mode === "demo") { DemoSynth.offset = DemoSynth.pos(); DemoSynth.stop(); }
    else this.el.pause();
    renderAll(false);
  },
  resume() {
    if (!state.npAsset) return;
    if (this.mode === "demo") DemoSynth.start(state.npAsset, DemoSynth.offset);
    else { const p = this.el.play(); if (p && p.catch) p.catch(() => {}); }
    renderAll(false);
  },
  toggle(asset) {
    if (state.npAsset && state.npAsset.id === asset.id) { this.playing() ? this.pause() : this.resume(); }
    else this.play(asset, 0);
  },
  switchTo(asset) {
    const p = this.pos(), was = this.playing();
    this.play(asset, Math.min(p, (asset.dur || p + 1) - .5)).then(() => { if (!was) this.pause(); });
  },
  seek(frac) {
    const a = state.npAsset; if (!a) return;
    const d = this.dur(); if (!d) return;
    if (this.mode === "demo") { const was = DemoSynth.playing; DemoSynth.start(a, frac * (a.dur || 30)); if (!was) this.pause(); }
    else { try { this.el.currentTime = frac * d; } catch (e) {} }
    renderNPTime();
  },
  stopEngines() { DemoSynth.stop(); this.el.pause(); },
  stop() {
    this.stopEngines(); this.mode = null; state.npAsset = null;
    try { this.el.removeAttribute("src"); this.el.load(); } catch (e) {}
    renderAll(false);
  }
};
Player.init();
setInterval(() => { if (state.npAsset) renderNPTime(); }, 400);

/* ============================ waveforms (real peaks) ============================ */
const PEAK_N = 72, PEAK_SIZE_CAP = 40 * 1024 * 1024;
const peakMem = new Map();
let decodeCtx = null;
function seededPeaks(id, n = PEAK_N) {
  let h = 0; for (const c of id) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  const out = [];
  for (let i = 0; i < n; i++) {
    h = (h * 1664525 + 1013904223) >>> 0;
    const r = h / 2 ** 32, env = .35 + .65 * Math.sin(Math.PI * i / n);
    out.push(Math.max(.08, r * env + .22 * Math.sin(i * .9) * (r > .5 ? 1 : .4)));
  }
  const m = Math.max(...out); return out.map(v => v / m);
}
async function peaksFor(asset) {
  if (peakMem.has(asset.id)) return peakMem.get(asset.id);
  if (asset.demo) { const p = seededPeaks(asset.id); peakMem.set(asset.id, p); return p; }
  const cached = await dbGet("kv", "peaks:" + asset.id);
  if (cached && cached.value) { peakMem.set(asset.id, cached.value); return cached.value; }
  const rec = await dbGet("blobs", asset.id);
  if (!rec || !rec.blob || rec.blob.size > PEAK_SIZE_CAP) return null;
  try {
    if (!decodeCtx) decodeCtx = new (window.AudioContext || window.webkitAudioContext)();
    const buf = await rec.blob.arrayBuffer();
    const audio = await decodeCtx.decodeAudioData(buf.slice(0));
    const ch = audio.getChannelData(0), per = Math.max(1, Math.floor(ch.length / PEAK_N));
    const out = new Array(PEAK_N).fill(0);
    for (let b = 0; b < PEAK_N; b++) {
      let mx = 0;
      const start = b * per, end = Math.min(ch.length, start + per);
      for (let i = start; i < end; i += 16) { const v = Math.abs(ch[i]); if (v > mx) mx = v; }
      out[b] = mx;
    }
    const m = Math.max(...out, .001);
    const norm = out.map(v => Math.max(.06, v / m));
    peakMem.set(asset.id, norm);
    dbPut("kv", { key: "peaks:" + asset.id, value: norm });
    return norm;
  } catch (e) { return null; }
}
function roundRect(g, x, y, w, h, r) {
  g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r);
  g.arcTo(x + w, y + h, x, y + h, r); g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r);
  g.closePath(); g.fill();
}
function paintWave(canvas, pk, tint) {
  const dpr = devicePixelRatio || 1, w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w) return;
  canvas.width = w * dpr; canvas.height = h * dpr;
  const g = canvas.getContext("2d"); g.scale(dpr, dpr);
  if (!pk) {
    g.fillStyle = "rgba(255,255,255,.05)"; roundRect(g, 0, h / 2 - 2, w, 4, 2); return;
  }
  const bw = w / pk.length; g.fillStyle = tint || "#D6AE5C"; g.globalAlpha = .88;
  pk.forEach((p, i) => roundRect(g, i * bw + bw * .16, (h - Math.max(2, p * h)) / 2, bw * .68, Math.max(2, p * h), bw * .3));
}
async function drawWaves(root) {
  for (const c of (root || document).querySelectorAll("canvas[data-wave]")) {
    const a = byId(c.dataset.wave); if (!a) continue;
    paintWave(c, peakMem.get(a.id) || (a.demo ? seededPeaks(a.id) : null), c.dataset.tint);
    if (!peakMem.has(a.id) && !a.demo) {
      peaksFor(a).then(p => { if (p && c.isConnected) paintWave(c, p, c.dataset.tint); });
    }
  }
}

/* ============================ hashing / metadata ============================ */
async function hashFile(file) {
  if (!crypto.subtle) return null;
  try {
    const head = await file.slice(0, 512 * 1024).arrayBuffer();
    const tail = file.size > 512 * 1024 ? await file.slice(-512 * 1024).arrayBuffer() : new ArrayBuffer(0);
    const sizeBuf = new TextEncoder().encode(String(file.size));
    const joined = new Uint8Array(sizeBuf.length + head.byteLength + tail.byteLength);
    joined.set(sizeBuf, 0); joined.set(new Uint8Array(head), sizeBuf.length);
    joined.set(new Uint8Array(tail), sizeBuf.length + head.byteLength);
    const digest = await crypto.subtle.digest("SHA-256", joined);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, "0")).join("");
  } catch (e) { return null; }
}
function durationOf(blob) {
  return new Promise(resolve => {
    const u = URL.createObjectURL(blob), a = new Audio();
    const done = d => { URL.revokeObjectURL(u); resolve(d); };
    a.preload = "metadata";
    a.onloadedmetadata = () => done(isFinite(a.duration) ? a.duration : 0);
    a.onerror = () => done(0);
    setTimeout(() => done(0), 6000);
    a.src = u;
  });
}

/* ============================ import pipeline ============================ */
function ensureSong(title) {
  const t = title.trim();
  let s = state.songs.find(x => x.title.toLowerCase() === t.toLowerCase());
  if (s) return { song: s, created: false };
  s = { id: uid(), title: t, era: "Imported", status: "Assembling", sections: C.defaultSections(uid), createdAt: now() };
  state.songs.push(s); persistSong(s);
  return { song: s, created: true };
}

async function importFiles(files, opts = {}) {
  const audioFiles = files.filter(f => C.isAudioName(f.name));
  const skipped = files.length - audioFiles.length;
  if (!audioFiles.length) { toast("No audio files found"); return; }
  state.importing = { done: 0, total: audioFiles.length, dupes: 0, songs: 0 };
  openImportProgress();

  const seen = existingHashes();
  let added = 0, newSongs = 0, dupes = 0;
  const perSong = new Map();

  for (const f of audioFiles) {
    const hash = await hashFile(f);
    if (hash && seen.has(hash)) { dupes++; state.importing.done++; state.importing.dupes = dupes; updateImportProgress(); continue; }
    if (hash) seen.add(hash);

    const pv = C.parseVersion(f.name);
    let title;
    if (opts.targetSongId) {
      title = state.songs.find(s => s.id === opts.targetSongId)?.title;
    } else if (opts.newSongName) {
      title = opts.newSongName;
    } else if (opts.smart) {
      title = pv.canonical;
    } else {
      const rel = f.webkitRelativePath || f.relativePath || "";
      const root = opts.rootName || (rel.split("/")[0] || "Imported");
      const group = C.groupForPath(rel || f.name, root);
      // Loose files (no subfolder) group by canonical song title, not folder name.
      title = group === root ? pv.canonical : C.titleize(group, false);
    }
    const { song: s, created } = ensureSong(title || "Imported");
    if (created) {
      newSongs++;
      record(s.id, "Song", "Imported", `${s.title} imported.` , !!opts.observed);
    }

    const asset = {
      id: uid(), songId: s.id, title: C.titleize(f.name), file: f.name,
      role: C.inferRole(f.name), created: now(), hash,
      size: f.size, type: f.type || "", modifiedAt: f.lastModified || 0,
      sourcePath: opts.pathFor ? opts.pathFor(f) : (f.webkitRelativePath || null),
      version: pv.label, vOrder: pv.order,
      dur: 0
    };
    await dbPut("blobs", { id: asset.id, blob: f });
    asset.dur = await durationOf(f);
    state.assets.push(asset);
    await persistAsset(asset);
    record(s.id, C.targetForRole(asset.role), "Imported",
      `${f.name} ${opts.observed ? "appeared in watched folder (observed)" : "imported"}.`, !!opts.observed);
    added++;
    perSong.set(s.id, (perSong.get(s.id) || 0) + 1);
    state.importing.done++; state.importing.songs = newSongs; updateImportProgress();
  }

  for (const [sid, n] of perSong) {
    if (n < 2) continue;
    const s = state.songs.find(x => x.id === sid);
    const vc = versionCount(sid);
    if (vc >= 2) record(sid, "Song", "Imported", `${vc} versions of ${s.title} stacked — latest flagged.`);
  }
  runDecisionEngine([...perSong.keys()]);
  queueAnalysis(state.assets.filter(a => [...perSong.keys()].includes(a.songId)).map(a => a.id));

  state.importing.summary =
    `${added} asset${added === 1 ? "" : "s"} imported · ${newSongs} new song${newSongs === 1 ? "" : "s"} · ` +
    `${dupes} duplicate${dupes === 1 ? "" : "s"} skipped` + (skipped ? ` · ${skipped} non-audio skipped` : "");
  updateImportProgress(true);
  if (!state.songId && state.songs.length) state.songId = state.songs[0].id;
  renderAll(false);
}

/* ---------- folder connect + watch (Chromium File System Access) ---------- */
const canConnect = "showDirectoryPicker" in window;
let dirHandle = null, watchTimer = null;

async function scanHandle(handle, prefix = "") {
  const out = [];
  for await (const entry of handle.values()) {
    if (entry.kind === "directory") {
      out.push(...await scanHandle(entry, prefix + entry.name + "/"));
    } else if (C.isAudioName(entry.name)) {
      out.push({ entry, path: prefix + entry.name });
    }
  }
  return out;
}

async function connectFolder() {
  try {
    dirHandle = await window.showDirectoryPicker({ mode: "read" });
  } catch (e) { return; }
  await dbPut("kv", { key: "dirHandle", value: dirHandle }).catch(() => {});
  await dbPut("kv", { key: "dirName", value: dirHandle.name });
  state.watchStatus = { name: dirHandle.name, live: true };
  toast(`Watching ${dirHandle.name}`);
  await reconcile(true);
  startWatchLoop();
  renderAll(false);
}

async function restoreFolder() {
  const rec = await dbGet("kv", "dirHandle");
  if (!rec || !rec.value || !rec.value.queryPermission) return;
  dirHandle = rec.value;
  const perm = await dirHandle.queryPermission({ mode: "read" }).catch(() => "denied");
  state.watchStatus = { name: dirHandle.name, live: perm === "granted", needsGrant: perm === "prompt" };
  if (perm === "granted") { await reconcile(false); startWatchLoop(); }
}

async function regrantFolder() {
  if (!dirHandle) return;
  const perm = await dirHandle.requestPermission({ mode: "read" }).catch(() => "denied");
  if (perm === "granted") {
    state.watchStatus = { name: dirHandle.name, live: true };
    await reconcile(false); startWatchLoop(); renderAll(false);
    toast(`Watching ${dirHandle.name}`);
  }
}

function startWatchLoop() {
  clearInterval(watchTimer);
  watchTimer = setInterval(() => reconcile(false).catch(() => {}), 20000);
}

const archivedOnce = () => new Set(state.events.filter(e => e.op === "Archived").map(e => e.summary));
async function reconcile(announce) {
  if (!dirHandle || !state.watchStatus || !state.watchStatus.live) return;
  let listing;
  try { listing = await scanHandle(dirHandle); }
  catch (e) { state.watchStatus.live = false; state.watchStatus.needsGrant = true; renderAll(false); return; }

  const root = dirHandle.name;
  const onDisk = new Map();
  const seen = existingHashes();
  let added = 0, changed = 0;

  for (const { entry, path } of listing) {
    const file = await entry.getFile().catch(() => null);
    if (!file) continue;
    const full = root + "/" + path;
    onDisk.set(full, file.lastModified);
    const known = state.assets.find(a => a.sourcePath === full);
    if (known) {
      if (file.lastModified && known.modifiedAt && Math.abs(file.lastModified - known.modifiedAt) > 1500) {
        known.modifiedAt = file.lastModified; known.size = file.size;
        known.hash = await hashFile(file);
        await dbPut("blobs", { id: known.id, blob: file });
        known.dur = await durationOf(file);
        peakMem.delete(known.id); dbDel("kv", "peaks:" + known.id);
        blobURLs.delete(known.id);
        known.analyzedAt = null;
        await persistAsset(known);
        record(known.songId, C.targetForRole(known.role), "Recording Updated",
          `${known.file} changed on disk (observed).`, true);
        changed++;
      }
      continue;
    }
    const hash = await hashFile(file);
    if (hash && seen.has(hash)) continue;
    if (hash) seen.add(hash);
    const pv = C.parseVersion(file.name);
    const group = C.groupForPath(root + "/" + path, root);
    const { song: s, created } = ensureSong(group === root ? pv.canonical : C.titleize(group, false));
    if (created) record(s.id, "Song", "Imported", `${s.title} detected in watched folder (observed).`, true);
    const asset = {
      id: uid(), songId: s.id, title: C.titleize(file.name), file: file.name,
      role: C.inferRole(file.name), created: now(), hash, size: file.size,
      type: file.type || "", modifiedAt: file.lastModified || 0, sourcePath: full,
      version: pv.label, vOrder: pv.order, dur: 0
    };
    await dbPut("blobs", { id: asset.id, blob: file });
    asset.dur = await durationOf(file);
    state.assets.push(asset); await persistAsset(asset);
    record(s.id, C.targetForRole(asset.role), "Imported", `${file.name} appeared in watched folder (observed).`, true);
    added++;
  }

  const once = archivedOnce();
  for (const a of state.assets) {
    if (!a.sourcePath || !a.sourcePath.startsWith(root + "/")) continue;
    if (onDisk.has(a.sourcePath)) continue;
    const summary = `${a.file} removed from disk (observed).`;
    if (once.has(summary)) continue;
    record(a.songId, C.targetForRole(a.role), "Archived", summary, true);
  }

  if (added || changed) {
    runDecisionEngine();
    queueAnalysis(state.assets.map(a => a.id));
    toast(`Observed: ${added ? added + " new" : ""}${added && changed ? ", " : ""}${changed ? changed + " changed" : ""}`);
    renderAll(false);
  }
  else if (announce) renderAll(false);
}

/* ============================ mutations ============================ */
function assign(slotId, assetId) {
  const s = song(), x = s.sections.find(z => z.id === slotId);
  const r = C.applyAssign(x, assetId);
  if (!r.changed) return;
  persistSong(s);
  const a = byId(assetId);
  record(s.id, C.targetForName(x.name), assetId ? "Source Selected" : "Structure Updated",
    assetId ? `${a.title} selected as ${x.name} source.` : `${x.name} source cleared.`);
  toast(assetId ? `${a.title} → ${x.name}` : `${x.name} cleared`);
}
function setSlotState(slotId, key) {
  const s = song(), x = s.sections.find(z => z.id === slotId);
  const old = x.state;
  if (!C.applyState(x, key)) return;
  persistSong(s);
  record(s.id, C.targetForName(x.name), C.opForState(key),
    `${x.name} moved from ${C.STATES[old].label} to ${C.STATES[key].label}.`);
}
function saveNote(slotId, note) {
  const s = song(), x = s.sections.find(z => z.id === slotId);
  x.note = note.trim(); persistSong(s);
}
function addSlot(name) {
  const s = song();
  s.sections.push({ id: uid(), name, role: "Custom", assetId: null, state: "open", conf: 0, note: "" });
  persistSong(s);
  record(s.id, "Song", "Structure Updated", `${name} slot added to master composition.`);
}
function removeSlot(slotId) {
  const s = song(), i = s.sections.findIndex(z => z.id === slotId);
  if (i < 0) return;
  const name = s.sections[i].name;
  s.sections.splice(i, 1); persistSong(s);
  record(s.id, "Song", "Structure Updated", `${name} slot removed from master composition.`);
}
function moveSlot(slotId, off) {
  const s = song(), i = s.sections.findIndex(z => z.id === slotId), j = i + off;
  if (i < 0 || j < 0 || j >= s.sections.length) return;
  [s.sections[i], s.sections[j]] = [s.sections[j], s.sections[i]];
  persistSong(s);
  record(s.id, "Song", "Structure Updated", `${s.sections[j].name} moved to position ${j + 1}.`);
}
function renameSong(id, title) {
  const t = title.trim(); if (!t) return;
  const s = state.songs.find(x => x.id === id);
  if (!s || s.title === t) return;
  const old = s.title; s.title = t; persistSong(s);
  record(id, "Song", "Structure Updated", `Renamed from ${old} to ${t}.`);
}
function deleteSong(id) {
  const s = state.songs.find(x => x.id === id); if (!s) return;
  if (state.npAsset && state.npAsset.songId === id) Player.stop();
  for (const a of state.assets.filter(a => a.songId === id)) {
    dbDel("assets", a.id); dbDel("blobs", a.id); dbDel("kv", "peaks:" + a.id);
    const u = blobURLs.get(a.id); if (u) { URL.revokeObjectURL(u); blobURLs.delete(a.id); }
  }
  state.assets = state.assets.filter(a => a.songId !== id);
  for (const e of state.events.filter(e => e.songId === id)) dbDel("events", e.id);
  state.events = state.events.filter(e => e.songId !== id);
  state.songs = state.songs.filter(x => x.id !== id);
  dbDel("songs", id);
  if (state.songId === id) state.songId = state.songs[0] ? state.songs[0].id : null;
  toast(`Deleted ${s.title}`);
}
function deleteAsset(id) {
  const a = byId(id); if (!a) return;
  if (state.npAsset && state.npAsset.id === id) Player.stop();
  for (const s of state.songs) {
    let touched = false;
    for (const x of s.sections) if (x.assetId === id) { x.assetId = null; touched = true; }
    if (touched) persistSong(s);
  }
  state.assets = state.assets.filter(x => x.id !== id);
  dbDel("assets", id); dbDel("blobs", id); dbDel("kv", "peaks:" + id);
  const u = blobURLs.get(id); if (u) { URL.revokeObjectURL(u); blobURLs.delete(id); }
  record(a.songId, C.targetForRole(a.role), "Archived", `${a.file} removed from library.`);
  toast(`Removed ${a.title}`);
}
function resolveDecision(slotId, winnerId) {
  assign(slotId, winnerId);
  setSlotState(slotId, "locked");
}

/* ---------- audio intelligence: BPM + key (lazy, queued, persisted) ---------- */
const ANALYZE_SIZE_CAP = 40 * 1024 * 1024;
let analyzeQueue = [], analyzeBusy = false;
function queueAnalysis(assetIds) {
  for (const id of assetIds) {
    const a = byId(id);
    if (!a || a.demo || a.analyzedAt || analyzeQueue.includes(id)) continue;
    analyzeQueue.push(id);
  }
  drainAnalysis();
}
async function drainAnalysis() {
  if (analyzeBusy) return;
  analyzeBusy = true;
  while (analyzeQueue.length) {
    const id = analyzeQueue.shift();
    const a = byId(id);
    if (!a) continue;
    try {
      const rec = await dbGet("blobs", id);
      if (!rec || !rec.blob || rec.blob.size > ANALYZE_SIZE_CAP) { a.analyzedAt = now(); await persistAsset(a); continue; }
      if (!decodeCtx) decodeCtx = new (window.AudioContext || window.webkitAudioContext)();
      const buf = await rec.blob.arrayBuffer();
      const audio = await decodeCtx.decodeAudioData(buf.slice(0));
      const result = window.AOSAudio.analyze(audio.getChannelData(0), audio.sampleRate);
      a.bpm = result.tempo ? result.tempo.bpm : null;
      a.keyName = result.key ? result.key.name : null;
      a.analysisConf = Math.max(result.tempo ? result.tempo.confidence : 0, result.key ? result.key.confidence : 0);
      a.analyzedAt = now();
      await persistAsset(a);
      renderAll(false);
    } catch (e) {
      a.analyzedAt = now();
      await persistAsset(a).catch(() => {});
    }
    await new Promise(r => setTimeout(r, 60)); // keep the UI thread breathing
  }
  analyzeBusy = false;
}

/* ---------- decision engine ---------- */
function runDecisionEngine(songIds) {
  const ids = songIds || state.songs.map(s => s.id);
  for (const id of ids) {
    const s = state.songs.find(x => x.id === id); if (!s) continue;
    const fired = C.applyAutoDecisions(s, state.assets.filter(a => a.songId === id));
    if (fired.length) {
      persistSong(s);
      for (const f of fired) {
        record(id, C.targetForName(f.slotName), "Needs Decision",
          `${f.slotName} auto-flagged: ${f.count} ${C.ROLES[f.role].toLowerCase()} candidates need a call.`, true);
      }
    }
  }
}
function pinMaster(songId, assetId) {
  const s = state.songs.find(x => x.id === songId); if (!s) return;
  const a = byId(assetId); if (!a || s.masterAssetId === assetId) return;
  s.masterAssetId = assetId; persistSong(s);
  record(songId, "Master", "Approved", `${a.title}${a.version ? " (" + a.version + ")" : ""} pinned as current master.`);
  toast(`★ ${a.title} is the master`);
}

/* ---------- re-analysis of existing catalog ---------- */
function reanalyzePlan() {
  const moves = [];
  for (const a of state.assets) {
    if (a.demo) continue;
    const pv = C.parseVersion(a.file);
    const home = songOf(a);
    const needsVersion = a.version !== pv.label || a.vOrder !== pv.order;
    const wrongSong = home && home.title.toLowerCase() !== pv.canonical.toLowerCase()
      && home.sections.every(x => x.assetId !== a.id); // never yank assets already assigned on a board
    moves.push({ asset: a, pv, move: !!wrongSong, needsVersion });
  }
  return moves;
}
function reanalyzePreviewSheet() {
  const plan = reanalyzePlan();
  const moving = plan.filter(p => p.move).length;
  const tagging = plan.filter(p => p.needsVersion).length;
  const targets = new Set(plan.filter(p => p.move).map(p => p.pv.canonical.toLowerCase()));
  openSheet(`
    <h3>Re-analyze filenames</h3>
    <div class="hint">Groups existing assets into songs by canonical title and stacks versions. Assets already placed on a master board stay put.</div>
    <div class="panel" style="padding:14px;margin-bottom:12px">
      <div class="row-title" style="font-size:14px">${moving} asset${moving === 1 ? "" : "s"} will move into ${targets.size || 0} song${targets.size === 1 ? "" : "s"}</div>
      <div class="sub" style="margin-top:4px">${tagging} version label${tagging === 1 ? "" : "s"} will be added or corrected. Songs left empty are removed.</div>
    </div>
    <div class="sheet-actions">
      <button class="btn ghost" data-act="close">Cancel</button>
      <button class="btn gold" data-act="do-reanalyze">Apply</button>
    </div>`);
}
function applyReanalyze() {
  const plan = reanalyzePlan();
  let moved = 0, tagged = 0;
  const touched = new Set();
  for (const p of plan) {
    const a = p.asset;
    if (p.needsVersion) { a.version = p.pv.label; a.vOrder = p.pv.order; tagged++; }
    if (p.move) {
      const from = songOf(a);
      const { song: s, created } = ensureSong(p.pv.canonical);
      if (created) record(s.id, "Song", "Imported", `${s.title} created during filename re-analysis.`);
      a.songId = s.id; moved++; touched.add(s.id);
      record(s.id, C.targetForRole(a.role), "Imported", `${a.file} regrouped into ${s.title} (re-analysis).`);
      if (from) touched.add(from.id);
    }
    persistAsset(a);
  }
  for (const id of touched) {
    const s = state.songs.find(x => x.id === id);
    if (s && !assetsFor(id).length && s.sections.every(x => !x.assetId)) deleteSong(id);
    else if (s && versionCount(id) >= 2) record(id, "Song", "Imported", `${versionCount(id)} versions of ${s.title} stacked — latest flagged.`);
  }
  runDecisionEngine();
  closeSheet(); renderAll(false);
  toast(moved || tagged ? `Reorganized: ${moved} moved, ${tagged} version-tagged` : "Catalog already organized");
}

/* ============================ demo catalog ============================ */
function loadDemo() {
  const mkS = (title, era, status) => ({ id: uid(), title, era, status, sections: [], createdAt: now() });
  const mkA = (songId, title, file, role, dur, ageHr) =>
    ({ id: uid(), songId, title, file, role, dur, created: now() - ageHr * 36e5, demo: true, hash: null, size: 0, modifiedAt: 0, sourcePath: null });
  const S1 = mkS("Golden State", "Ascension Era", "Assembling");
  const A1 = [
    mkA(S1.id, "Beat is M9", "beat is m9.m4a", "beat", 199, 220),
    mkA(S1.id, "Soda7draft", "soda7draft.m4a", "leadVocal", 252, 190),
    mkA(S1.id, "Hook Take 2", "golden hook take2.m4a", "hook", 41, 52),
    mkA(S1.id, "Hook Late Night", "hook latenite bounce.m4a", "hook", 44, 9),
    mkA(S1.id, "Candid Camera", "candidcamera(apple master)_1.m4a", "bridge", 258, 300)
  ];
  const sc = (name, role, aId, st, conf, note = "") => ({ id: uid(), name, role, assetId: aId, state: st, conf, note });
  S1.sections = [
    sc("Intro", "Atmosphere", A1[0].id, "locked", .94),
    sc("Verse 1", "Lead vocal", A1[1].id, "candidate", .62),
    sc("Hook", "Melody", A1[2].id, "needsDecision", .5, "Take 2 vs late-night bounce."),
    sc("Bridge", "Alt pocket", A1[4].id, "experiment", .4),
    sc("Outro", "Space", null, "open", 0)
  ];
  state.songs.push(S1); state.assets.push(...A1);
  persistSong(S1); A1.forEach(persistAsset);
  record(S1.id, "Song", "Imported", "Golden State loaded as demo catalog.");
  record(S1.id, "Hook", "Needs Decision", "Hook moved from Candidate to Needs Decision.");
  state.songId = S1.id;
  toast("Demo catalog loaded — demo assets play a generative preview");
}

/* ============================ export / danger ============================ */
function exportBackup() {
  const data = { exportedAt: new Date().toISOString(), songs: state.songs, assets: state.assets.map(a => ({ ...a })), events: state.events };
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
  const u = URL.createObjectURL(blob), a = document.createElement("a");
  a.href = u; a.download = "artist-os-backup.json"; a.click();
  setTimeout(() => URL.revokeObjectURL(u), 5000);
}
async function wipeAll() {
  Player.stop(); clearInterval(watchTimer);
  if (idb) { idb.close(); await new Promise(r => { const q = indexedDB.deleteDatabase(DB_NAME); q.onsuccess = q.onerror = q.onblocked = r; }); }
  location.reload();
}

/* ============================ renderers ============================ */
const stateChip = k => `<span class="badge" style="--tint:${C.STATES[k].tint}">${C.STATES[k].label}</span>`;
const eqHtml = () => `<span class="eq" aria-hidden="true"><i></i><i></i><i></i></span>`;

function watchBanner() {
  const w = state.watchStatus;
  if (w && w.needsGrant) {
    return `<div class="banner warn">Folder access paused — the browser needs a fresh grant to keep watching “${esc(w.name)}”.
      <button class="btn gold" data-act="regrant">Re-connect</button></div>`;
  }
  if (w && w.live) {
    return `<div class="watch-card panel"><div class="watch-dot"></div>
      <div class="grow"><div style="font-weight:800;font-size:13.5px">Watching ${esc(w.name)}</div>
      <div class="sub">New bounces auto-import · changes become observed events · rechecks every 20s</div></div></div>`;
  }
  return "";
}

function songCard(s, compact = false) {
  const p = C.progressOf(s);
  return `<div class="song-card-wrap">
    <button class="card panel" data-song="${s.id}" style="margin-bottom:0">
      <div style="display:flex;align-items:flex-start;gap:10px">
        <div style="flex:1;min-width:0">
          <div class="row-title">${esc(s.title)}</div>
          <div class="sub" style="margin-top:2px">${esc(s.era)} · ${versionCount(s.id) >= 2 ? versionCount(s.id) + " versions · " : ""}${assetsFor(s.id).length} assets</div>
        </div>
        <span class="badge">${esc(s.status)}</span>
      </div>
      <div class="bar" style="margin-top:11px"><i style="width:${p * 100}%"></i></div>
      ${compact ? "" : `<div class="sub" style="margin-top:8px">${esc(C.riskOf(s))}</div>`}
    </button>
    ${compact ? "" : `<button class="kebab panel" data-songmenu="${s.id}" aria-label="Song options">⋯</button>`}
  </div>`;
}

function renderOnboard() {
  return `<div class="onboard">
    <div class="logo">♪</div>
    <h2>Your catalog, organized around songs — not files.</h2>
    <p>Import your bounces, takes, and mixes. Artist OS groups them into songs, tracks every decision, and writes the creative record for you.</p>
    <div class="stack">
      ${canConnect ? `<button class="btn gold" data-act="connect">Connect a folder (auto-watch)</button>` : ""}
      <button class="btn ${canConnect ? "" : "gold"}" data-act="pick-folder">Import a folder</button>
      <button class="btn" data-act="pick-files">Import audio files</button>
      <button class="btn ghost" data-act="demo">Load demo catalog</button>
    </div>
    <div class="priv">🔒 Local-first — your audio and catalog never leave this device.</div>
  </div>`;
}

function renderDecideInbox() {
  const list = allDecisions();
  if (!list.length) return "";
  return `<div class="eyebrow" style="color:var(--gold)">Decide · ${list.length}</div>` + list.map(d => `
    <button class="card panel" data-decision="${d.kind}" data-dsong="${d.songId}" ${d.slotId ? `data-dslot="${d.slotId}"` : ""}
      style="margin-bottom:10px;border-color:color-mix(in srgb,var(--gold) 38%,transparent)">
      <div style="display:flex;align-items:center;gap:10px">
        <span style="font-size:17px">⚖️</span>
        <div style="flex:1;min-width:0">
          <div class="row-title" style="font-size:14px">${esc(d.title)}</div>
          <div class="sub" style="margin-top:2px">${esc(d.detail)}</div>
        </div>
        <span class="badge">A/B</span>
      </div>
    </button>`).join("") + `<div style="height:8px"></div>`;
}

function renderSongs() {
  if (!state.songs.length) return renderOnboard();
  return watchBanner() + renderDecideInbox() + `<div class="eyebrow">Songs</div>` + state.songs.map(s => songCard(s)).join("") +
    `<button class="btn ghost add-slot" data-act="new-song">＋ New song</button>`;
}

function scoreRing(v) {
  const r = 26, c = 2 * Math.PI * r;
  return `<div class="ring"><svg width="62" height="62" viewBox="0 0 62 62">
    <circle cx="31" cy="31" r="${r}" fill="none" stroke="rgba(255,255,255,.08)" stroke-width="5"/>
    <circle cx="31" cy="31" r="${r}" fill="none" stroke="var(--gold)" stroke-width="5" stroke-linecap="round"
      stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - v)}"/></svg><b>${Math.round(v * 100)}</b></div>`;
}

function renderSongView() {
  const s = song(); if (!s) return renderSongs();
  const p = C.progressOf(s);
  let body = "";
  if (state.songTab === "master") body = renderMaster(s);
  if (state.songTab === "changes") body = renderEvents(state.events.filter(e => e.songId === s.id), false);
  if (state.songTab === "assets") body = renderAssetCards(assetsFor(s.id), false);
  return `
  <div class="song-hero">
    <div class="eyebrow" style="color:var(--gold);margin-bottom:6px">Current Song</div>
    <div class="hero-row">
      <div class="grow"><h1>${esc(s.title)}</h1>
        <div class="sub" style="margin-top:6px">${esc(s.era)} · ${esc(s.status)} · ${esc(C.riskOf(s))}</div></div>
      ${scoreRing(.5 + p * .45)}
    </div>
    <div class="bar" style="margin-top:14px"><i style="width:${p * 100}%"></i></div>
  </div>
  <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
    <div class="segs">${[["master","Master"],["changes","Changes"],["assets","Assets"]].map(([k, l]) =>
      `<button data-songtab="${k}" class="${state.songTab === k ? "on" : ""}">${l}</button>`).join("")}</div>
    ${versionCount(s.id) >= 2 ? `<button class="btn ghost" data-versioncompare="${s.id}" style="min-height:40px;color:var(--blue)">⚖ Compare versions</button>` : ""}
    <button class="btn ghost" data-act="log-change" style="min-height:40px;color:var(--gold)">＋ Log change</button>
  </div>${body}`;
}

function renderMaster(s) {
  return `<div class="eyebrow">Current Master Composition</div>` +
    s.sections.map((x, i) => {
      const a = byId(x.assetId);
      const playing = a && state.npAsset && state.npAsset.id === a.id;
      return `<div class="slot panel ${x.state === "needsDecision" ? "decide" : ""}" data-slot="${x.id}" role="button" tabindex="0">
        <div class="idx mono">${String(i + 1).padStart(2, "0")}</div>
        <div class="meta">
          <div class="nm">${esc(x.name)} ${playing ? eqHtml() : ""}</div>
          <div class="asset">${a ? esc(a.title) + " · " + esc(a.file) : (x.note ? esc(x.note) : "No asset — tap to assign")}</div>
        </div>
        ${a ? `<button class="play" data-play="${a.id}" aria-label="Preview ${esc(a.title)}">${playing && Player.playing() ? "❚❚" : "▶"}</button>` : ""}
        ${x.state === "needsDecision" && assetsFor(s.id).length > 1 ? `<button class="btn gold" data-compare="${x.id}" style="min-height:38px;padding:8px 12px;font-size:12px">A/B</button>` : ""}
        <div class="right">${stateChip(x.state)}<div class="bar conf"><i style="width:${(x.conf || 0) * 100}%"></i></div></div>
      </div>`;
    }).join("") +
    `<button class="btn ghost add-slot" data-act="add-slot">＋ Add slot</button>`;
}

function renderEvents(list, withSong) {
  if (!list.length) return `<div class="empty"><div class="big">⏱</div><b>No creative events yet</b>Import audio or make a change — the record writes itself.</div>`;
  return `<div class="eyebrow">Creative Change Log</div>` + list.map(e => {
    const s = state.songs.find(x => x.id === e.songId);
    return `<div class="evt panel">
      <div class="when mono" title="${new Date(e.t).toLocaleString()}">${C.agoFrom(now(), e.t)}</div>
      <div class="body">
        ${withSong && s ? `<div class="sub" style="color:var(--gold);font-weight:800;font-size:11px;margin-bottom:2px">${esc(s.title)}</div>` : ""}
        <div class="ops">${esc(e.target)} <span class="op">${esc(e.op)}</span></div>
        <div class="sum">${esc(e.summary)}</div>
      </div>
      <div class="who ${e.observed ? "obs" : ""}">${e.observed ? "Observed" : "You"}</div>
    </div>`;
  }).join("");
}

function renderAssetCards(list, withSong) {
  if (!list.length) return `<div class="empty"><div class="big">▦</div><b>No assets yet</b>Import audio to attach recordings and mixes.</div>`;
  const latestId = !withSong && list.length > 1 && (list[0].version || list[0].vOrder != null) ? list[0].id : null;
  return `<div class="eyebrow">${!withSong && versionCount(list[0].songId) >= 2 ? "Version Stack" : "Assets"}</div>` + list.map(a => {
    const playing = state.npAsset && state.npAsset.id === a.id;
    return `<div class="asset-card panel" data-asset="${a.id}">
      <div class="hd">
        <button class="play" data-play="${a.id}" aria-label="Preview ${esc(a.title)}">${playing && Player.playing() ? "❚❚" : "▶"}</button>
        <div class="grow">
          <div class="row-title" style="font-size:14.5px">${esc(a.title)} ${playing ? eqHtml() : ""}</div>
          <div class="sub">${C.ROLES[a.role]}${a.dur ? " · " + C.mmss(a.dur) : ""}${a.bpm ? " · " + Math.round(a.bpm) + " BPM" : ""}${a.keyName ? " · " + esc(a.keyName) : ""}${a.demo ? " · demo" : ""}${withSong ? " · " + esc(songOf(a)?.title || "") : ""}</div>
        </div>
        ${(songOf(a) && songOf(a).masterAssetId === a.id) ? `<span class="badge" style="--tint:var(--gold)">★ Master</span>` : (a.id === latestId ? `<span class="badge" style="--tint:var(--green)">Latest</span>` : (a.version ? `<span class="badge">${esc(a.version)}</span>` : ""))}
        <button class="kebab" data-assetmenu="${a.id}" aria-label="Asset options">⋯</button>
      </div>
      <canvas class="wave" data-wave="${a.id}"></canvas>
      <div class="file mono">${esc(a.file)}</div>
    </div>`;
  }).join("");
}

function renderSettings() {
  const bytes = state.assets.reduce((n, a) => n + (a.size || 0), 0);
  const mb = (bytes / 1048576).toFixed(1);
  return `<div class="eyebrow">Settings</div>
  <div class="panel" style="padding:16px;margin-bottom:12px">
    <div class="row-title">Library</div>
    <div class="sub" style="margin:6px 0 14px">${state.songs.length} songs · ${state.assets.length} assets · ${state.events.length} events · ~${mb} MB audio stored locally${memoryMode ? " · <b style='color:var(--gold)'>memory mode (nothing persists)</b>" : ""}</div>
    ${canConnect ? `<button class="btn" data-act="connect" style="width:100%;margin-bottom:9px">${state.watchStatus && state.watchStatus.live ? "Watching “" + esc(state.watchStatus.name) + "” — change folder" : "Connect a folder (auto-watch)"}</button>` : ""}
    <button class="btn" data-act="reanalyze" style="width:100%;margin-bottom:9px">Re-analyze filenames & regroup</button>
    <button class="btn" data-act="export" style="width:100%;margin-bottom:9px">Export catalog backup (JSON)</button>
    <button class="btn danger" data-act="wipe" style="width:100%">Erase everything on this device…</button>
  </div>
  <div class="panel" style="padding:16px">
    <div class="row-title">Privacy</div>
    <div class="sub" style="margin-top:6px">Artist OS web is local-first. Your audio files and catalog are stored in this browser only and are never uploaded. Clearing site data erases the library.</div>
  </div>`;
}

function renderAll(scroll = true) {
  const v = $("#view");
  if (state.tab === "songs") v.innerHTML = state.songId && song() ? renderSongView() : renderSongs();
  if (state.tab === "timeline") v.innerHTML = renderEvents([...state.events].sort((a, b) => b.t - a.t), true);
  if (state.tab === "assets") v.innerHTML = renderAssetCards([...state.assets].sort((a, b) => b.created - a.created), true);
  if (state.tab === "settings") v.innerHTML = renderSettings();
  $("#desk-list").innerHTML = state.songs.length ? `<div class="eyebrow">Catalog</div>` + state.songs.map(s => songCard(s, true)).join("") : "";
  $("#back").classList.toggle("show", state.tab === "songs" && !!state.songId);
  $$("nav#tabs button").forEach(b => b.classList.toggle("on", b.dataset.tab === state.tab));
  drawWaves($("#view"));
  renderNP();
  if (scroll) $("#main").scrollTo({ top: 0 });
}

function renderNP() {
  const a = state.npAsset, bar = $("#np");
  bar.classList.toggle("show", !!a);
  $("#main").classList.toggle("has-np", !!a);
  if (!a) return;
  $("#np-title").textContent = a.title;
  $("#np-sub").textContent = (songOf(a) ? songOf(a).title : "") + (a.demo ? " · generative preview" : "");
  $("#np-dur").textContent = C.mmss(Player.dur());
  $("#np-play").textContent = Player.playing() ? "❚❚" : "▶";
}
function renderNPTime() {
  const a = state.npAsset; if (!a) return;
  const d = Player.dur() || 1, p = Player.pos();
  $("#np-cur").textContent = C.mmss(p);
  $("#np-fill").style.width = Math.min(100, 100 * p / d) + "%";
  $("#np-play").textContent = Player.playing() ? "❚❚" : "▶";
}

/* ============================ sheets ============================ */
function openSheet(html) {
  $("#sheet").innerHTML = `<div class="grab"></div>` + html;
  $("#sheet").classList.add("show"); $("#scrim").classList.add("show");
}
function closeSheet() { $("#sheet").classList.remove("show"); $("#scrim").classList.remove("show"); }

function importSheet() {
  openSheet(`
    <h3>Import audio</h3>
    <div class="hint">Files are copied into your local library. Subfolders become songs.</div>
    ${canConnect ? `<button class="opt" data-act="connect"><span class="dot" style="--tint:var(--green)"></span>Connect a folder (auto-watch)<span class="r">Chrome/Edge</span></button>` : ""}
    <button class="opt" data-act="pick-folder"><span class="dot" style="--tint:var(--gold)"></span>Import a folder once</button>
    <button class="opt" data-act="pick-files"><span class="dot" style="--tint:var(--blue)"></span>Pick audio files</button>
    ${state.songs.length ? "" : `<button class="opt" data-act="demo"><span class="dot"></span>Load demo catalog</button>`}
  `);
}
function filesTargetSheet(files) {
  pendingFiles = files;
  const groups = C.clusterByCanonical(files.map(f => f.name));
  const smartLines = groups.map(g => {
    const t = state.songs.find(s => s.title.toLowerCase() === g.title.toLowerCase());
    return `<button class="opt" data-act="smart-import">
      <span class="dot" style="--tint:var(--gold)"></span>${esc(g.title)}
      <span class="r">${g.indices.length} file${g.indices.length === 1 ? "" : "s"}${g.versions >= 2 ? " · " + g.versions + " versions" : ""}${t ? " · existing" : " · new"}</span>
    </button>`;
  }).join("");
  openSheet(`
    <h3>Smart import</h3>
    <div class="hint">${files.length} file${files.length === 1 ? "" : "s"} → ${groups.length} song${groups.length === 1 ? "" : "s"} detected from filenames. Versions stack automatically.</div>
    ${smartLines}
    <button class="btn gold" data-act="smart-import" style="width:100%;margin:6px 0 14px">Import as ${groups.length} song${groups.length === 1 ? "" : "s"}</button>
    <div class="eyebrow">Or override</div>
    <input class="field" id="ft-new" placeholder="Put everything in one song…" maxlength="60">
    <button class="btn" data-act="files-new" style="width:100%;margin-bottom:12px">Import into one song</button>
    ${state.songs.length ? `<div class="eyebrow">Or add all to an existing song</div>` +
      state.songs.map(s => `<button class="opt" data-filestarget="${s.id}"><span class="dot" style="--tint:var(--gold)"></span>${esc(s.title)}<span class="r">${assetsFor(s.id).length} assets</span></button>`).join("") : ""}
  `);
}
function openImportProgress() {
  openSheet(`<h3>Importing</h3><div class="hint" id="ip-phase">Reading audio…</div>
    <div class="progress-sheet"><div class="big-count mono" id="ip-count">0 / ${state.importing.total}</div>
    <div class="bar" style="margin:12px 0"><i id="ip-bar" style="width:0%"></i></div>
    <div class="sub" id="ip-sum"></div></div>
    <div class="sheet-actions" id="ip-done" style="display:none"><button class="btn gold" data-act="ip-close">Done</button></div>`);
}
function updateImportProgress(done) {
  const im = state.importing; if (!im) return;
  const c = $("#ip-count"), b = $("#ip-bar");
  if (c) c.textContent = `${im.done} / ${im.total}`;
  if (b) b.style.width = (100 * im.done / im.total) + "%";
  if (done) {
    const s = $("#ip-sum"), d = $("#ip-done"), ph = $("#ip-phase");
    if (ph) ph.textContent = "Import complete";
    if (s) s.textContent = im.summary;
    if (d) d.style.display = "flex";
  }
}
function slotSheet(slotId) {
  const s = song(), x = s.sections.find(z => z.id === slotId);
  const opts = assetsFor(s.id);
  openSheet(`
    <h3>${esc(x.name)}</h3>
    <div class="hint">Assign a source, set its state, or reorder.</div>
    <div class="eyebrow">Assign asset</div>
    <button class="opt" data-assign="none" data-slotref="${slotId}"><span class="dot"></span>None<span class="r">clear</span></button>
    ${opts.map(a => `<button class="opt" data-assign="${a.id}" data-slotref="${slotId}">
      <span class="dot" style="--tint:${x.assetId === a.id ? "var(--gold)" : "var(--muted)"}"></span>${esc(a.title)}<span class="r">${C.ROLES[a.role]}</span></button>`).join("")}
    <div class="eyebrow" style="margin-top:14px">Set state</div>
    ${Object.entries(C.STATES).map(([k, v]) => `<button class="opt" data-state="${k}" data-slotref="${slotId}">
      <span class="dot" style="--tint:${v.tint}"></span>${v.label}${x.state === k ? `<span class="r">current</span>` : ""}</button>`).join("")}
    <div class="eyebrow" style="margin-top:14px">Note</div>
    <textarea class="field" id="slot-note" placeholder="Decision context…">${esc(x.note || "")}</textarea>
    <div class="sheet-actions">
      <button class="btn ghost" data-moveslot="-1" data-slotref="${slotId}">↑ Up</button>
      <button class="btn ghost" data-moveslot="1" data-slotref="${slotId}">↓ Down</button>
      <button class="btn danger" data-removeslot="${slotId}">Remove</button>
      <button class="btn gold" data-savenote="${slotId}">Save</button>
    </div>
    ${opts.length > 1 ? `<button class="btn" data-compare="${slotId}" style="width:100%;margin-top:10px">Compare A/B</button>` : ""}
  `);
}
let ab = null, pendingFiles = null;
function compareSheet(slotId) {
  const s = song(), x = s.sections.find(z => z.id === slotId);
  const cands = assetsFor(s.id);
  if (!ab || ab.kind !== "slot" || ab.slot !== slotId) {
    const a0 = x.assetId || cands[0].id;
    ab = { kind: "slot", slot: slotId, a: a0, b: (cands.find(c => c.id !== a0) || cands[0]).id };
  }
  const side = (lbl, asset, key, tint, hex) => `
    <div class="ab ${state.npAsset && state.npAsset.id === asset.id ? "live" : ""}" style="--tint:${tint}">
      <div class="lbl">${lbl}</div>
      <select class="field" data-abpick="${key}">${cands.map(c =>
        `<option value="${c.id}" ${c.id === asset.id ? "selected" : ""}>${esc(c.title)}</option>`).join("")}</select>
      <canvas class="wave" data-wave="${asset.id}" data-tint="${hex}"></canvas>
      <div class="fn mono">${esc(asset.file)}</div>
      <button class="btn" style="border-color:${tint};color:${tint}" data-ablisten="${key}">
        ${state.npAsset && state.npAsset.id === asset.id && Player.playing() ? "❚❚ Pause" : "▶ Listen " + lbl}</button>
      <button class="btn ${key === "a" ? "gold" : "blue"}" data-abchoose="${key}">Choose ${lbl}</button>
    </div>`;
  openSheet(`
    <h3>Compare — ${esc(x.name)}</h3>
    <div class="hint">Switch sides without losing the playhead. Choosing locks the slot.</div>
    <div class="ab-grid">${side("A", byId(ab.a), "a", "var(--gold)", "#D6AE5C")}${side("B", byId(ab.b), "b", "var(--blue)", "#80A6FF")}</div>
    <button class="btn ghost" style="width:100%" data-act="close">Keep undecided</button>`);
  drawWaves($("#sheet"));
}

function versionCompareSheet(songId) {
  const s = state.songs.find(x => x.id === songId); if (!s) return;
  const cands = masterStackFor(songId);
  if (cands.length < 2) return;
  if (!ab || ab.kind !== "master" || ab.songId !== songId) {
    const a0 = s.masterAssetId && cands.some(c => c.id === s.masterAssetId) ? s.masterAssetId : cands[1].id;
    const b0 = cands.find(c => c.id !== a0).id;
    ab = { kind: "master", songId, a: a0, b: cands[0].id !== a0 ? cands[0].id : b0 };
  }
  const side = (lbl, asset, key, tint, hex) => `
    <div class="ab ${state.npAsset && state.npAsset.id === asset.id ? "live" : ""}" style="--tint:${tint}">
      <div class="lbl">${lbl}</div>
      <select class="field" data-abpick="${key}">${cands.map(c =>
        `<option value="${c.id}" ${c.id === asset.id ? "selected" : ""}>${esc(c.title)}${c.version ? " · " + esc(c.version) : ""}${s.masterAssetId === c.id ? " ★" : ""}</option>`).join("")}</select>
      <canvas class="wave" data-wave="${asset.id}" data-tint="${hex}"></canvas>
      <div class="fn mono">${esc(asset.file)}</div>
      <button class="btn" style="border-color:${tint};color:${tint}" data-ablisten="${key}">
        ${state.npAsset && state.npAsset.id === asset.id && Player.playing() ? "❚❚ Pause" : "▶ Listen " + lbl}</button>
      <button class="btn ${key === "a" ? "gold" : "blue"}" data-abchoose="${key}">Pin ${lbl} as master</button>
    </div>`;
  openSheet(`
    <h3>Current master — ${esc(s.title)}</h3>
    <div class="hint">Compare any two versions at the same playhead. Pinning marks the song's source of truth.</div>
    <div class="ab-grid">${side("A", byId(ab.a), "a", "var(--gold)", "#D6AE5C")}${side("B", byId(ab.b), "b", "var(--blue)", "#80A6FF")}</div>
    <button class="btn ghost" style="width:100%" data-act="close">Keep undecided</button>`);
  drawWaves($("#sheet"));
}
function logChangeSheet() {
  const s = song(); if (!s) return;
  openSheet(`
    <h3>Log change</h3>
    <div class="hint">${esc(s.title)} — a manual entry in the creative record.</div>
    <select class="field" id="lc-target">${C.TARGETS.map(t => `<option>${t}</option>`).join("")}</select>
    <select class="field" id="lc-op">${C.OPS.map(o => `<option>${o}</option>`).join("")}</select>
    <input class="field" id="lc-sum" placeholder="What changed?" maxlength="140">
    <div class="sheet-actions"><button class="btn ghost" data-act="close">Cancel</button>
    <button class="btn gold" data-act="lc-save">Log change</button></div>`);
}
function textSheet(title, hint, placeholder, act, val = "") {
  openSheet(`
    <h3>${esc(title)}</h3><div class="hint">${esc(hint)}</div>
    <input class="field" id="tx-in" placeholder="${esc(placeholder)}" value="${esc(val)}" maxlength="60">
    <div class="sheet-actions"><button class="btn ghost" data-act="close">Cancel</button>
    <button class="btn gold" data-act="${act}">Save</button></div>`);
  setTimeout(() => { const i = $("#tx-in"); if (i) i.focus(); }, 250);
}
function songMenuSheet(id) {
  const s = state.songs.find(x => x.id === id);
  openSheet(`
    <h3>${esc(s.title)}</h3><div class="hint">${assetsFor(id).length} assets · ${state.events.filter(e => e.songId === id).length} events</div>
    <button class="opt" data-act="rename-song" data-ref="${id}"><span class="dot" style="--tint:var(--gold)"></span>Rename…</button>
    <button class="opt" data-act="confirm-del-song" data-ref="${id}"><span class="dot" style="--tint:var(--red)"></span><span style="color:var(--red)">Delete song…</span></button>`);
}
function assetMenuSheet(id) {
  const a = byId(id);
  openSheet(`
    <h3>${esc(a.title)}</h3>
    <div class="hint mono">${esc(a.file)}${a.size ? " · " + (a.size / 1048576).toFixed(1) + " MB" : ""}${a.bpm ? " · " + Math.round(a.bpm) + " BPM" : ""}${a.keyName ? " · " + esc(a.keyName) : ""}${a.sourcePath ? " · " + esc(a.sourcePath) : ""}</div>
    <button class="opt" data-play="${id}"><span class="dot" style="--tint:var(--gold)"></span>Preview</button>
    ${((a.version || a.vOrder != null) && a.role === "fullMix") ? `<button class="opt" data-pinmaster="${id}"><span class="dot" style="--tint:var(--gold)"></span>Set as current master</button>` : ""}
    <button class="opt" data-act="confirm-del-asset" data-ref="${id}"><span class="dot" style="--tint:var(--red)"></span><span style="color:var(--red)">Remove from library…</span></button>`);
}
function confirmSheet(title, msg, act, ref) {
  openSheet(`
    <h3>${esc(title)}</h3><div class="hint">${esc(msg)}</div>
    <div class="sheet-actions"><button class="btn ghost" data-act="close">Cancel</button>
    <button class="btn danger" data-act="${act}" data-ref="${ref}" style="border-color:var(--red)">Delete</button></div>`);
}

/* ============================ wiring ============================ */
let renameRef = null;
document.addEventListener("click", async e => {
  const t = e.target.closest("button,[data-slot],[data-song]");
  if (!t) return;
  const act = t.dataset.act;

  if (t.dataset.play) { e.stopPropagation(); Player.toggle(byId(t.dataset.play)); if ($("#sheet").classList.contains("show") && ab) compareSheet(ab.slot); return; }
  if (t.dataset.tab) { state.tab = t.dataset.tab; renderAll(); return; }
  if (t.dataset.song) { state.tab = "songs"; state.songId = t.dataset.song; state.songTab = "master"; renderAll(); return; }
  if (t.dataset.songtab) { state.songTab = t.dataset.songtab; renderAll(false); return; }
  if (t.id === "back") { state.songId = null; renderAll(); return; }
  if (t.id === "open-import") { importSheet(); return; }
  if (t.dataset.songmenu) { songMenuSheet(t.dataset.songmenu); return; }
  if (t.dataset.assetmenu) { assetMenuSheet(t.dataset.assetmenu); return; }

  if (act === "close") { closeSheet(); return; }
  if (act === "connect") { closeSheet(); connectFolder(); return; }
  if (act === "regrant") { regrantFolder(); return; }
  if (act === "pick-folder") { closeSheet(); $("#pick-folder").click(); return; }
  if (act === "pick-files") { closeSheet(); $("#pick-files").click(); return; }
  if (act === "demo") { closeSheet(); loadDemo(); renderAll(); return; }
  if (act === "export") { exportBackup(); return; }
  if (act === "wipe") { confirmSheet("Erase everything?", "Deletes all songs, assets, audio copies, and history stored in this browser. This cannot be undone.", "do-wipe", ""); return; }
  if (act === "do-wipe") { wipeAll(); return; }
  if (act === "new-song") { textSheet("New song", "Creates a song with default master slots.", "Song title", "save-new-song"); return; }
  if (act === "save-new-song") {
    const v = $("#tx-in").value.trim(); if (!v) return;
    const { song: s, created } = ensureSong(v);
    if (created) record(s.id, "Song", "Structure Updated", `${s.title} created with default master slots.`);
    state.songId = s.id; closeSheet(); renderAll(); return;
  }
  if (act === "add-slot") { textSheet("New master slot", "Adds a structural slot to this song.", "Slot name (e.g. Verse 2)", "save-slot"); return; }
  if (act === "save-slot") { const v = $("#tx-in").value.trim(); if (!v) return; addSlot(v); closeSheet(); renderAll(false); return; }
  if (act === "log-change") { logChangeSheet(); return; }
  if (act === "lc-save") {
    record(song().id, $("#lc-target").value, $("#lc-op").value, $("#lc-sum").value.trim() || "Manual entry.");
    closeSheet(); state.songTab = "changes"; renderAll(false); toast("Change logged"); return;
  }
  if (act === "rename-song") { renameRef = t.dataset.ref; const s = state.songs.find(x => x.id === renameRef); textSheet("Rename song", "Logged in the change record.", "Title", "save-rename", s.title); return; }
  if (act === "save-rename") { renameSong(renameRef, $("#tx-in").value); closeSheet(); renderAll(false); return; }
  if (act === "confirm-del-song") { const s = state.songs.find(x => x.id === t.dataset.ref); confirmSheet(`Delete “${s.title}”?`, "Removes the song, its assets, its local audio copies, and its history.", "do-del-song", s.id); return; }
  if (act === "do-del-song") { deleteSong(t.dataset.ref); closeSheet(); renderAll(); return; }
  if (act === "confirm-del-asset") { const a = byId(t.dataset.ref); confirmSheet(`Remove “${a.title}”?`, "Removes it from the library and clears any slots using it. Original files on disk are not touched.", "do-del-asset", a.id); return; }
  if (act === "do-del-asset") { deleteAsset(t.dataset.ref); closeSheet(); renderAll(false); return; }
  if (act === "smart-import") {
    closeSheet(); importFiles(pendingFiles, { smart: true }); pendingFiles = null; return;
  }
  if (act === "files-new") {
    const name = $("#ft-new").value.trim() || "Imported " + new Date().toLocaleDateString();
    closeSheet(); importFiles(pendingFiles, { newSongName: name }); pendingFiles = null; return;
  }
  if (act === "reanalyze") { reanalyzePreviewSheet(); return; }
  if (act === "do-reanalyze") { applyReanalyze(); return; }
  if (t.dataset.filestarget) { closeSheet(); importFiles(pendingFiles, { targetSongId: t.dataset.filestarget }); pendingFiles = null; return; }
  if (act === "ip-close") { state.importing = null; closeSheet(); renderAll(false); return; }

  if (t.dataset.decision) {
    state.tab = "songs"; state.songId = t.dataset.dsong; state.songTab = "master"; renderAll();
    if (t.dataset.decision === "slot") compareSheet(t.dataset.dslot);
    else versionCompareSheet(t.dataset.dsong);
    return;
  }
  if (t.dataset.versioncompare) { versionCompareSheet(t.dataset.versioncompare); return; }
  if (t.dataset.pinmaster) { const a = byId(t.dataset.pinmaster); pinMaster(a.songId, a.id); closeSheet(); renderAll(false); return; }
  if (t.dataset.compare) { compareSheet(t.dataset.compare); return; }
  if (t.dataset.assign !== undefined) { assign(t.dataset.slotref, t.dataset.assign === "none" ? null : t.dataset.assign); closeSheet(); renderAll(false); return; }
  if (t.dataset.state) { setSlotState(t.dataset.slotref, t.dataset.state); closeSheet(); renderAll(false); return; }
  if (t.dataset.savenote) { saveNote(t.dataset.savenote, $("#slot-note").value); closeSheet(); renderAll(false); toast("Note saved"); return; }
  if (t.dataset.removeslot) { removeSlot(t.dataset.removeslot); closeSheet(); renderAll(false); return; }
  if (t.dataset.moveslot) { moveSlot(t.dataset.slotref, parseInt(t.dataset.moveslot, 10)); closeSheet(); renderAll(false); return; }

  if (t.dataset.ablisten) {
    const a = byId(ab[t.dataset.ablisten]);
    if (state.npAsset && state.npAsset.id === a.id) { Player.playing() ? Player.pause() : Player.resume(); }
    else Player.switchTo(a);
    ab.kind === "master" ? versionCompareSheet(ab.songId) : compareSheet(ab.slot);
    return;
  }
  if (t.dataset.abchoose) {
    const winner = byId(ab[t.dataset.abchoose]);
    if (ab.kind === "master") { pinMaster(ab.songId, winner.id); }
    else { resolveDecision(ab.slot, winner.id); toast(winner.title + " locked ✓"); }
    Player.stop(); ab = null; closeSheet(); renderAll(false);
    return;
  }

  const slotEl = e.target.closest("[data-slot]");
  if (slotEl && !e.target.closest("button")) slotSheet(slotEl.dataset.slot);
});

document.addEventListener("change", e => {
  if (e.target.dataset && e.target.dataset.abpick) {
    ab[e.target.dataset.abpick] = e.target.value;
    ab.kind === "master" ? versionCompareSheet(ab.songId) : compareSheet(ab.slot);
  }
});
$("#scrim").addEventListener("click", () => { if (!state.importing) closeSheet(); });
$("#np-play").addEventListener("click", () => { Player.playing() ? Player.pause() : Player.resume(); });
$("#np-stop").addEventListener("click", () => Player.stop());
$("#np-track").addEventListener("pointerdown", ev => {
  const r = $("#np-track").getBoundingClientRect();
  Player.seek(Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width)));
});
$("#pick-folder").addEventListener("change", e => {
  const files = Array.from(e.target.files || []);
  e.target.value = "";
  if (!files.length) return;
  const hasPaths = files.some(f => f.webkitRelativePath);
  if (hasPaths) importFiles(files);
  else filesTargetSheet(files.filter(f => C.isAudioName(f.name)));
});
$("#pick-files").addEventListener("change", e => {
  const files = Array.from(e.target.files || []).filter(f => C.isAudioName(f.name));
  e.target.value = "";
  if (!files.length) { toast("No audio files selected"); return; }
  filesTargetSheet(files);
});
window.addEventListener("resize", () => drawWaves(document));
document.addEventListener("visibilitychange", () => { if (!document.hidden && dirHandle) reconcile(false).catch(() => {}); });

/* ============================ boot ============================ */
(async function boot() {
  idb = await openDB();
  if (memoryMode) $("#env-pill").textContent = "Memory mode — nothing persists here";
  const [songs, assets, events] = await Promise.all([dbAll("songs"), dbAll("assets"), dbAll("events")]);
  state.songs = songs.sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
  state.assets = assets;
  state.events = events.sort((a, b) => b.t - a.t);
  await restoreFolder().catch(() => {});
  runDecisionEngine();
  renderAll();
  queueAnalysis(state.assets.map(a => a.id));
})();

/* exposed for automated tests */
window.__AOS = { state, importFiles, loadDemo, record, resolveDecision };
})();
