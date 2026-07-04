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
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });

  const assert = (cond, msg) => { if (!cond) throw new Error('ASSERT FAIL: ' + msg); console.log('  ✓ ' + msg); };

  await page.goto('http://localhost:8931/');
  await page.waitForTimeout(600);
  assert(await page.locator('.onboard').count() === 1, 'onboarding shows on empty catalog');

  // Import two real audio files via the file picker → new song flow
  await page.locator('[data-act="pick-files"]').first().click();
  await page.setInputFiles('#pick-files', ['/tmp/hook take1.wav', '/tmp/trap beat v1.wav']);
  await page.waitForSelector('#ft-new');
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

  // Persistence: reload and confirm everything survived IndexedDB round-trip
  await page.reload();
  await page.waitForTimeout(900);
  const st2 = await page.evaluate(() => ({
    songs: window.__AOS.state.songs.length,
    assets: window.__AOS.state.assets.length,
    events: window.__AOS.state.events.length,
    hookAssigned: !!window.__AOS.state.songs.find(x => x.title === 'Test Song').sections[2].assetId
  }));
  assert(st2.songs >= 1 && st2.assets === 2 && st2.events >= 4, 'catalog persisted across reload');
  assert(st2.hookAssigned, 'slot assignment persisted');

  const fatal = errors.filter(e => !e.includes('AudioContext') && !e.includes('play()'));
  assert(fatal.length === 0, 'no page errors (' + (fatal[0] || 'clean') + ')');

  await browser.close(); server.close();
  console.log('\nE2E PASSED');
})().catch(e => { console.error(e.message); process.exit(1); });
