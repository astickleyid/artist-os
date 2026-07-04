/* Artist OS — web (local-first). All data stays on this device. */
(function () {
"use strict";
const C = window.AOSCore;
const Sync = window.AOSSync;
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
  tab: "home", songId: null, songTab: "master",
  npAsset: null, importing: null, watchStatus: null, lastSeenHome: 0
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

async function persistSong(s) {
  s.updatedAt = now();
  await dbPut("songs", s);
  markDirty("song", s.id);
}
async function persistAsset(a) {
  a.updatedAt = now();
  await dbPut("assets", a);
  markDirty("asset", a.id);
}
function record(songId, target, op, summary, observed = false) {
  const e = { id: uid(), songId, target, op, summary, t: now(), observed };
  state.events.unshift(e);
  dbPut("events", e);
  markDirty("event", e.id);
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
  async playRange(asset, start, end) {
    // Preview just one section: start at `start`, auto-stop at `end`.
    if (this._rangeTimer) { clearTimeout(this._rangeTimer); this._rangeTimer = null; }
    await this.play(asset, start);
    const ms = Math.max(200, (end - start) * 1000);
    this._rangeTimer = setTimeout(() => { this.pause(); }, ms);
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
  markDirty("song", id, true);
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
  markDirty("asset", id, true);
  toast(`Removed ${a.title}`);
}
function resolveDecision(slotId, winnerId) {
  assign(slotId, winnerId);
  setSlotState(slotId, "locked");
}

/* ---------- sync: Cloudflare push/pull + device linking + opt-in blobs ---------- */
const SYNC_URL = window.AOS_SYNC_URL || "https://artist-os-sync.astickley9.workers.dev";
const dirty = Sync.makeDirtyTracker();
let syncState = { accountId: null, token: null, seq: 0, status: "off", lastError: null };
let pushTimer = null;

async function syncApi(path, opts = {}) {
  const headers = Object.assign({}, opts.headers);
  if (syncState.token) headers.authorization = "Bearer " + syncState.token;
  if (opts.body !== undefined && !(opts.body instanceof Blob) && !(opts.body instanceof ArrayBuffer)) {
    headers["content-type"] = "application/json";
    opts = { ...opts, body: JSON.stringify(opts.body) };
  }
  const res = await fetch(SYNC_URL + path, { ...opts, headers });
  if (!res.ok) {
    const msg = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(msg.error || ("sync error " + res.status));
  }
  return res;
}

async function loadSyncState() {
  const saved = await dbGet("kv", "sync-account").catch(() => null);
  if (saved && saved.value) syncState = { ...syncState, ...saved.value, status: "on" };
}
async function saveSyncState() {
  await dbPut("kv", { key: "sync-account", value: {
    accountId: syncState.accountId, token: syncState.token, seq: syncState.seq
  } });
}

async function enableSync() {
  if (syncState.token) return syncState;
  const res = await syncApi("/v1/account", { method: "POST" });
  const body = await res.json();
  syncState = { ...syncState, accountId: body.accountId, token: body.token, status: "on" };
  await saveSyncState();
  await pushAllToCloud();
  return syncState;
}

async function linkStart() {
  const res = await syncApi("/v1/link/start", { method: "POST" });
  return res.json();
}
async function linkClaim(code) {
  const res = await fetch(SYNC_URL + "/v1/link/claim", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: code.toUpperCase().trim() })
  });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || "link failed");
  const body = await res.json();
  syncState = { ...syncState, accountId: body.accountId, token: body.token, status: "on", seq: 0 };
  await saveSyncState();
  await pullFromCloud();
  return syncState;
}

function markDirty(kind, id, deleted) {
  dirty.mark(kind, id, deleted);
  if (syncState.status !== "on") return;
  clearTimeout(pushTimer);
  pushTimer = setTimeout(pushDirtyToCloud, 1500);
}

function entityFor(kind, id) {
  if (kind === "song") return state.songs.find(s => s.id === id);
  if (kind === "asset") return state.assets.find(a => a.id === id);
  return state.events.find(e => e.id === id);
}

async function pushDirtyToCloud() {
  if (syncState.status !== "on" || !dirty.size) return;
  const items = dirty.drain();
  const changes = items.map(({ kind, id, deleted }) => {
    if (deleted) return { kind, id, updatedAt: now(), deleted: true };
    const entity = entityFor(kind, id);
    return entity ? Sync.toChange(kind, entity) : null;
  }).filter(Boolean);
  if (!changes.length) return;
  try {
    await syncApi("/v1/sync/push", { method: "POST", body: { changes } });
    syncState.lastError = null;
  } catch (e) {
    syncState.lastError = e.message;
    items.forEach(i => dirty.mark(i.kind, i.id, i.deleted));
  }
}

async function pushAllToCloud() {
  const changes = [
    ...state.songs.map(s => Sync.toChange("song", s)),
    ...state.assets.filter(a => !a.demo).map(a => Sync.toChange("asset", a)),
    ...state.events.map(e => Sync.toChange("event", e))
  ];
  for (let i = 0; i < changes.length; i += 200) {
    await syncApi("/v1/sync/push", { method: "POST", body: { changes: changes.slice(i, i + 200) } });
  }
}

async function pullFromCloud() {
  let hasMore = true;
  while (hasMore) {
    const res = await syncApi(`/v1/sync/pull?since=${syncState.seq}`);
    const body = await res.json();
    for (const change of body.changes) {
      const key = change.kind === "song" ? "songs" : change.kind === "asset" ? "assets" : "events";
      state[key] = Sync.applyRemoteChange(state[key], change);
    }
    syncState.seq = body.seq;
    hasMore = body.hasMore;
  }
  await saveSyncState();
  renderAll(false);
}

async function uploadAssetToCloud(assetId) {
  const a = byId(assetId);
  const rec = await dbGet("blobs", assetId);
  if (!a || !rec || !rec.blob) throw new Error("asset has no local audio to upload");
  await enableSync();
  await syncApi(`/v1/blob/${assetId}`, {
    method: "PUT",
    headers: { "content-type": rec.blob.type || "application/octet-stream" },
    body: rec.blob
  });
  a.cloudKey = assetId;
  await persistAsset(a); // persistAsset already marks it dirty for the next push
  toast("Uploaded — available on every synced device");
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

/* ---------------- section intelligence ---------------- */
// Decode an asset and run structural segmentation. Stores proposed sections
// on the asset (artist confirms/renames later). Heavier than BPM/key, so it
// runs on demand, not in the background queue.
const SEGMENT_SIZE_CAP = 60 * 1024 * 1024;
async function segmentAsset(id) {
  const a = byId(id);
  if (!a) return null;
  if (a.demo) { // demo assets have no real audio — synthesize a plausible structure
    a.sections = demoSections(a);
    await persistAsset(a);
    return a.sections;
  }
  const rec = await dbGet("blobs", id);
  if (!rec || !rec.blob || rec.blob.size > SEGMENT_SIZE_CAP) return null;
  if (!decodeCtx) decodeCtx = new (window.AudioContext || window.webkitAudioContext)();
  const buf = await rec.blob.arrayBuffer();
  const audio = await decodeCtx.decodeAudioData(buf.slice(0));
  // downsample to mono ~11025 for the O(n^2) SSM to stay fast
  const src = audio.getChannelData(0);
  const targetSR = 11025;
  const ratio = Math.max(1, Math.floor(audio.sampleRate / targetSR));
  const sr = audio.sampleRate / ratio;
  const mono = new Float32Array(Math.floor(src.length / ratio));
  for (let i = 0; i < mono.length; i++) mono[i] = src[i * ratio];
  const result = window.AOSSegment.segment(mono, sr, { hopSeconds: 0.5, minSectionSeconds: 6 });
  a.sections = result.sections.map(x => ({
    id: uid(), label: x.label, start: x.start, end: x.end,
    confidence: x.confidence, cluster: x.cluster, confirmed: false
  }));
  a.segmentedAt = now();
  await persistAsset(a);
  record(a.songId, "Structure", "Analyzed",
    `Detected ${a.sections.length} sections in ${a.title} — confirm or rename them.`, true);
  return a.sections;
}

function demoSections(a) {
  // deterministic pseudo-structure for demo/file-less assets
  const dur = a.dur || 180;
  const plan = [["Intro", .06], ["Verse", .18], ["Hook", .18], ["Verse", .16], ["Hook", .16], ["Bridge", .12], ["Hook", .14]];
  let t = 0; const out = [];
  for (const [label, frac] of plan) {
    const len = dur * frac;
    out.push({ id: uid(), label, start: +t.toFixed(2), end: +(t + len).toFixed(2),
      confidence: label === "Hook" ? .72 : label === "Intro" ? .7 : .55, cluster: 0, confirmed: false });
    t += len;
  }
  return out;
}

// Gather every confirmed/proposed section-slice across all versions of a song,
// carrying tempo/key so the assembly board + unified folders can show them.
function sectionSlicesFor(songId) {
  const out = [];
  for (const a of assetsFor(songId)) {
    if (!a.sections) continue;
    for (const sec of a.sections) {
      out.push({
        assetId: a.id, assetTitle: a.title, version: a.version || "v1",
        sectionId: sec.id, label: sec.label, start: sec.start, end: sec.end,
        confidence: sec.confidence, bpm: a.bpm || null, keyName: a.keyName || null
      });
    }
  }
  return out;
}

/* ---------------- cross-version render (Web Audio -> WAV) ---------------- */
// Decode each needed version once, slice each pick, equal-power crossfade at
// seams, write a downloadable WAV. Honest cuts — no time-stretch in v1.
async function renderRecipe(recipe, opts) {
  opts = opts || {};
  if (!decodeCtx) decodeCtx = new (window.AudioContext || window.webkitAudioContext)();
  const outSR = 44100;

  // decode each distinct source asset once
  const need = [...new Set(recipe.map(p => p.assetId))];
  const decoded = {};
  for (const id of need) {
    const rec = await dbGet("blobs", id);
    if (!rec || !rec.blob) throw new Error("Missing audio for a selected version.");
    const buf = await rec.blob.arrayBuffer();
    decoded[id] = await decodeCtx.decodeAudioData(buf.slice(0));
  }

  const xf = opts.crossfade != null ? opts.crossfade : 0.04; // seconds
  // total length: sum of slices minus crossfade overlaps
  let totalSec = 0;
  recipe.forEach((p, i) => { totalSec += Math.max(0, p.end - p.start); if (i > 0) totalSec -= xf; });
  const totalSamples = Math.max(1, Math.ceil(totalSec * outSR));
  const outL = new Float32Array(totalSamples);
  const outR = new Float32Array(totalSamples);

  let writePos = 0; // in samples
  recipe.forEach((p, idx) => {
    const audio = decoded[p.assetId];
    const inSR = audio.sampleRate;
    const chL = audio.getChannelData(0);
    const chR = audio.numberOfChannels > 1 ? audio.getChannelData(1) : chL;
    const startS = Math.floor(p.start * inSR);
    const endS = Math.min(chL.length, Math.floor(p.end * inSR));
    const sliceLen = endS - startS;
    if (sliceLen <= 0) return;

    // resample factor input->output
    const step = inSR / outSR;
    const outLen = Math.floor(sliceLen / step);
    const xfSamples = Math.floor(xf * outSR);
    // where this slice begins in the output (overlap previous by xfSamples)
    const base = idx === 0 ? 0 : writePos - xfSamples;

    for (let i = 0; i < outLen; i++) {
      const srcIdx = startS + Math.floor(i * step);
      let l = chL[srcIdx] || 0, r = chR[srcIdx] || 0;
      const oi = base + i;
      if (oi < 0 || oi >= totalSamples) continue;
      // equal-power crossfade over the first xfSamples of every slice after the first
      if (idx > 0 && i < xfSamples) {
        const t = i / xfSamples;               // 0..1
        const gIn = Math.sin(t * Math.PI / 2); // fade in (equal power)
        outL[oi] = outL[oi] * Math.cos(t * Math.PI / 2) + l * gIn;
        outR[oi] = outR[oi] * Math.cos(t * Math.PI / 2) + r * gIn;
      } else {
        outL[oi] = l; outR[oi] = r;
      }
    }
    writePos = base + outLen;
  });

  return encodeWAV([outL.subarray(0, writePos), outR.subarray(0, writePos)], outSR);
}

// 16-bit PCM stereo WAV encoder
function encodeWAV(channels, sampleRate) {
  const len = channels[0].length;
  const numCh = channels.length;
  const buffer = new ArrayBuffer(44 + len * numCh * 2);
  const view = new DataView(buffer);
  const ws = (off, s) => { for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i)); };
  ws(0, "RIFF"); view.setUint32(4, 36 + len * numCh * 2, true); ws(8, "WAVE");
  ws(12, "fmt "); view.setUint32(16, 16, true); view.setUint16(20, 1, true);
  view.setUint16(22, numCh, true); view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * numCh * 2, true); view.setUint16(32, numCh * 2, true);
  view.setUint16(34, 16, true); ws(36, "data"); view.setUint32(40, len * numCh * 2, true);
  let off = 44;
  for (let i = 0; i < len; i++) {
    for (let c = 0; c < numCh; c++) {
      let v = Math.max(-1, Math.min(1, channels[c][i]));
      view.setInt16(off, v < 0 ? v * 0x8000 : v * 0x7FFF, true);
      off += 2;
    }
  }
  return new Blob([view], { type: "audio/wav" });
}

/* ---------------- structure/assembly actions ---------------- */
async function runSegmentation(assetId) {
  const a = byId(assetId);
  if (!a) return;
  toast("Analyzing structure…");
  try {
    const secs = await segmentAsset(assetId);
    if (!secs) { toast("Couldn't analyze this file"); return; }
    toast(`Found ${secs.length} sections — confirm or rename`);
    renderAll(false);
    pushDirtyToCloud && pushDirtyToCloud().catch(() => {});
  } catch (e) { toast("Analysis failed"); }
}

function sectionRef(ref) {
  const [assetId, secId] = ref.split(":");
  const a = byId(assetId);
  const sec = a && a.sections ? a.sections.find(x => x.id === secId) : null;
  return { a, sec };
}

async function confirmSection(ref) {
  const { a, sec } = sectionRef(ref);
  if (!sec) return;
  sec.confirmed = true;
  await persistAsset(a);
  toast(`${sec.label} confirmed`);
  renderAll(false);
}

function renameSectionSheet(ref) {
  const { sec } = sectionRef(ref);
  if (!sec) return;
  state.renamingSection = ref;
  const common = ["Intro", "Verse", "Pre-Chorus", "Hook", "Chorus", "Bridge", "Outro"];
  $("#sheet").innerHTML = `<div class="grab"></div>
    <h3>Rename section</h3>
    <div class="hint">Currently “${esc(sec.label)}”. Pick a label or type your own — this confirms the section.</div>
    <div style="display:flex;flex-wrap:wrap;gap:7px;margin-bottom:12px">
      ${common.map(l => `<button class="btn ${l===sec.label?"gold":""}" data-seclabel="${l}" style="min-height:38px;padding:8px 13px;font-size:13px">${l}</button>`).join("")}
    </div>
    <input class="field" id="sec-custom" placeholder="Custom label" value="">
    <div class="sheet-actions"><button class="btn" data-act="close">Cancel</button>
      <button class="btn gold" data-act="save-seclabel">Save</button></div>`;
  openSheet();
}

async function applySectionLabel(label) {
  if (!state.renamingSection || !label.trim()) return;
  const { a, sec } = sectionRef(state.renamingSection);
  if (!sec) return;
  sec.label = label.trim();
  sec.confirmed = true;
  await persistAsset(a);
  state.renamingSection = null;
  closeSheet();
  toast("Section updated");
  renderAll(false);
}

async function playSection(ref) {
  const { a, sec } = sectionRef(ref);
  if (!a || !sec) return;
  if (a.demo) { Player.toggle(a); return; } // demo: just play the generative preview
  await Player.playRange(a, sec.start, sec.end);
}

function startAssembly() {
  const s = song(); if (!s) return;
  const withSecs = assetsFor(s.id).filter(a => a.sections && a.sections.length);
  if (!withSecs.length) { toast("Detect sections first"); return; }
  // Build slots from the master's structure order, defaulting each to the best
  // available source: prefer the pinned master version, else the latest.
  const master = byId(s.masterAssetId) || withSecs[0];
  const order = ["Intro", "Verse", "Pre-Chorus", "Hook", "Chorus", "Bridge", "Outro"];
  const slices = sectionSlicesFor(s.id);
  // unique labels present, in canonical order
  const labels = [...new Set(slices.map(x => x.label))]
    .sort((a, b) => (order.indexOf(a) === -1 ? 99 : order.indexOf(a)) - (order.indexOf(b) === -1 ? 99 : order.indexOf(b)));
  const picks = labels.map(label => {
    // prefer a slice from the master version for this label, else first available
    const fromMaster = slices.find(x => x.label === label && x.assetId === master.id);
    const pick = fromMaster || slices.find(x => x.label === label);
    return { slotId: uid(), label, assetId: pick.assetId, sectionId: pick.sectionId,
      start: pick.start, end: pick.end, bpm: pick.bpm, keyName: pick.keyName, crossfade: 0.04 };
  });
  state.asmRecipe = { songId: s.id, picks };
  state.structureView = "assemble";
  renderAll(false);
}

function swapAssemblySource(index, value) {
  if (!state.asmRecipe) return;
  const [assetId, sectionId] = value.split(":");
  const slice = sectionSlicesFor(state.asmRecipe.songId).find(x => x.assetId === assetId && x.sectionId === sectionId);
  if (!slice) return;
  const p = state.asmRecipe.picks[index];
  Object.assign(p, { assetId: slice.assetId, sectionId: slice.sectionId, start: slice.start, end: slice.end, bpm: slice.bpm, keyName: slice.keyName });
  renderAll(false);
}

async function playRecipeSlice(index) {
  if (!state.asmRecipe) return;
  const p = state.asmRecipe.picks[index];
  const a = byId(p.assetId);
  if (!a) return;
  if (a.demo) { Player.toggle(a); return; }
  await Player.playRange(a, p.start, p.end);
}

async function renderAndDownload() {
  if (!state.asmRecipe) return;
  const s = song();
  const recipe = state.asmRecipe.picks;
  const v = window.AOSAssembly.validateRecipe(recipe);
  if (!v.ok) { toast(v.errors[0]); return; }
  // demo assets can't be truly rendered (no real audio) — be honest about it
  if (recipe.some(p => { const a = byId(p.assetId); return a && a.demo; })) {
    toast("Demo versions can't be rendered — import real audio to export");
    return;
  }
  toast("Rendering… this runs entirely on your device");
  try {
    const blob = await renderRecipe(recipe, { crossfade: 0.04 });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    const name = (s ? s.title.replace(/[^a-z0-9]+/gi, "-").toLowerCase() : "assembled") + "-assembled.wav";
    a.href = url; a.download = name; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    record(s.id, "Master", "Assembled",
      `Rendered a new version from ${recipe.length} sections across takes → ${name}`, false);
    toast("Downloaded — check your files");
    renderAll(false);
  } catch (e) { toast("Render failed: " + (e.message || "unknown")); }
}

function renderSyncCard() {
  const s = syncState;
  if (s.status !== "on") {
    return `
      <div class="panel" style="padding:14px;margin-bottom:14px">
        <div class="sub">Sync your catalog across devices. Audio stays local unless you explicitly share an asset.</div>
      </div>
      <button class="btn gold" data-act="sync-enable" style="width:100%;margin-bottom:9px">Enable sync</button>
      <button class="btn" data-act="sync-link" style="width:100%;margin-bottom:14px">I have a code from another device</button>`;
  }
  return `
    <div class="panel" style="padding:14px;margin-bottom:14px">
      <div class="row-title" style="font-size:14px">✓ Synced${s.lastError ? " · retrying…" : ""}</div>
      <div class="sub mono" style="margin-top:4px">Account ${esc(s.accountId)}</div>
    </div>
    <button class="btn" data-act="sync-link" style="width:100%;margin-bottom:9px">Link another device</button>`;
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

function decideCard(d) {
  const kicker = d.kind === "master" ? "Pick the master" : "Competing takes";
  return `<button class="decide-card" data-decision="${d.kind}" data-dsong="${d.songId}" ${d.slotId ? `data-dslot="${d.slotId}"` : ""}>
    <div class="dc-top">
      <div class="dc-icon">⚖</div>
      <div class="dc-body">
        <div class="dc-kicker">${kicker}</div>
        <div class="dc-title">${esc(d.title)}</div>
        <div class="dc-detail">${esc(d.detail)}</div>
      </div>
    </div>
    <div class="dc-cta">Compare & decide →</div>
  </button>`;
}

function happenedRow(e) {
  const s = state.songs.find(x => x.id === e.songId);
  return `<div class="happened">
    <div class="hp-dot"></div>
    <div class="hp-body">
      <div class="hp-sum">${esc(e.summary)}</div>
      <div class="hp-meta">${s ? `<span class="sng">${esc(s.title)}</span>` : ""}<span>${C.agoFrom(now(), e.t)}</span></div>
    </div>
  </div>`;
}

function motionCard(m) {
  const s = m.song;
  const p = C.progressOf(s);
  const vc = versionCount(s.id);
  const lastTouch = m.lastTouch ? C.agoFrom(now(), m.lastTouch) : "";
  return `<button class="motion-card" data-song="${s.id}">
    <div class="mc-top">
      <div class="mc-grow">
        <div class="mc-title">${esc(s.title)}</div>
        <div class="mc-meta">${esc(s.status)} · ${vc >= 2 ? vc + " versions · " : ""}${assetsFor(s.id).length} assets</div>
      </div>
      ${m.needsYou ? `<span class="mc-needs">Needs you</span>` : (lastTouch ? `<span class="mc-when">${lastTouch}</span>` : "")}
    </div>
    <div class="mc-bar"><i style="width:${p * 100}%"></i></div>
  </button>`;
}

function renderHome() {
  if (!state.songs.length) return renderOnboard();
  // Freeze the "just happened" cutoff once per session (on first Home paint)
  // so re-renders within the session don't wipe the feed; it advances only
  // when the session's marker is committed below.
  if (state.homeCutoff == null) state.homeCutoff = state.lastSeenHome || 0;
  const feed = C.buildHomeFeed(state.songs, state.assets, state.events, {
    now: now(), lastSeen: state.homeCutoff, recentLimit: 6
  });

  const hour = new Date().getHours();
  const greeting = hour < 5 ? "Late night" : hour < 12 ? "Good morning" : hour < 18 ? "Afternoon" : "Evening";
  const decisionsWord = feed.counts.decisions === 1 ? "decision" : "decisions";

  let html = watchBanner();
  html += `<div class="home-head">
    <div class="home-greeting">${greeting}, STICK</div>
    <div class="home-sub">${feed.counts.decisions
      ? `<b>${feed.counts.decisions} ${decisionsWord}</b> waiting · ${feed.counts.songs} songs in your catalog`
      : `Everything's decided · ${feed.counts.songs} songs in your catalog`}</div>
  </div>`;

  // 1) NEEDS YOU
  html += `<div class="home-sec"><span class="h gold">Needs you</span>${feed.counts.decisions ? `<span class="count">${feed.counts.decisions}</span>` : ""}<span class="rule"></span></div>`;
  if (feed.decisions.length) {
    html += feed.decisions.map(decideCard).join("");
  } else {
    html += `<div class="all-clear">
      <div class="ac-icon">✓</div>
      <div class="ac-txt"><b>All clear</b><div>No decisions pending. Keep making.</div></div>
    </div>`;
  }

  // 2) JUST HAPPENED (only if there's anything new)
  if (feed.recentEvents.length) {
    html += `<div class="home-sec"><span class="h green">Just happened</span><span class="rule"></span></div>`;
    html += feed.recentEvents.map(happenedRow).join("");
  }

  // 3) IN MOTION
  html += `<div class="home-sec"><span class="h muted">In motion</span><span class="rule"></span></div>`;
  html += feed.inMotion.map(motionCard).join("");
  html += `<button class="btn ghost home-add" data-act="new-song">＋ New song</button>`;

  // Persist "seen up to now" so the NEXT session's feed starts fresh, while
  // the current session keeps showing this batch (homeCutoff stays frozen).
  state.lastSeenHome = now();
  dbPut("kv", { key: "lastSeenHome", value: state.lastSeenHome }).catch(() => {});

  return html;
}

function renderSongsList() {
  if (!state.songs.length) return renderOnboard();
  return `<div class="eyebrow">All songs · ${state.songs.length}</div>` +
    state.songs.map(s => songCard(s)).join("") +
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
  if (state.songTab === "structure") body = renderStructure(s);
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
    <div class="segs">${[["master","Master"],["structure","Structure"],["changes","Changes"],["assets","Assets"]].map(([k, l]) =>
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

/* ---------------- STRUCTURE tab: sections + assembly + folders ---------------- */
function confChip(c) {
  const cls = c >= 0.7 ? "ok" : c >= 0.5 ? "mid" : "low";
  const txt = c >= 0.7 ? "likely" : c >= 0.5 ? "maybe" : "guess";
  return `<span class="sr-conf ${cls}">${txt}</span>`;
}

function renderStructure(s) {
  const versions = assetsFor(s.id).filter(a => !a.demo || a.dur);
  const withSections = versions.filter(a => a.sections && a.sections.length);
  const sub = state.structureView || "sections";

  let html = `<div class="segs" style="margin-top:4px">${
    [["sections","Detected sections"],["assemble","Build a version"],["folders","Section folders"]]
      .map(([k,l]) => `<button data-structview="${k}" class="${sub===k?"on":""}">${l}</button>`).join("")
  }</div>`;

  if (sub === "sections") {
    html += `<div class="sec-hint">Artist OS proposes the structure of each version — intro, verse, hook, bridge. It's a starting guess; confirm or rename any section with a tap. Confirmed sections become available to build with.</div>`;
    if (!versions.length) {
      html += `<div class="empty"><div class="big">◫</div><b>No versions to analyze yet</b>Import audio for this song first.</div>`;
      return html;
    }
    for (const a of versions) {
      const secs = a.sections || [];
      html += `<div class="eyebrow" style="margin-top:16px;display:flex;align-items:center;gap:8px">
        ${esc(a.title)} ${a.version ? `· ${esc(a.version)}` : ""}
        ${a.bpm ? `<span class="badge" style="--tint:var(--blue)">${Math.round(a.bpm)} BPM</span>` : ""}
        ${a.keyName ? `<span class="badge">${esc(a.keyName)}</span>` : ""}</div>`;
      if (!secs.length) {
        html += `<button class="btn gold sec-analyze" data-segment="${a.id}">✦ Detect sections in this version</button>`;
      } else {
        html += secs.map((sec, i) => `
          <div class="section-row ${sec.confirmed ? "" : "unconfirmed"}">
            <div class="sr-time">${C.mmss(sec.start)}–${C.mmss(sec.end)}</div>
            <div class="sr-label">
              <div class="sr-name">${esc(sec.label)} ${sec.confirmed ? `<span style="color:var(--green);font-size:12px">✓</span>` : confChip(sec.confidence)}</div>
              <div class="sr-dur">${Math.round(sec.end - sec.start)}s</div>
            </div>
            <div class="sr-actions">
              <button class="mini play" data-secplay="${a.id}:${sec.id}" aria-label="Preview section">▶</button>
              <button class="mini" data-secrename="${a.id}:${sec.id}" aria-label="Rename section">✎</button>
              ${sec.confirmed ? "" : `<button class="mini" data-secconfirm="${a.id}:${sec.id}" aria-label="Confirm section" style="color:var(--green)">✓</button>`}
            </div>
          </div>`).join("");
        html += `<button class="btn ghost" data-segment="${a.id}" style="width:100%;margin-bottom:8px;color:var(--muted)">↻ Re-detect</button>`;
      }
    }
    return html;
  }

  if (sub === "assemble") {
    if (withSections.length < 1) {
      html += `<div class="empty" style="margin-top:20px"><div class="big">✦</div><b>Detect sections first</b>Head to "Detected sections" and analyze at least one version, then build a new version from the pieces you like.</div>`;
      return html;
    }
    const recipe = state.asmRecipe && state.asmRecipe.songId === s.id ? state.asmRecipe.picks : null;
    if (!recipe) {
      html += `<div class="asm-intro"><h3>Build a version from your best parts</h3><p>Pick the source version for each section — the verse from one take, the hook from another. Artist OS renders them into one track with smooth crossfades. Mismatched tempo or key is flagged so you choose with eyes open.</p></div>`;
      html += `<button class="btn gold" data-act="asm-start" style="width:100%">Start from the master structure</button>`;
      return html;
    }
    // render the recipe board
    const seams = window.AOSAssembly.seamsFor(recipe);
    const seamAt = new Set(seams.map(x => x.at));
    const allSlices = sectionSlicesFor(s.id);
    html += `<div class="asm-intro"><h3>Building a new version</h3><p>Tap a section's source to swap which version it comes from. Preview, then render to a downloadable track.</p></div>`;
    recipe.forEach((p, i) => {
      // seam warning before this pick
      if (seamAt.has(i)) {
        const seam = seams.find(x => x.at === i);
        html += `<div class="seam"><span class="s-ic">⚠</span>${seam.issues.map(x => esc(x.detail)).join(" · ")} — cut won't beat-match here</div>`;
      }
      const opts = allSlices.filter(sl => sl.label === p.label);
      html += `<div class="asm-slot">
        <div class="as-idx mono">${String(i + 1).padStart(2, "0")}</div>
        <div class="as-body">
          <div class="as-label">${esc(p.label)}</div>
          <div class="as-src">${p.bpm ? Math.round(p.bpm) + " BPM · " : ""}${p.keyName ? esc(p.keyName) + " · " : ""}${Math.round(p.end - p.start)}s</div>
        </div>
        <button class="as-play" data-asmplay="${i}" aria-label="Preview section">▶</button>
        <select data-asmsrc="${i}">
          ${opts.map(o => `<option value="${o.assetId}:${o.sectionId}" ${o.assetId === p.assetId && o.sectionId === p.sectionId ? "selected" : ""}>${esc(o.version)} · ${esc(o.assetTitle)}</option>`).join("")}
        </select>
      </div>`;
    });
    html += `<div class="asm-total">Total length: ~${C.mmss(window.AOSAssembly.totalDuration(recipe))}${seams.length ? ` · ${seams.length} seam${seams.length>1?"s":""} flagged` : " · clean"}</div>`;
    html += `<div class="asm-render">
      <button class="btn ghost" data-act="asm-reset" style="flex:0 0 auto">Reset</button>
      <button class="btn gold" data-act="asm-render">⬇ Render &amp; download</button>
    </div>`;
    return html;
  }

  if (sub === "folders") {
    const slices = sectionSlicesFor(s.id);
    if (!slices.length) {
      html += `<div class="empty" style="margin-top:20px"><div class="big">🗂</div><b>No sections detected yet</b>Analyze your versions to gather every verse, hook, and bridge across takes into folders here.</div>`;
      return html;
    }
    html += `<div class="sec-hint">Every section across every version, gathered by part. All your choruses in one place — audition them side by side.</div>`;
    const folders = window.AOSAssembly.unifiedFolders(slices);
    const open = state.openFolder;
    html += folders.map(f => `
      <div class="folder">
        <button class="folder-head" data-folder="${esc(f.label)}">
          <div class="fh-ic">${f.label === "Hook" || f.label === "Chorus" ? "★" : "♪"}</div>
          <div class="fh-name">${esc(f.label)}</div>
          <div class="fh-count">${f.items.length} across versions</div>
        </button>
        ${open === f.label ? `<div class="folder-body">${f.items.map(it => `
          <div class="folder-item">
            <button class="fi-play" data-secplay="${it.assetId}:${it.sectionId}" aria-label="Preview">▶</button>
            <div class="fi-body">
              <div class="fi-ver">${esc(it.version)} · ${esc(it.assetTitle)}</div>
              <div class="fi-meta">${C.mmss(it.start)}–${C.mmss(it.end)}${it.bpm ? " · " + Math.round(it.bpm) + " BPM" : ""}${it.keyName ? " · " + esc(it.keyName) : ""}</div>
            </div>
          </div>`).join("")}</div>` : ""}
      </div>`).join("");
    return html;
  }
  return html;
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
    <div class="eyebrow" style="margin-top:18px">Sync</div>
    ${renderSyncCard()}
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
  if (state.tab === "home") v.innerHTML = state.songId && song() ? renderSongView() : renderHome();
  if (state.tab === "songs") v.innerHTML = state.songId && song() ? renderSongView() : renderSongsList();
  if (state.tab === "timeline") v.innerHTML = renderEvents([...state.events].sort((a, b) => b.t - a.t), true);
  if (state.tab === "assets") v.innerHTML = renderAssetCards([...state.assets].sort((a, b) => b.created - a.created), true);
  if (state.tab === "settings") v.innerHTML = renderSettings();
  $("#desk-list").innerHTML = state.songs.length ? `<div class="eyebrow">Catalog</div>` + state.songs.map(s => songCard(s, true)).join("") : "";
  $("#back").classList.toggle("show", (state.tab === "home" || state.tab === "songs") && !!state.songId);
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
    ${(!a.demo && !a.cloudKey) ? `<button class="opt" data-act="cloud-upload" data-cloud-upload="${id}"><span class="dot" style="--tint:var(--blue)"></span>Make available everywhere</button>` : (a.cloudKey ? `<div class="hint" style="padding:8px 4px">☁️ Available on every synced device</div>` : "")}
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
  if (t.dataset.song) { if (state.tab !== "home" && state.tab !== "songs") state.tab = "home"; state.songId = t.dataset.song; state.songTab = "master"; renderAll(); return; }
  if (t.dataset.songtab) { state.songTab = t.dataset.songtab; renderAll(false); return; }
  if (t.dataset.structview) { state.structureView = t.dataset.structview; renderAll(false); return; }
  if (t.dataset.segment) { runSegmentation(t.dataset.segment); return; }
  if (t.dataset.secconfirm) { confirmSection(t.dataset.secconfirm); return; }
  if (t.dataset.secrename) { renameSectionSheet(t.dataset.secrename); return; }
  if (t.dataset.secplay) { e.stopPropagation(); playSection(t.dataset.secplay); return; }
  if (t.dataset.asmplay) { e.stopPropagation(); playRecipeSlice(+t.dataset.asmplay); return; }
  if (t.dataset.folder) { state.openFolder = state.openFolder === t.dataset.folder ? null : t.dataset.folder; renderAll(false); return; }
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
  if (t.dataset.seclabel) { applySectionLabel(t.dataset.seclabel); return; }
  if (act === "save-seclabel") { const v = $("#sec-custom").value.trim(); if (v) applySectionLabel(v); return; }
  if (act === "log-change") { logChangeSheet(); return; }
  if (act === "asm-start") { startAssembly(); return; }
  if (act === "asm-reset") { state.asmRecipe = null; renderAll(false); return; }
  if (act === "asm-render") { renderAndDownload(); return; }
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
  if (act === "sync-enable") {
    try { await enableSync(); renderAll(false); toast("Sync enabled"); }
    catch (e) { toast("Sync failed: " + e.message); }
    return;
  }
  if (act === "sync-link") {
    try {
      if (syncState.status !== "on") await enableSync();
      const { code, expiresInSeconds } = await linkStart();
      openSheet(`
        <h3>Link a device</h3>
        <div class="hint">On your other device, open Settings → Sync → and enter this code within ${Math.round(expiresInSeconds / 60)} minutes.</div>
        <div class="panel" style="padding:24px;text-align:center;margin-bottom:14px">
          <div class="mono" style="font-size:32px;letter-spacing:6px;font-weight:800">${esc(code)}</div>
        </div>
        <div class="eyebrow">Or enter a code from another device</div>
        <input class="field mono" id="link-code" placeholder="XXXXXX" maxlength="6" style="text-transform:uppercase">
        <button class="btn gold" data-act="sync-claim" style="width:100%;margin-top:10px">Claim code</button>`);
    } catch (e) { toast("Could not start linking: " + e.message); }
    return;
  }
  if (act === "sync-claim") {
    const code = $("#link-code").value;
    if (!code) return;
    try {
      await linkClaim(code);
      closeSheet(); renderAll(false);
      toast("Device linked — catalog synced");
    } catch (e) { toast("Link failed: " + e.message); }
    return;
  }
  if (act === "cloud-upload") {
    const id = t.dataset.cloudUpload;
    toast("Uploading…");
    try { await uploadAssetToCloud(id); closeSheet(); renderAll(false); }
    catch (e) { toast("Upload failed: " + e.message); }
    return;
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
  if (e.target.dataset && e.target.dataset.asmsrc != null) {
    swapAssemblySource(+e.target.dataset.asmsrc, e.target.value);
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
  const seen = await dbGet("kv", "lastSeenHome").catch(() => null);
  state.lastSeenHome = seen && seen.value ? seen.value : 0;
  await restoreFolder().catch(() => {});
  runDecisionEngine();
  renderAll();
  queueAnalysis(state.assets.map(a => a.id));
  await loadSyncState();
  if (syncState.status === "on") pullFromCloud().catch(() => {});
  renderAll(false);
})();

/* exposed for automated tests */
window.__AOS = {
  state, importFiles, loadDemo, record, resolveDecision,
  enableSync, linkStart, linkClaim, pushDirtyToCloud, pullFromCloud, uploadAssetToCloud,
  renderAll, segmentAsset, renderRecipe, startAssembly, renderAndDownload,
  get syncState() { return syncState; }
};
})();
