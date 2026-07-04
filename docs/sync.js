/* Artist OS — Cloudflare sync client.
   Contract: metadata-first (songs/assets/events), audio opt-in per asset
   via "Make available everywhere". See Docs/VISION.md + worker/src/index.js.
   Pure helpers (exported as AOSSync for Node testing) are separated from
   the network/IndexedDB-touching runtime below. */
(function (g) {
  "use strict";

  /* ---------- pure: entity <-> wire encoding ---------- */

  // Only fields that matter for cross-device state; excludes local-only
  // runtime fields (blob handles, decoded peaks, etc).
  const SONG_FIELDS = ["id", "title", "era", "status", "progress", "qualityScore",
    "risk", "sections", "masterAssetId", "created", "updatedAt"];
  const ASSET_FIELDS = ["id", "songId", "title", "file", "role", "created", "updatedAt",
    "type", "modifiedAt", "sourcePath", "version", "vOrder", "dur", "hash", "size",
    "bpm", "keyName", "analysisConf", "analyzedAt", "cloudKey"];
  const EVENT_FIELDS = ["id", "songId", "target", "op", "summary", "t", "observed", "confidence"];

  function pick(obj, fields) {
    const out = {};
    for (const f of fields) if (obj[f] !== undefined) out[f] = obj[f];
    return out;
  }

  function toChange(kind, entity, deleted) {
    const updatedAt = entity.updatedAt || entity.created || entity.t || 0;
    if (deleted) return { kind, id: entity.id, updatedAt: Date.now(), deleted: true };
    const fields = kind === "song" ? SONG_FIELDS : kind === "asset" ? ASSET_FIELDS : EVENT_FIELDS;
    return { kind, id: entity.id, updatedAt, data: pick(entity, fields) };
  }

  /* Merge a remote change into a local collection (array), keyed by id.
     Returns a NEW array (caller replaces state.<collection>). Local wins
     on tie (>=) since local was just mutated by the user in that case. */
  function applyRemoteChange(list, change) {
    const idx = list.findIndex(x => x.id === change.id);
    if (change.deleted) {
      return idx === -1 ? list : list.filter(x => x.id !== change.id);
    }
    const incomingUpdatedAt = change.updatedAt || 0;
    if (idx === -1) return [...list, { ...change.data, updatedAt: incomingUpdatedAt }];
    const existingUpdatedAt = list[idx].updatedAt || list[idx].created || 0;
    if (incomingUpdatedAt <= existingUpdatedAt) return list; // local already current
    const copy = list.slice();
    copy[idx] = { ...list[idx], ...change.data, updatedAt: incomingUpdatedAt };
    return copy;
  }

  /* Dirty-set bookkeeping: which (kind,id) pairs need pushing. Plain data
     structure so it's trivially testable; the runtime below wires it to
     actual mutations via a Proxy-free "markDirty" call at write sites. */
  function makeDirtyTracker() {
    const set = new Map(); // "kind:id" -> {kind, id, deleted}
    return {
      mark(kind, id, deleted) { set.set(kind + ":" + id, { kind, id, deleted: !!deleted }); },
      drain() { const out = [...set.values()]; set.clear(); return out; },
      get size() { return set.size; }
    };
  }

  g.AOSSync = {
    SONG_FIELDS, ASSET_FIELDS, EVENT_FIELDS,
    toChange, applyRemoteChange, makeDirtyTracker, pick
  };
})(typeof window !== "undefined" ? window : globalThis);
