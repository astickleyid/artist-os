/* Artist OS Sync Worker — metadata-first sync + selective audio blobs.
   Zero dependencies. Tokens stored SHA-256 hashed. Device-link pairing. */

const KINDS = new Set(["song", "asset", "event"]);
const MAX_BATCH = 500;
const MAX_DATA_BYTES = 200_000;
const MAX_BLOB_BYTES = 150 * 1024 * 1024;
const LINK_TTL_MS = 5 * 60 * 1000;
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I

/* ---------- helpers ---------- */
const json = (data, status = 200, extra = {}) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", ...extra }
  });

const err = (status, message) => json({ error: message }, status);

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("");
}

function randomToken(bytes = 32) {
  const raw = crypto.getRandomValues(new Uint8Array(bytes));
  return [...raw].map(b => b.toString(16).padStart(2, "0")).join("");
}

function randomCode(length = 6) {
  const raw = crypto.getRandomValues(new Uint8Array(length));
  return [...raw].map(b => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

function corsHeaders(env, origin) {
  const allowed = (env.ALLOWED_ORIGINS || "https://astickleyid.github.io")
    .split(",").map(s => s.trim()).filter(Boolean);
  const ok = origin && (allowed.includes(origin) || allowed.includes("*"));
  return {
    "access-control-allow-origin": ok ? origin : allowed[0],
    "access-control-allow-methods": "GET,POST,PUT,DELETE,OPTIONS",
    "access-control-allow-headers": "authorization,content-type",
    "access-control-max-age": "86400",
    "vary": "origin"
  };
}

async function authenticate(request, env) {
  const header = request.headers.get("authorization") || "";
  const match = header.match(/^Bearer\s+([a-f0-9]{64})$/i);
  if (!match) return null;
  const hash = await sha256Hex(match[1]);
  const row = await env.DB.prepare("SELECT account_id FROM tokens WHERE hash = ?")
    .bind(hash).first();
  return row ? row.account_id : null;
}

async function nextSeq(env, accountId, count) {
  await env.DB.prepare(
    "INSERT INTO seq_counter (account_id, seq) VALUES (?, 0) ON CONFLICT(account_id) DO NOTHING"
  ).bind(accountId).run();
  await env.DB.prepare("UPDATE seq_counter SET seq = seq + ? WHERE account_id = ?")
    .bind(count, accountId).run();
  const row = await env.DB.prepare("SELECT seq FROM seq_counter WHERE account_id = ?")
    .bind(accountId).first();
  return row.seq - count; // base; caller assigns base+1..base+count
}

async function issueToken(env, accountId, label) {
  const token = randomToken();
  await env.DB.prepare(
    "INSERT INTO tokens (hash, account_id, created_at, label) VALUES (?, ?, ?, ?)"
  ).bind(await sha256Hex(token), accountId, Date.now(), label || "device").run();
  return token;
}

/* ---------- handlers ---------- */
async function createAccount(env) {
  const accountId = randomToken(8);
  await env.DB.prepare("INSERT INTO accounts (id, created_at) VALUES (?, ?)")
    .bind(accountId, Date.now()).run();
  const token = await issueToken(env, accountId, "first device");
  return json({ accountId, token }, 201);
}

async function linkStart(env, accountId) {
  const code = randomCode();
  await env.DB.prepare(
    "INSERT INTO link_codes (code, account_id, expires_at, used) VALUES (?, ?, ?, 0)"
  ).bind(code, accountId, Date.now() + LINK_TTL_MS).run();
  return json({ code, expiresInSeconds: LINK_TTL_MS / 1000 });
}

async function linkClaim(env, request) {
  let body;
  try { body = await request.json(); } catch { return err(400, "invalid json"); }
  const code = String(body.code || "").toUpperCase().trim();
  if (!/^[A-Z2-9]{6}$/.test(code)) return err(400, "invalid code format");
  const row = await env.DB.prepare(
    "SELECT account_id, expires_at, used FROM link_codes WHERE code = ?"
  ).bind(code).first();
  if (!row || row.used || row.expires_at < Date.now()) return err(404, "code not found or expired");
  await env.DB.prepare("UPDATE link_codes SET used = 1 WHERE code = ?").bind(code).run();
  const token = await issueToken(env, row.account_id, "linked device");
  return json({ accountId: row.account_id, token });
}

async function syncPush(env, accountId, request) {
  let body;
  try { body = await request.json(); } catch { return err(400, "invalid json"); }
  const changes = Array.isArray(body.changes) ? body.changes : null;
  if (!changes) return err(400, "changes array required");
  if (changes.length > MAX_BATCH) return err(413, `max ${MAX_BATCH} changes per push`);

  let applied = 0, skipped = 0;
  const valid = [];
  for (const c of changes) {
    if (!c || !KINDS.has(c.kind) || typeof c.id !== "string" || c.id.length > 64) { skipped++; continue; }
    const updatedAt = Number(c.updatedAt) || 0;
    const data = c.deleted ? "" : JSON.stringify(c.data ?? {});
    if (data.length > MAX_DATA_BYTES) { skipped++; continue; }
    valid.push({ kind: c.kind, id: c.id, updatedAt, deleted: c.deleted ? 1 : 0, data });
  }

  if (valid.length) {
    const base = await nextSeq(env, accountId, valid.length);
    let offset = 1;
    for (const c of valid) {
      const existing = await env.DB.prepare(
        "SELECT updated_at FROM entities WHERE account_id = ? AND kind = ? AND id = ?"
      ).bind(accountId, c.kind, c.id).first();
      if (existing && existing.updated_at >= c.updatedAt) { skipped++; continue; } // LWW
      await env.DB.prepare(`
        INSERT INTO entities (account_id, kind, id, updated_at, deleted, data, seq)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_id, kind, id)
        DO UPDATE SET updated_at = excluded.updated_at, deleted = excluded.deleted,
                      data = excluded.data, seq = excluded.seq
      `).bind(accountId, c.kind, c.id, c.updatedAt, c.deleted, c.data, base + offset).run();
      applied++; offset++;
    }
  }
  const row = await env.DB.prepare("SELECT seq FROM seq_counter WHERE account_id = ?")
    .bind(accountId).first();
  return json({ applied, skipped, seq: row ? row.seq : 0 });
}

async function syncPull(env, accountId, url) {
  const since = Number(url.searchParams.get("since")) || 0;
  const rows = await env.DB.prepare(`
    SELECT kind, id, updated_at, deleted, data, seq FROM entities
    WHERE account_id = ? AND seq > ? ORDER BY seq ASC LIMIT 1000
  `).bind(accountId, since).all();
  const results = rows.results || [];
  const changes = results.map(r => ({
    kind: r.kind, id: r.id, updatedAt: r.updated_at,
    deleted: !!r.deleted, data: r.deleted ? null : JSON.parse(r.data || "{}")
  }));
  const seq = results.length ? results[results.length - 1].seq : since;
  return json({ changes, seq, hasMore: results.length === 1000 });
}

async function blobPut(env, accountId, assetId, request) {
  if (!/^[a-z0-9]{1,64}$/i.test(assetId)) return err(400, "bad asset id");
  const length = Number(request.headers.get("content-length")) || 0;
  if (!length || length > MAX_BLOB_BYTES) return err(413, "blob too large or length missing");
  const key = `${accountId}/${assetId}`;
  await env.AUDIO.put(key, request.body, {
    httpMetadata: { contentType: request.headers.get("content-type") || "application/octet-stream" }
  });
  await env.DB.prepare(`
    INSERT INTO blobs (account_id, asset_id, size, content_type, created_at) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(account_id, asset_id) DO UPDATE SET size = excluded.size,
      content_type = excluded.content_type, created_at = excluded.created_at
  `).bind(accountId, assetId, length, request.headers.get("content-type") || "", Date.now()).run();
  return json({ ok: true, size: length });
}

async function blobGet(env, accountId, assetId) {
  const object = await env.AUDIO.get(`${accountId}/${assetId}`);
  if (!object) return err(404, "blob not found");
  return new Response(object.body, {
    headers: {
      "content-type": object.httpMetadata?.contentType || "application/octet-stream",
      "cache-control": "private, max-age=3600"
    }
  });
}

async function deleteAccount(env, accountId) {
  const blobs = await env.DB.prepare("SELECT asset_id FROM blobs WHERE account_id = ?")
    .bind(accountId).all();
  for (const b of blobs.results || []) {
    await env.AUDIO.delete(`${accountId}/${b.asset_id}`);
  }
  for (const table of ["entities", "blobs", "tokens", "link_codes", "seq_counter", "accounts"]) {
    const col = table === "accounts" ? "id" : "account_id";
    await env.DB.prepare(`DELETE FROM ${table} WHERE ${col} = ?`).bind(accountId).run();
  }
  return json({ ok: true });
}

/* ---------- router ---------- */
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const cors = corsHeaders(env, request.headers.get("origin"));
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

    const wrap = async () => {
      const path = url.pathname.replace(/\/+$/, "");
      if (path === "/v1/health") return json({ ok: true, service: "artist-os-sync" });
      if (path === "/v1/account" && request.method === "POST") return createAccount(env);
      if (path === "/v1/link/claim" && request.method === "POST") return linkClaim(env, request);

      const accountId = await authenticate(request, env);
      if (!accountId) return err(401, "unauthorized");

      if (path === "/v1/link/start" && request.method === "POST") return linkStart(env, accountId);
      if (path === "/v1/sync/push" && request.method === "POST") return syncPush(env, accountId, request);
      if (path === "/v1/sync/pull" && request.method === "GET") return syncPull(env, accountId, url);
      if (path === "/v1/account" && request.method === "DELETE") return deleteAccount(env, accountId);

      const blob = path.match(/^\/v1\/blob\/([a-z0-9]+)$/i);
      if (blob && request.method === "PUT") return blobPut(env, accountId, blob[1], request);
      if (blob && request.method === "GET") return blobGet(env, accountId, blob[1]);

      return err(404, "not found");
    };

    const response = await wrap().catch(e => err(500, "internal error: " + e.message));
    for (const [k, v] of Object.entries(cors)) response.headers.set(k, v);
    return response;
  }
};
