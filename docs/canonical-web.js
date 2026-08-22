/* Artist OS — web canonical metadata bridge.
   Keeps canonical sync entities durable without making the legacy web UI an
   authority over Master Composition or Decisions. */
(function (g) {
  "use strict";

  const DB_NAME = "artist-os-canonical";
  const DB_VER = 1;
  const STORES = ["songs", "assets", "events", "decisions", "masterCompositions", "tombstones"];
  const STORE_BY_KIND = {
    song: "songs",
    asset: "assets",
    event: "events",
    decision: "decisions",
    masterComposition: "masterCompositions"
  };

  const stampOf = value => value && (value.updatedAt || value.created || value.t || 0) || 0;
  const tombstoneKey = (kind, id) => kind + ":" + id;

  function normalizeIncomingChanges(changes, existingSongs) {
    const songs = existingSongs || [];
    const legacy = [];
    const canonical = [];

    for (const change of changes || []) {
      if (!change || !STORE_BY_KIND[change.kind]) continue;

      if (change.kind === "decision" || change.kind === "masterComposition") {
        canonical.push(change);
        continue;
      }

      if (change.kind === "song" && change.deleted) {
        const existing = songs.find(song => song.id === change.id);
        if (!existing) continue;
        const archived = {
          ...existing,
          status: "archived",
          updatedAt: change.updatedAt || stampOf(existing)
        };
        const normalized = {
          kind: "song",
          id: change.id,
          updatedAt: change.updatedAt || stampOf(existing),
          data: archived
        };
        legacy.push(normalized);
        canonical.push(normalized);
        continue;
      }

      legacy.push(change);
      canonical.push(change);
    }

    return { legacy, canonical };
  }

  function mergeByUpdatedAt(local, cached) {
    const map = new Map((local || []).map(item => [item.id, item]));
    for (const incoming of cached || []) {
      const current = map.get(incoming.id);
      if (!current || stampOf(incoming) > stampOf(current)) map.set(incoming.id, incoming);
    }
    return [...map.values()];
  }

  function applyTombstones(list, tombstones, kind) {
    const relevant = (tombstones || []).filter(t => t.kind === kind);
    if (!relevant.length) return list || [];
    return (list || []).filter(item => {
      const t = relevant.find(x => x.entityId === item.id);
      return !t || stampOf(item) >= (t.updatedAt || 0);
    });
  }

  function canonicalSourceAssetID(section) {
    const source = ((section && section.selections) || []).find(selection => selection.kind === "sourceAsset");
    return source && source.referenceId ? source.referenceId : null;
  }

  function projectCanonicalSong(song, composition) {
    if (!song || !composition) return song;
    const legacyByID = new Map(((song.sections) || []).map(section => [section.id, section]));
    const sections = ((composition.sections) || []).map(section => {
      const legacy = legacyByID.get(section.id) || {};
      return {
        ...legacy,
        id: section.id,
        name: section.name != null ? section.name : (legacy.name || "Section"),
        role: section.role != null ? section.role : (legacy.role || ""),
        assetId: canonicalSourceAssetID(section),
        state: section.state != null ? section.state : (legacy.state || "open"),
        conf: section.confidence != null ? section.confidence : (legacy.conf || 0),
        note: section.note != null ? section.note : (legacy.note || "")
      };
    });
    const locked = sections.filter(section => section.state === "locked").length;
    const progress = sections.length ? locked / sections.length : 0;
    const unresolved = sections.filter(section => section.state === "needsDecision").map(section => section.name);
    const risk = unresolved.length
      ? unresolved.join(", ") + " decision unresolved"
      : (sections.length && progress === 1 ? "Master locked" : "In assembly");

    return {
      ...song,
      sections,
      masterAssetId: composition.outputAssetId || null,
      progress,
      risk
    };
  }

  function projectCanonicalSongs(songs, compositions) {
    const newestBySong = new Map();
    for (const composition of compositions || []) {
      if (!composition || !composition.songId) continue;
      const current = newestBySong.get(composition.songId);
      if (!current || stampOf(composition) > stampOf(current)) newestBySong.set(composition.songId, composition);
    }
    return (songs || []).map(song => projectCanonicalSong(song, newestBySong.get(song.id)));
  }

  const api = {
    STORE_BY_KIND,
    stampOf,
    normalizeIncomingChanges,
    mergeByUpdatedAt,
    applyTombstones,
    canonicalSourceAssetID,
    projectCanonicalSong,
    projectCanonicalSongs
  };
  g.AOSCanonicalWeb = api;

  if (typeof window === "undefined" || !("indexedDB" in g) || typeof g.fetch !== "function") return;

  let dbPromise = null;
  function openDB() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise(resolve => {
      let req;
      try { req = indexedDB.open(DB_NAME, DB_VER); }
      catch (e) { return resolve(null); }
      req.onupgradeneeded = () => {
        const db = req.result;
        for (const store of STORES) {
          if (!db.objectStoreNames.contains(store)) db.createObjectStore(store, { keyPath: "id" });
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
    });
    return dbPromise;
  }

  async function dbPut(store, value) {
    const db = await openDB();
    if (!db) return;
    await new Promise((resolve, reject) => {
      const tx = db.transaction(store, "readwrite");
      tx.objectStore(store).put(value);
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  }

  async function dbDelete(store, id) {
    const db = await openDB();
    if (!db) return;
    await new Promise((resolve, reject) => {
      const tx = db.transaction(store, "readwrite");
      tx.objectStore(store).delete(id);
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  }

  async function dbAll(store) {
    const db = await openDB();
    if (!db) return [];
    return new Promise(resolve => {
      const req = db.transaction(store).objectStore(store).getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = () => resolve([]);
    });
  }

  async function persistChange(change) {
    const store = STORE_BY_KIND[change.kind];
    if (!store) return;
    const key = tombstoneKey(change.kind, change.id);
    if (change.deleted) {
      await Promise.all([
        dbDelete(store, change.id),
        dbPut("tombstones", {
          id: key,
          kind: change.kind,
          entityId: change.id,
          updatedAt: change.updatedAt || Date.now()
        })
      ]);
      return;
    }
    const entity = { ...(change.data || {}), id: change.id, updatedAt: change.updatedAt || stampOf(change.data) };
    await Promise.all([dbPut(store, entity), dbDelete("tombstones", key)]);
  }

  async function persistChanges(changes) {
    for (const change of changes || []) await persistChange(change);
  }

  async function hydrateRuntime() {
    const runtime = g.__AOS;
    if (!runtime || !runtime.state) return false;
    const [songs, assets, events, decisions, masterCompositions, tombstones] = await Promise.all([
      dbAll("songs"), dbAll("assets"), dbAll("events"), dbAll("decisions"), dbAll("masterCompositions"), dbAll("tombstones")
    ]);
    const state = runtime.state;
    state.songs = applyTombstones(mergeByUpdatedAt(state.songs, songs), tombstones, "song");
    state.assets = applyTombstones(mergeByUpdatedAt(state.assets, assets), tombstones, "asset");
    state.events = applyTombstones(mergeByUpdatedAt(state.events, events), tombstones, "event")
      .sort((a, b) => (b.t || 0) - (a.t || 0));
    state.decisions = applyTombstones(mergeByUpdatedAt(state.decisions || [], decisions), tombstones, "decision");
    state.masterCompositions = applyTombstones(
      mergeByUpdatedAt(state.masterCompositions || [], masterCompositions), tombstones, "masterComposition"
    );
    // The existing web UI still renders through Song-shaped compatibility fields.
    // Project canonical Master Composition into that in-memory view only; do not
    // write the projection back to the legacy IndexedDB Song store.
    state.songs = projectCanonicalSongs(state.songs, state.masterCompositions);
    if (typeof runtime.renderAll === "function") runtime.renderAll(false);
    return true;
  }
  api.hydrateRuntime = hydrateRuntime;
  api.persistChanges = persistChanges;

  const nativeFetch = g.fetch.bind(g);
  g.fetch = async function canonicalAwareFetch(input, init) {
    const response = await nativeFetch(input, init);
    const url = typeof input === "string" ? input : (input && input.url) || "";
    if (!response.ok || !/\/v1\/sync\/pull(?:\?|$)/.test(url)) return response;

    try {
      const body = await response.clone().json();
      const existingSongs = g.__AOS && g.__AOS.state ? g.__AOS.state.songs : [];
      const normalized = normalizeIncomingChanges(body.changes || [], existingSongs);
      await persistChanges(normalized.canonical);
      setTimeout(() => hydrateRuntime().catch(() => {}), 120);
      return new Response(JSON.stringify({ ...body, changes: normalized.legacy }), {
        status: response.status,
        statusText: response.statusText,
        headers: response.headers
      });
    } catch (e) {
      return response;
    }
  };

  const hydrateWhenReady = () => {
    let tries = 0;
    const timer = setInterval(() => {
      tries += 1;
      if (g.__AOS && g.__AOS.state) {
        clearInterval(timer);
        setTimeout(() => hydrateRuntime().catch(() => {}), 250);
      } else if (tries >= 80) clearInterval(timer);
    }, 25);
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", hydrateWhenReady, { once: true });
  else hydrateWhenReady();
})(typeof window !== "undefined" ? window : globalThis);
