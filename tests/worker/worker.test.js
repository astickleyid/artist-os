const assert = require('assert');
const path = require('path');
const { makeD1, makeR2 } = require('./adapters');

async function main() {
  const worker = (await import('../src/index.js')).default;
  const schemaPath = path.join(__dirname, '..', 'schema.sql');

  function newEnv() {
    return { DB: makeD1(schemaPath), AUDIO: makeR2(), ALLOWED_ORIGINS: 'https://astickleyid.github.io' };
  }
  function req(env, method, pathname, { body, token, headers, origin } = {}) {
    const h = new Headers(headers || {});
    if (token) h.set('authorization', 'Bearer ' + token);
    if (body !== undefined) h.set('content-type', 'application/json');
    h.set('origin', origin || 'https://astickleyid.github.io');
    return worker.fetch(new Request('https://sync.example/' + pathname.replace(/^\//, ''), {
      method, headers: h, body: body !== undefined ? JSON.stringify(body) : undefined
    }), env);
  }

  let n = 0, failed = 0;
  async function test(name, fn) {
    n++;
    try { await fn(); console.log('  ✓ ' + name); }
    catch (e) { failed++; console.log('  ✗ ' + name + '\n    ' + e.message); }
  }

  // ---------- health + CORS ----------
  await test('health check responds ok', async () => {
    const res = await req(newEnv(), 'GET', '/v1/health');
    assert.equal(res.status, 200);
    assert.equal((await res.json()).ok, true);
  });
  await test('CORS echoes allowed origin', async () => {
    const res = await req(newEnv(), 'GET', '/v1/health', { origin: 'https://astickleyid.github.io' });
    assert.equal(res.headers.get('access-control-allow-origin'), 'https://astickleyid.github.io');
  });
  await test('CORS falls back to default for disallowed origin', async () => {
    const res = await req(newEnv(), 'GET', '/v1/health', { origin: 'https://evil.example' });
    assert.equal(res.headers.get('access-control-allow-origin'), 'https://astickleyid.github.io');
  });
  await test('OPTIONS preflight returns 204', async () => {
    const env = newEnv();
    const res = await worker.fetch(new Request('https://sync.example/v1/sync/push', {
      method: 'OPTIONS', headers: { origin: 'https://astickleyid.github.io' }
    }), env);
    assert.equal(res.status, 204);
  });

  // ---------- auth ----------
  await test('account creation issues accountId + working token', async () => {
    const env = newEnv();
    const res = await req(env, 'POST', '/v1/account');
    assert.equal(res.status, 201);
    const body = await res.json();
    assert(body.accountId && body.token, 'has accountId and token');
    assert.equal(body.token.length, 64, 'token is 32 raw bytes hex-encoded');
  });
  await test('protected route rejects missing auth', async () => {
    const res = await req(newEnv(), 'GET', '/v1/sync/pull');
    assert.equal(res.status, 401);
  });
  await test('protected route rejects garbage token', async () => {
    const res = await req(newEnv(), 'GET', '/v1/sync/pull', { token: 'not-a-real-token' });
    assert.equal(res.status, 401);
  });
  await test('protected route rejects well-formed but unknown token', async () => {
    const res = await req(newEnv(), 'GET', '/v1/sync/pull', { token: 'a'.repeat(64) });
    assert.equal(res.status, 401);
  });
  await test('tokens are stored hashed, not raw', async () => {
    const env = newEnv();
    const { token } = await (await req(env, 'POST', '/v1/account')).json();
    const row = await env.DB.prepare('SELECT hash FROM tokens').bind().first();
    assert.notEqual(row.hash, token, 'raw token must never be stored');
    assert.equal(row.hash.length, 64, 'sha256 hex');
  });

  // ---------- push/pull sync ----------
  async function account(env) { return (await req(env, 'POST', '/v1/account')).json(); }

  await test('push then pull round-trips a song', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const change = { kind: 'song', id: 'song1', updatedAt: 1000, data: { title: 'Night Drive' } };
    const push = await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [change] } });
    assert.equal(push.status, 200);
    const pushBody = await push.json();
    assert.equal(pushBody.applied, 1);
    assert.equal(pushBody.skipped, 0);

    const pull = await req(env, 'GET', '/v1/sync/pull?since=0', { token });
    const pullBody = await pull.json();
    assert.equal(pullBody.changes.length, 1);
    assert.equal(pullBody.changes[0].data.title, 'Night Drive');
  });

  await test('pull with since= only returns newer entries', async () => {
    const env = newEnv();
    const { token } = await account(env);
    await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 1, data: { title: 'A' } }
    ] } });
    const midSeq = (await (await req(env, 'GET', '/v1/sync/pull?since=0', { token })).json()).seq;
    await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's2', updatedAt: 2, data: { title: 'B' } }
    ] } });
    const pull = await (await req(env, 'GET', '/v1/sync/pull?since=' + midSeq, { token })).json();
    assert.equal(pull.changes.length, 1);
    assert.equal(pull.changes[0].id, 's2');
  });

  await test('last-write-wins: older update does not overwrite newer', async () => {
    const env = newEnv();
    const { token } = await account(env);
    await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 100, data: { title: 'Latest' } }
    ] } });
    const stale = await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 50, data: { title: 'Stale' } }
    ] } });
    const staleBody = await stale.json();
    assert.equal(staleBody.applied, 0);
    assert.equal(staleBody.skipped, 1);
    const pull = await (await req(env, 'GET', '/v1/sync/pull?since=0', { token })).json();
    assert.equal(pull.changes.find(c => c.id === 's1').data.title, 'Latest');
  });

  await test('newer update overwrites older', async () => {
    const env = newEnv();
    const { token } = await account(env);
    await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 1, data: { title: 'v1' } }
    ] } });
    await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 2, data: { title: 'v2' } }
    ] } });
    const pull = await (await req(env, 'GET', '/v1/sync/pull?since=0', { token })).json();
    assert.equal(pull.changes.length, 1);
    assert.equal(pull.changes[0].data.title, 'v2');
  });

  await test('deletion propagates as a tombstone', async () => {
    const env = newEnv();
    const { token } = await account(env);
    await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 1, data: { title: 'A' } }
    ] } });
    await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 2, deleted: true }
    ] } });
    const pull = await (await req(env, 'GET', '/v1/sync/pull?since=0', { token })).json();
    assert.equal(pull.changes[0].deleted, true);
    assert.equal(pull.changes[0].data, null);
  });

  await test('malformed changes are skipped without failing the batch', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const res = await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 'ok', updatedAt: 1, data: {} },
      { kind: 'not-a-kind', id: 'bad', updatedAt: 1, data: {} },
      { kind: 'song', id: 123, updatedAt: 1, data: {} }, // non-string id
      {}
    ] } });
    const body = await res.json();
    assert.equal(body.applied, 1);
    assert.equal(body.skipped, 3);
  });

  await test('oversized data payload rejected', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const res = await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 1, data: { blob: 'x'.repeat(250_000) } }
    ] } });
    const body = await res.json();
    assert.equal(body.applied, 0);
    assert.equal(body.skipped, 1);
  });

  await test('batch over the max size is rejected with 413', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const changes = Array.from({ length: 501 }, (_, i) => ({ kind: 'event', id: 'e' + i, updatedAt: i, data: {} }));
    const res = await req(env, 'POST', '/v1/sync/push', { token, body: { changes } });
    assert.equal(res.status, 413);
  });

  await test('accounts are fully isolated from each other', async () => {
    const env = newEnv();
    const a = await account(env), b = await account(env);
    await req(env, 'POST', '/v1/sync/push', { token: a.token, body: { changes: [
      { kind: 'song', id: 'private-to-a', updatedAt: 1, data: { title: 'secret' } }
    ] } });
    const pullAsB = await (await req(env, 'GET', '/v1/sync/pull?since=0', { token: b.token })).json();
    assert.equal(pullAsB.changes.length, 0, 'account B must not see account A data');
  });

  // ---------- device linking ----------
  await test('link start + claim issues a working second-device token', async () => {
    const env = newEnv();
    const { token, accountId } = await account(env);
    const start = await (await req(env, 'POST', '/v1/link/start', { token })).json();
    assert.match(start.code, /^[A-Z2-9]{6}$/);
    const claim = await req(env, 'POST', '/v1/link/claim', { body: { code: start.code } });
    assert.equal(claim.status, 200);
    const claimBody = await claim.json();
    assert.equal(claimBody.accountId, accountId);
    // new token actually works
    const pull = await req(env, 'GET', '/v1/sync/pull?since=0', { token: claimBody.token });
    assert.equal(pull.status, 200);
  });
  await test('link code is single-use', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const { code } = await (await req(env, 'POST', '/v1/link/start', { token })).json();
    await req(env, 'POST', '/v1/link/claim', { body: { code } });
    const second = await req(env, 'POST', '/v1/link/claim', { body: { code } });
    assert.equal(second.status, 404);
  });
  await test('malformed link code rejected before a DB lookup', async () => {
    const res = await req(newEnv(), 'POST', '/v1/link/claim', { body: { code: 'nope!!' } });
    assert.equal(res.status, 400);
  });
  await test('unknown link code rejected', async () => {
    const res = await req(newEnv(), 'POST', '/v1/link/claim', { body: { code: 'ZZZZZZ' } });
    assert.equal(res.status, 404);
  });

  // ---------- blob storage ----------
  await test('blob upload + download round-trips bytes and content-type', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const bytes = Buffer.from('fake audio bytes for testing');
    const put = await worker.fetch(new Request('https://sync.example/v1/blob/asset123', {
      method: 'PUT',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'audio/wav', 'content-length': String(bytes.length) },
      body: bytes
    }), env);
    assert.equal(put.status, 200);
    const get = await req(env, 'GET', '/v1/blob/asset123', { token });
    assert.equal(get.status, 200);
    assert.equal(get.headers.get('content-type'), 'audio/wav');
    const downloaded = Buffer.from(await get.arrayBuffer());
    assert.equal(downloaded.toString(), bytes.toString());
  });
  await test('blob rejects asset id over the length cap', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const longId = 'a'.repeat(100); // alnum, so it matches the router but fails the {1,64} cap
    const res = await worker.fetch(new Request(`https://sync.example/v1/blob/${longId}`, {
      method: 'PUT', headers: { authorization: 'Bearer ' + token, 'content-length': '4' }, body: 'data'
    }), env);
    assert.equal(res.status, 400);
  });
  await test('path traversal in blob id is neutralized by URL normalization (404, not a leak)', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const res = await worker.fetch(new Request('https://sync.example/v1/blob/../etc-passwd', {
      method: 'PUT', headers: { authorization: 'Bearer ' + token, 'content-length': '4' }, body: 'data'
    }), env);
    assert.equal(res.status, 404);
  });
  await test('blob rejects missing content-length', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const res = await worker.fetch(new Request('https://sync.example/v1/blob/asset1', {
      method: 'PUT', headers: { authorization: 'Bearer ' + token }, body: 'data'
    }), env);
    assert.equal(res.status, 413);
  });
  await test('blob rejects oversized content-length', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const res = await worker.fetch(new Request('https://sync.example/v1/blob/asset1', {
      method: 'PUT',
      headers: { authorization: 'Bearer ' + token, 'content-length': String(200 * 1024 * 1024) },
      body: 'data'
    }), env);
    assert.equal(res.status, 413);
  });
  await test('blob download 404s when not found', async () => {
    const env = newEnv();
    const { token } = await account(env);
    const res = await req(env, 'GET', '/v1/blob/doesnotexist', { token });
    assert.equal(res.status, 404);
  });
  await test('a second account cannot read the first account\'s blob', async () => {
    const env = newEnv();
    const a = await account(env), b = await account(env);
    await worker.fetch(new Request('https://sync.example/v1/blob/shared', {
      method: 'PUT', headers: { authorization: 'Bearer ' + a.token, 'content-length': '4' }, body: 'data'
    }), env);
    const res = await req(env, 'GET', '/v1/blob/shared', { token: b.token });
    assert.equal(res.status, 404, 'blobs are namespaced per account, not just per asset id');
  });

  // ---------- account deletion ----------
  await test('account deletion revokes tokens and wipes entities + blobs', async () => {
    const env = newEnv();
    const { token } = await account(env);
    await req(env, 'POST', '/v1/sync/push', { token, body: { changes: [
      { kind: 'song', id: 's1', updatedAt: 1, data: {} }
    ] } });
    await worker.fetch(new Request('https://sync.example/v1/blob/a1', {
      method: 'PUT', headers: { authorization: 'Bearer ' + token, 'content-length': '4' }, body: 'data'
    }), env);
    const del = await req(env, 'DELETE', '/v1/account', { token });
    assert.equal(del.status, 200);
    const after = await req(env, 'GET', '/v1/sync/pull?since=0', { token });
    assert.equal(after.status, 401, 'token must be revoked after account deletion');
    assert.equal(env.AUDIO._store.size, 0, 'blobs removed from storage');
  });

  console.log(`\n${n - failed}/${n} worker tests passed`);
  if (failed) process.exit(1);
}

main().catch(e => { console.error('FATAL:', e); process.exit(1); });
