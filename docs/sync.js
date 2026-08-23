/* Artist OS — Cloudflare sync client.
   Contract: metadata-first canonical creative state + selective audio blobs.
   See Docs/VISION.md + worker/src/index.js. Pure helpers (exported as AOSSync
   for Node testing) are separated from the network/IndexedDB runtime below. */
(function (g) {
  "use strict";

  /* ---------- pure: entity <-> wire encoding ---------- */

  // Only fields that matter for cross-device state; excludes local-only runtime
  // fields (blob handles, decoded peaks, bookmarks, etc). Current section source
  // and master pointers are intentionally excluded from Song changes because
  // Master Composition owns that truth and syncs independently.
  const SONG_FIELDS = ["id", "title", "era", "status", "progress", "qualityScore",
    "risk", "sections", "created", "updatedAt"];
  const ASSET_FIELDS = ["id", "songId", "title", "file", "role", "created", "updatedAt",
    "type", "modifiedAt", "sourcePath", "version", "vOrder", "dur", "hash", "size",
    "bpm", "keyName", "analysisConf", "analyzedAt", "cloudKey"];
  const EVENT_FIELDS = ["id", "songId", "target", "op", "beforeAssetId", "afterAssetId",
    "summary", "t", "observed", "confidence"];
  const DECISION_FIELDS = ["id", "songId", "target", "action", "selectedAssetId",
    "rejectedAssetIds", "relatedEventIds", "reason", "source", "updatedAt"];
  const MASTER_COMPOSITION_FIELDS = ["id", "songId", "sections", "outputAssetId", "updatedAt"];

  const FIELDS_BY_KIND = {
    song: SONG_FIELDS,
    asset: ASSET_FIELDS,
    event: EVENT_FIELDS,
    decision: DECISION_FIELDS,
    masterComposition: MASTER_COMPOSITION_FIELDS
  };

  function pick(obj, fields) {
    const out = {};
    for (const f of fields) if (obj[f] !== undefined) out[f] = obj[f];
    return out;
  }

  function songDataForSync(entity) {
    const data = pick(entity, SONG_FIELDS);
    if (Array.isArray(data.sections)) {
      data.sections = data.sections.map(section => {
        const copy = { ...section };
        delete copy.assetId;
        delete copy.assetID;
        return copy;
      });
    }
    return data;
  }

  function toChange(kind, entity, deleted) {
    const updatedAt = entity.updatedAt || entity.created || entity.t || 0;
    if (deleted) return { kind, id: entity.id, updatedAt: Date.now(), deleted: true };
    const fields = FIELDS_BY_KIND[kind];
    if (!fields) throw new Error("Unsupported sync kind: " + kind);
    const data = kind === "song" ? songDataForSync(entity) : pick(entity, fields);
    return { kind, id: entity.id, updatedAt, data };
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

  function makeDirtyTracker() {
    const set = new Map(); // "kind:id" -> {kind, id, deleted}
    return {
      mark(kind, id, deleted) { set.set(kind + ":" + id, { kind, id, deleted: !!deleted }); },
      drain() { const out = [...set.values()]; set.clear(); return out; },
      get size() { return set.size; }
    };
  }

  g.AOSSync = {
    SONG_FIELDS, ASSET_FIELDS, EVENT_FIELDS, DECISION_FIELDS, MASTER_COMPOSITION_FIELDS,
    FIELDS_BY_KIND, toChange, applyRemoteChange, makeDirtyTracker, pick, songDataForSync
  };
})(typeof window !== "undefined" ? window : globalThis);