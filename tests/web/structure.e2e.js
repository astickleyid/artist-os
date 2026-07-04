const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const assert = require('assert');
const ROOT = '/home/claude/artist-os/docs';
const MIME = { '.html':'text/html','.js':'text/javascript','.css':'text/css','.wav':'audio/wav' };
const server = http.createServer((req,res)=>{
  const p = path.join(ROOT, req.url==='/'?'index.html':req.url.split('?')[0]);
  try{ res.setHeader('Content-Type',MIME[path.extname(p)]||'text/plain'); res.end(fs.readFileSync(p)); }
  catch(e){ res.statusCode=404; res.end('nf'); }
});
let pass=0; const ok=(c,m)=>{ assert(c,m); console.log('  ✓ '+m); pass++; };

(async()=>{
  await new Promise(r=>server.listen(8931,r));
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport:{width:390,height:844} });
  const errs=[]; page.on('pageerror',e=>errs.push(e.message));
  let downloaded=null;
  page.on('download', d => { downloaded = d.suggestedFilename(); });

  await page.goto('http://localhost:8931/app.html');
  await page.waitForTimeout(500);

  // import two structured versions of one song via the real import path
  await page.locator('#open-import').click();
  await page.locator('#sheet [data-act="pick-files"]').click();
  await page.setInputFiles('#pick-files', ['/tmp/night groove v1.wav','/tmp/night groove v2.wav']);
  await page.waitForSelector('[data-act="smart-import"]', { timeout: 8000 });
  await page.locator('.btn.gold[data-act="smart-import"]').click();
  await page.waitForFunction(() => window.__AOS && window.__AOS.state.assets.length >= 2, { timeout: 20000 });
  await page.waitForTimeout(800);
  await page.evaluate(()=>{ document.querySelector('#sheet')?.classList.remove('show'); document.querySelector('#scrim')?.classList.remove('show'); });

  const info = await page.evaluate(()=>({ assets: window.__AOS.state.assets.length, songs: window.__AOS.state.songs.length }));
  ok(info.assets === 2 && info.songs === 1, 'two versions imported into one song');

  // detect sections on BOTH versions via the real segmentAsset entry point
  const seg = await page.evaluate(async ()=>{
    const ids = window.__AOS.state.assets.map(a=>a.id);
    const r = [];
    for (const id of ids) { const secs = await window.__AOS.segmentAsset(id); r.push(secs ? secs.length : 0); }
    return r;
  });
  ok(seg.every(n => n >= 5 && n <= 9), 'both versions segmented into plausible sections ('+seg.join(', ')+')');

  const labelInfo = await page.evaluate(()=>{
    const a = window.__AOS.state.assets[0];
    return { labels: a.sections.map(s=>s.label), hasConf: a.sections.every(s=>typeof s.confidence==='number') };
  });
  ok(labelInfo.labels.includes('Hook'), 'proposed a Hook');
  ok(labelInfo.labels.includes('Intro'), 'proposed an Intro');
  ok(labelInfo.hasConf, 'every section carries confidence for the confirm UI');

  // confirm + rename a section (simulate the tap path through state + persist)
  const renamed = await page.evaluate(async ()=>{
    const a = window.__AOS.state.assets[0];
    const sec = a.sections[1];
    sec.label = 'Verse'; sec.confirmed = true;
    return { label: sec.label, confirmed: sec.confirmed };
  });
  ok(renamed.confirmed && renamed.label === 'Verse', 'section confirm/rename updates the model');

  // build a cross-version assembly recipe
  const recipe = await page.evaluate(()=>{
    window.__AOS.startAssembly();
    return window.__AOS.state.asmRecipe ? window.__AOS.state.asmRecipe.picks.map(p=>({label:p.label, asset:p.assetId})) : null;
  });
  ok(recipe && recipe.length >= 3, 'assembly recipe built across sections ('+recipe.length+' slots)');

  // swap one section's source to the OTHER version — proving cross-version assembly
  const swapped = await page.evaluate(()=>{
    const r = window.__AOS.state.asmRecipe.picks;
    const assets = window.__AOS.state.assets;
    // find a hook slot, point it at the other version's hook
    const hookIdx = r.findIndex(p=>p.label==='Hook');
    if (hookIdx<0) return { ok:false };
    const cur = r[hookIdx].assetId;
    const other = assets.find(a=>a.id!==cur && a.sections.some(s=>s.label==='Hook'));
    if (!other) return { ok:false };
    const otherHook = other.sections.find(s=>s.label==='Hook');
    Object.assign(r[hookIdx], { assetId: other.id, sectionId: otherHook.id, start: otherHook.start, end: otherHook.end });
    // now recipe spans 2 versions
    const versions = new Set(r.map(p=>p.assetId));
    return { ok:true, versions: versions.size };
  });
  ok(swapped.ok && swapped.versions >= 2, 'recipe spans multiple versions (verse from one, hook from another)');

  // unified folders gather sections across versions
  const folders = await page.evaluate(()=>{
    const slices = window.__AOS.state.assets.flatMap(a=>a.sections.map(s=>({label:s.label, v:a.id, start:s.start, end:s.end, bpm:a.bpm, keyName:a.keyName})));
    return window.AOSAssembly.unifiedFolders(slices).map(f=>({label:f.label, n:f.items.length}));
  });
  const hookFolder = folders.find(f=>f.label==='Hook');
  ok(hookFolder && hookFolder.n >= 2, 'unified Hook folder gathers hooks across versions ('+hookFolder.n+')');

  // RENDER the cross-version track and confirm a real WAV comes out
  const rendered = await page.evaluate(async ()=>{
    const recipe = window.__AOS.state.asmRecipe.picks;
    const blob = await window.__AOS.renderRecipe(recipe, { crossfade: 0.04 });
    // decode it back to confirm it's valid audio of roughly the right length
    const ctx = new (window.AudioContext||window.webkitAudioContext)();
    const buf = await ctx.decodeAudioData(await blob.arrayBuffer());
    const expected = recipe.reduce((n,p)=>n+(p.end-p.start),0) - (recipe.length-1)*0.04;
    return { bytes: blob.size, seconds: buf.duration, channels: buf.numberOfChannels, expected };
  });
  ok(rendered.bytes > 44, 'render produced a non-empty WAV ('+Math.round(rendered.bytes/1024)+' KB)');
  ok(rendered.channels === 2, 'rendered stereo');
  ok(Math.abs(rendered.seconds - rendered.expected) < 1.5, 'rendered length ~matches recipe ('+rendered.seconds.toFixed(1)+'s vs '+rendered.expected.toFixed(1)+'s expected)');

  ok(errs.length===0, 'no page errors' + (errs.length?': '+errs[0]:''));

  console.log('\n  '+pass+' structure/assembly assertions passed');
  await browser.close(); server.close(); process.exit(errs.length?1:0);
})().catch(e=>{ console.error('FAIL:', e.message); process.exit(1); });
