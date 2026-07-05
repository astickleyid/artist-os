const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const assert = require('assert');
const ROOT = '/home/claude/artist-os/docs';
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.wav':'audio/wav'};
const server=http.createServer((q,r)=>{const p=path.join(ROOT,q.url==='/'?'index.html':q.url.split('?')[0]);try{r.setHeader('Content-Type',MIME[path.extname(p)]||'text/plain');r.end(fs.readFileSync(p))}catch(e){r.statusCode=404;r.end('x')}});
let pass=0; const ok=(c,m)=>{assert(c,m);console.log('  ✓ '+m);pass++;};
(async()=>{
  await new Promise(r=>server.listen(8931,r));
  const b=await chromium.launch(); const page=await b.newPage();
  const errs=[]; page.on('pageerror',e=>errs.push(e.message));
  await page.goto('http://localhost:8931/app.html'); await page.waitForTimeout(400);
  // import two full versions of one song
  await page.locator('#open-import').click();
  await page.locator('#sheet [data-act="pick-files"]').click();
  await page.setInputFiles('#pick-files',['/tmp/night groove v1.wav','/tmp/night groove v2.wav']);
  await page.waitForSelector('[data-act="smart-import"]',{timeout:8000});
  await page.locator('.btn.gold[data-act="smart-import"]').click();
  await page.waitForFunction(()=>window.__AOS&&window.__AOS.state.assets.length>=2,{timeout:20000});
  await page.waitForTimeout(500);
  // build a comp: v1 for first half, v2 for second half, render it, decode it back
  const out = await page.evaluate(async ()=>{
    const A=window.__AOS, assets=A.state.assets;
    const versions = assets.map((a,i)=>({id:'src'+i, assetId:a.id}));
    let comp = window.AOSComp.makeComp(64, versions[0].id);   // full song ~64s
    comp = window.AOSComp.applySwipe(comp, versions[1].id, 32, 64); // v2 second half
    const usedIds = [...new Set(comp.segments.map(s=>s.sourceId))];
    const blob = await A.renderComp(comp, versions, {crossfade:0.03});
    const ctx = new (window.AudioContext||window.webkitAudioContext)();
    const buf = await ctx.decodeAudioData(await blob.arrayBuffer());
    return { bytes: blob.size, seconds: buf.duration, channels: buf.numberOfChannels, sources: usedIds.length, segs: comp.segments.length };
  });
  ok(out.sources===2, 'comp uses both versions (verse from one region, rest from another)');
  ok(out.segs===2, 'comp has 2 segments after the swipe');
  ok(out.bytes>44, 'rendered a real WAV ('+Math.round(out.bytes/1024)+' KB)');
  ok(out.channels===2, 'stereo output');
  ok(Math.abs(out.seconds-64)<1.5, 'comp length ~matches timeline ('+out.seconds.toFixed(1)+'s)');
  ok(errs.length===0,'no page errors'+(errs.length?': '+errs[0]:''));
  console.log('\n  '+pass+' comp render assertions passed');
  await b.close(); server.close(); process.exit(errs.length?1:0);
})().catch(e=>{console.error('FAIL:',e.message);process.exit(1)});
