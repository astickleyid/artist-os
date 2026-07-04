/* Thin adapters that expose D1's prepare().bind().first()/.all()/.run() shape
   and R2's put/get/delete shape, backed by real SQLite + an in-memory Map.
   This lets us exercise worker/src/index.js verbatim — no logic is re-implemented here. */
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const path = require('path');

function makeD1(schemaPath) {
  const db = new DatabaseSync(':memory:');
  db.exec(fs.readFileSync(schemaPath, 'utf8'));

  function run(sql, params) {
    const stmt = db.prepare(sql);
    return { stmt, params: params || [] };
  }

  return {
    prepare(sql) {
      let bound = [];
      const api = {
        bind(...args) { bound = args; return api; },
        async first() {
          const stmt = db.prepare(sql);
          const row = stmt.get(...bound);
          return row === undefined ? null : row;
        },
        async all() {
          const stmt = db.prepare(sql);
          const rows = stmt.all(...bound);
          return { results: rows };
        },
        async run() {
          const stmt = db.prepare(sql);
          const info = stmt.run(...bound);
          return { success: true, meta: { changes: info.changes, last_row_id: info.lastInsertRowid } };
        }
      };
      return api;
    },
    _raw: db
  };
}

function makeR2() {
  const store = new Map();
  return {
    async put(key, body, opts) {
      let chunks = [];
      if (body && typeof body.getReader === 'function') {
        const reader = body.getReader();
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          chunks.push(value);
        }
      } else if (Buffer.isBuffer(body) || body instanceof Uint8Array) {
        chunks = [body];
      } else if (typeof body === 'string') {
        chunks = [Buffer.from(body)];
      }
      const data = Buffer.concat(chunks.map(c => Buffer.from(c)));
      store.set(key, { data, httpMetadata: opts && opts.httpMetadata });
      return { key };
    },
    async get(key) {
      const entry = store.get(key);
      if (!entry) return null;
      return {
        body: new ReadableStream({
          start(controller) { controller.enqueue(entry.data); controller.close(); }
        }),
        httpMetadata: entry.httpMetadata
      };
    },
    async delete(key) { store.delete(key); },
    _store: store
  };
}

module.exports = { makeD1, makeR2 };
