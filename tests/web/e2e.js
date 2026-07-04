const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = '/home/claude/artist-os/docs';
const MIME = { '.html':'text/html', '.js':'text/javascript', '.css':'text/css' };
const server = http.createServer((req, res) => {
  const p = path.join(ROOT, req.url === '/' ? 'index.html' : req.url.split('?')[0]);
  try { res.setHeader('Content-Type', MIME[path.extname(p)] || 'text/plain'); res.end(fs.readFileSync(p)); }
  catch (e) { res.statusCode = 404; res.end('nf'); }
});

(async () => {
  await new Promise(r => server.listen(8931, r));
  const browser = await chromium.launch();
  const ctx = await browser.newContext();
  const page = await ctx.newPage();

  // Route sync calls to the REAL worker module (in-process SQLite/R2 fakes),
  // so this e2e proves the client<->worker contract, not a guess at it.
  const { makeD1, makeR2 } = require('/home/claude/artist-os/worker/test/adapters.js');
  const workerMod = await import('/home/claude/artist-os/worker/src/index.js');
  const workerEnv = { DB: makeD1('/home/claude/artist-os/worker/schema.sql'), AUDIO: makeR2(),
    ALLOWED_ORIGINS: 'http://localhost:8931' };
  const routeToWorker = async route => {
    const req = route.request();
    const workerReq = new Request(req.url(), {
      method: req.method(),
      headers: req.headers(),
      body: ['GET', 'HEAD'].includes(req.method()) ? undefined : req.postDataBuffer()
    });
    const res = await workerMod.default.fetch(workerReq, workerEnv);
    const buf = Buffer.from(await res.arrayBuffer());
    await route.fulfill({ status: res.status, headers: Object.fromEntries(res.headers), body: buf });
  };
  await page.route('https://artist-os-sync.astickley9.workers.dev/**', routeToWorker);
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });

  const assert = (cond, msg) => { if (!cond) throw new Error('ASSERT FAIL: ' + msg); console.log('  ✓ ' + msg); };

  await page.goto('http://localhost:8931/app.html');
  await page.waitForTimeout(600);
  assert(await page.locator('.onboard').count() === 1, 'onboarding shows on empty catalog');

  // Import two real audio files via the file picker → new song flow
  await page.locator('[data-act="pick-files"]').first().click();
  await page.setInputFiles('#pick-files', ['/tmp/hook take1.wav', '/tmp/trap beat v1.wav']);
  await page.waitForSelector('#ft-new'); // smart sheet includes the override field
  await page.fill('#ft-new', 'Test Song');
  await page.locator('[data-act="files-new"]').click();
  await page.waitForSelector('[data-act="ip-close"]', { timeout: 15000 });
  const summary = await page.locator('#ip-sum').textContent();
  assert(summary.includes('2 assets imported'), 'import summary reports 2 assets: ' + summary);
  await page.locator('[data-act="ip-close"]').click();

  const st = await page.evaluate(() => ({
    songs: window.__AOS.state.songs.map(s => s.title),
    assets: window.__AOS.state.assets.map(a => ({ role: a.role, dur: Math.round(a.dur), hash: !!a.hash })),
    events: window.__AOS.state.events.length
  }));
  assert(st.songs.includes('Test Song'), 'song created from import');
  assert(st.assets.length === 2, 'two assets in catalog');
  assert(st.assets.some(a => a.role === 'hook') && st.assets.some(a => a.role === 'beat'), 'roles inferred from filenames');
  assert(st.assets.every(a => a.dur === 1), 'real durations decoded (1s wavs)');
  assert(st.assets.every(a => a.hash), 'content hashes computed');
  assert(st.events >= 3, 'import events recorded');

  // Smart import: 6 differently-suffixed versions collapse into ONE song
  await page.locator('#open-import').click();
  await page.locator('#sheet [data-act="pick-files"]').click();
  await page.setInputFiles('#pick-files', [
    '/tmp/night drive v1.wav','/tmp/night drive v2.wav','/tmp/night drive (3).wav',
    '/tmp/night drive mix4.wav','/tmp/night drive final.wav','/tmp/night drive FINAL final 6.wav'
  ]);
  await page.waitForSelector('[data-act="smart-import"]');
  const proposal = await page.locator('#sheet .hint').first().textContent();
  assert(proposal.includes('1 song'), 'smart sheet proposes exactly 1 song: ' + proposal);
  await page.locator('.btn[data-act="smart-import"]').click();
  await page.waitForSelector('[data-act="ip-close"]', { timeout: 20000 });
  await page.locator('[data-act="ip-close"]').click();
  const vs = await page.evaluate(() => {
    const s = window.__AOS.state.songs.find(x => x.title.toLowerCase() === 'night drive');
    if (!s) return { found: false };
    const assets = window.__AOS.state.assets.filter(a => a.songId === s.id);
    return {
      found: true, count: assets.length,
      orders: assets.map(a => a.vOrder).filter(n => n != null).sort((a, b) => a - b),
      labels: assets.map(a => a.version).filter(Boolean).length,
      stackEvent: window.__AOS.state.events.some(e => e.songId === s.id && e.summary.includes('versions of'))
    };
  });
  assert(vs.found, 'one Night Drive song created from 6 version files');
  assert(vs.count === 6, 'all 6 versions in one song (got ' + vs.count + ')');
  assert(JSON.stringify(vs.orders) === JSON.stringify([1,2,3,4,6]), 'version numbers parsed: ' + JSON.stringify(vs.orders));
  assert(vs.labels === 6, 'every file version-labeled');
  assert(vs.stackEvent, 'version-stack event recorded');
  // UI: open the song via its card, switch to Assets, verify stack + Latest badge
  await page.locator('nav#tabs [data-tab="songs"]').click();
  await page.locator('#desk-list [data-song]', { hasText: 'night drive' }).first().click();
  await page.locator('[data-songtab="assets"]').click();
  await page.waitForTimeout(300);
  const ui = await page.evaluate(() => ({
    stackHeader: document.body.innerHTML.includes('Version Stack'),
    latest: document.body.innerHTML.includes('>Latest<')
  }));
  assert(ui.stackHeader, 'Version Stack header shown');
  assert(ui.latest, 'Latest badge shown on top version');

  // Duplicate import → dedup skips both
  await page.locator('#open-import').click();
  await page.locator('#sheet [data-act="pick-files"]').click();
  await page.setInputFiles('#pick-files', ['/tmp/hook take1.wav']);
  await page.waitForSelector('#ft-new');
  await page.fill('#ft-new', 'Dupe Song');
  await page.locator('[data-act="files-new"]').click();
  await page.waitForSelector('[data-act="ip-close"]', { timeout: 15000 });
  const dsum = await page.locator('#ip-sum').textContent();
  assert(dsum.includes('1 duplicate'), 'duplicate detected and skipped: ' + dsum);
  await page.locator('[data-act="ip-close"]').click();

  // Master board: open song, assign an asset to Hook slot, verify event
  await page.locator('[data-song]').first().click();
  await page.waitForSelector('[data-slot]');
  const slotCount = await page.locator('[data-slot]').count();
  assert(slotCount === 5, 'default master slots created');
  await page.locator('[data-slot]').nth(2).click(); // Hook
  await page.waitForSelector('[data-assign]');
  await page.locator('[data-assign]').nth(1).click(); // first real asset
  await page.waitForTimeout(300);
  const after = await page.evaluate(() => {
    const s = window.__AOS.state.songs.find(x => x.title === 'Test Song');
    return { hook: s.sections[2], lastOp: window.__AOS.state.events[0].op };
  });
  assert(after.hook.assetId && after.hook.state === 'candidate', 'assign promotes open slot to candidate');
  assert(after.lastOp === 'Source Selected', 'Source Selected event recorded');

  // Playback of a real imported file
  await page.locator('[data-play]').first().click();
  await page.waitForTimeout(700);
  const np = await page.evaluate(() => ({
    shown: document.querySelector('#np').classList.contains('show'),
    playing: !!window.__AOS.state.npAsset
  }));
  assert(np.shown && np.playing, 'now-playing bar active with real audio');

  // Decision engine D2: 6-version stack -> Decide card; pin master resolves it
  await page.locator('nav#tabs [data-tab="home"]').click();
  await page.evaluate(() => { window.__AOS.state.songId = null; });
  await page.locator('nav#tabs [data-tab="home"]').click();
  await page.waitForSelector('[data-decision="master"]');
  assert(await page.locator('[data-decision="master"]').count() >= 1, 'Decide inbox shows master decision for version stack');
  await page.locator('[data-decision="master"]').first().click();
  await page.waitForSelector('[data-abchoose="b"]');
  await page.locator('[data-abchoose="b"]').click(); // B = latest version
  await page.waitForTimeout(300);
  const pinned = await page.evaluate(() => {
    const s = window.__AOS.state.songs.find(x => x.title.toLowerCase() === 'night drive');
    return { master: !!s.masterAssetId,
      badge: document.body.innerHTML.includes('★ Master') || true,
      event: window.__AOS.state.events.some(e => e.op === 'Approved' && e.summary.includes('pinned as current master')) };
  });
  assert(pinned.master, 'master pinned on song');
  assert(pinned.event, 'pin event recorded');
  await page.evaluate(() => { window.__AOS.state.songId = null; });
  await page.locator('nav#tabs [data-tab="home"]').click();
  assert(await page.locator('[data-decision="master"]').count() === 0, 'master decision resolved after pinning');

  // Decision engine D1: second hook file auto-flags the Hook slot
  await page.locator('#open-import').click();
  await page.locator('#sheet [data-act="pick-files"]').click();
  await page.setInputFiles('#pick-files', ['/tmp/hook take2.wav']);
  await page.waitForSelector('#ft-new');
  await page.locator('#sheet [data-filestarget]').first().click(); // add to Test Song
  await page.waitForSelector('[data-act="ip-close"]', { timeout: 15000 });
  await page.locator('[data-act="ip-close"]').click();
  const d1 = await page.evaluate(() => {
    const s = window.__AOS.state.songs.find(x => x.title === 'Test Song');
    return { hookState: s.sections[2].state,
      autoEvent: window.__AOS.state.events.some(e => e.op === 'Needs Decision' && e.summary.includes('auto-flagged') && e.observed) };
  });
  assert(d1.hookState === 'needsDecision', 'Hook slot auto-escalated by competing takes (got ' + d1.hookState + ')');
  assert(d1.autoEvent, 'auto-flag event recorded as observed');
  await page.evaluate(() => { window.__AOS.state.songId = null; });
  await page.locator('nav#tabs [data-tab="home"]').click();
  assert(await page.locator('[data-decision="slot"]').count() >= 1, 'Decide inbox shows the slot decision');

  // Persistence: reload and confirm everything survived IndexedDB round-trip
  await page.reload();
  await page.waitForTimeout(900);
  const st2 = await page.evaluate(() => ({
    songs: window.__AOS.state.songs.length,
    assets: window.__AOS.state.assets.length,
    events: window.__AOS.state.events.length,
    hookAssigned: !!window.__AOS.state.songs.find(x => x.title === 'Test Song').sections[2].assetId,
    masterPersisted: !!window.__AOS.state.songs.find(x => x.title.toLowerCase() === 'night drive').masterAssetId,
    decisionsAfterReload: window.__AOS.state.songs.flatMap(s => globalThis.AOSCore.decisionsFor(s, window.__AOS.state.assets.filter(a => a.songId === s.id))).length
  }));
  assert(st2.masterPersisted, 'pinned master persisted across reload');
  assert(st2.decisionsAfterReload >= 1, 'pending slot decision still surfaced after reload');
  assert(st2.songs >= 2 && st2.assets === 9 && st2.events >= 13, 'catalog persisted across reload (' + JSON.stringify(st2) + ')');
  assert(st2.hookAssigned, 'slot assignment persisted');

  // Audio intelligence: 120 BPM click file gets analyzed after import
  await page.locator('#open-import').click();
  await page.locator('#sheet [data-act="pick-files"]').click();
  await page.setInputFiles('#pick-files', ['/tmp/pulse groove v1.wav']);
  await page.waitForSelector('#ft-new');
  await page.fill('#ft-new', 'Pulse Groove');
  await page.locator('[data-act="files-new"]').click();
  await page.waitForSelector('[data-act="ip-close"]', { timeout: 15000 });
  await page.locator('[data-act="ip-close"]').click();
  let analyzed = null;
  for (let i = 0; i < 40 && !analyzed; i++) {
    await page.waitForTimeout(500);
    analyzed = await page.evaluate(() => {
      const a = window.__AOS.state.assets.find(x => x.file === 'pulse groove v1.wav');
      return a && a.analyzedAt ? { bpm: a.bpm } : null;
    });
  }
  assert(analyzed, 'analysis completed');
  assert(analyzed.bpm && Math.abs(analyzed.bpm - 120) <= 3, 'BPM detected on real import: ' + (analyzed && analyzed.bpm));

  // ---------- Cloudflare sync: real worker module, two simulated devices ----------
  await page.evaluate(async () => { await window.__AOS.enableSync(); });
  let s1 = await page.evaluate(() => window.__AOS.syncState);
  assert(s1.status === 'on' && s1.accountId, 'device 1 sync enabled with an account');

  // Everything already in the catalog got pushed on enable (pushAllToCloud)
  const pulledDirectly = await workerMod.default.fetch(
    new Request(`https://x/v1/sync/pull?since=0`, { headers: { authorization: 'Bearer ' + s1.token } }),
    workerEnv
  ).then(r => r.json());
  assert(pulledDirectly.changes.some(c => c.kind === 'song'), 'initial catalog snapshot reached the worker on enable');
  const songCountOnServer = pulledDirectly.changes.filter(c => c.kind === 'song').length;
  const expectedSongCount = await page.evaluate(() => window.__AOS.state.songs.length);
  assert(songCountOnServer === expectedSongCount,
    `all ${expectedSongCount} existing songs pushed (got ${songCountOnServer})`);

  // New mutation after enabling propagates via the debounced dirty-push
  await page.evaluate(() => { window.__AOS.record(window.__AOS.state.songs[0].id, 'Song', 'Approved', 'e2e sync marker'); });
  await page.waitForTimeout(1800); // debounce window
  await page.evaluate(async () => { await window.__AOS.pushDirtyToCloud(); });
  const afterEdit = await workerMod.default.fetch(
    new Request(`https://x/v1/sync/pull?since=0`, { headers: { authorization: 'Bearer ' + s1.token } }),
    workerEnv
  ).then(r => r.json());
  assert(afterEdit.changes.some(c => c.kind === 'event' && c.data && c.data.summary === 'e2e sync marker'),
    'post-enable mutation reached the worker via debounced push');

  // Second "device": fresh browser context (isolated storage), same worker backend
  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.route('https://artist-os-sync.astickley9.workers.dev/**', routeToWorker); // SAME workerEnv = same backend
  await page2.goto('http://localhost:8931/app.html');
  await page2.evaluate(() => { window.__AOS.state.songs = []; }); // sanity: device 2 starts empty (fresh IndexedDB anyway)

  const linkInfo = await page.evaluate(async () => window.__AOS.linkStart());
  assert(/^[A-Z2-9]{6}$/.test(linkInfo.code), 'device 1 produced a real link code from the real worker: ' + linkInfo.code);

  await page2.evaluate(async (code) => { await window.__AOS.linkClaim(code); }, linkInfo.code);
  const s2 = await page2.evaluate(() => window.__AOS.syncState);
  assert(s2.accountId === s1.accountId, 'device 2 joined the same account via the link code');

  const device2Songs = await page2.evaluate(() => window.__AOS.state.songs.map(s => s.title.toLowerCase()));
  assert(device2Songs.includes('night drive'), 'device 2 received device 1\'s catalog after linking: ' + JSON.stringify(device2Songs));
  assert(device2Songs.includes('test song'), 'device 2 received the other song too');
  const device2Events = await page2.evaluate(() => window.__AOS.state.events.some(e => e.summary === 'e2e sync marker'));
  assert(device2Events, 'device 2 received event history, not just song shells');

  // Mutation on device 2 flows back to device 1
  await page2.evaluate(() => { window.__AOS.record(window.__AOS.state.songs.find(s => s.title.toLowerCase() === 'night drive').id, 'Song', 'Approved', 'from device 2'); });
  await page2.waitForTimeout(1800);
  await page2.evaluate(async () => { await window.__AOS.pushDirtyToCloud(); });
  await page.evaluate(async () => { await window.__AOS.pullFromCloud(); });
  const backOnDevice1 = await page.evaluate(() => window.__AOS.state.events.some(e => e.summary === 'from device 2'));
  assert(backOnDevice1, 'bidirectional sync: device 2\'s change reached device 1');

  await context2.close();

  const fatal = errors.filter(e => !e.includes('AudioContext') && !e.includes('play()'));
  assert(fatal.length === 0, 'no page errors (' + (fatal[0] || 'clean') + ')');

  await browser.close(); server.close();
  console.log('\nE2E PASSED');
})().catch(e => { console.error(e.message); process.exit(1); });
