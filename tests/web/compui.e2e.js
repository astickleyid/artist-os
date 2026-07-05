const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const assert = require('assert');
const ROOT='/home/claude/artist-os/docs';
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.wav':'audio/wav'};
const server=http.createServer((q,r)=>{const p=path.join(ROOT,q.url==='/'?'index.html':q.url.split('?')[0]);try{r.setHeader('Content-Type',MIME[path.extname(p)]||'text/plain');r.end(fs.readFileSync(p))}catch(e){r.statusCode=404;r.end('x')}});
let pass=0; const ok=(c,m)=>{assert(c,m);console.log('  ✓ '+m);pass++;};
(async()=>{
  await new Promise(r=>server.listen(8931,r));
  const b=await chromium.launch(); const page=await b.newPage({viewport:{width:390,height:844},deviceScaleFactor:2});
  const errs=[]; page.on('pageerror',e=>errs.push(e.message));
  await page.goto('http://localhost:8931/app.html'); await page.waitForTimeout(400);
  await page.locator('#open-import').click();
  await page.locator('#sheet [data-act="pick-files"]').click();
  await page.setInputFiles('#pick-files',['/tmp/night groove v1.wav','/tmp/night groove v2.wav']);
  await page.waitForSelector('[data-act="smart-import"]',{timeout:8000});
  await page.locator('.btn.gold[data-act="smart-import"]').click();
  await page.waitForFunction(()=>window.__AOS&&window.__AOS.state.assets.length>=2,{timeout:20000});
  await page.waitForTimeout(500);
  // open song + Comp tab
  await page.evaluate(()=>{ const s=window.__AOS.state.songs[0]; window.__AOS.state.songId=s.id; window.__AOS.state.songTab='comp'; window.__AOS.renderAll(false); });
  // wait for comp audio to load (2 lanes decoded)
  await page.waitForFunction(()=>{ const cs=window.__AOS.state; return window.__AOS.CompPlayer && window.__AOS.CompPlayer.duration>0; },{timeout:20000}).catch(()=>{});
  await page.waitForTimeout(800);
  await page.evaluate(()=>window.__AOS.renderAll(false));
  await page.waitForTimeout(400);

  const lanes = await page.locator('.comp-lane').count();
  ok(lanes===2, 'two version lanes rendered');
  ok(await page.locator('#comp-strip').count()===1, 'comp strip present');
  ok(await page.locator('[data-act="comp-play"]').count()===1, 'transport present');

  // perform a real swipe on the 2nd lane via pointer events (claim second half)
  await page.evaluate(()=>{
    const lane = document.querySelectorAll('.comp-lane[data-complane]')[1];
    const rect = document.querySelector('#comp-lanes').getBoundingClientRect();
    const y = lane.getBoundingClientRect().top + 30;
    const fire=(t,x)=>lane.dispatchEvent(new PointerEvent(t,{clientX:x,clientY:y,pointerId:1,bubbles:true}));
    fire('pointerdown', rect.left+rect.width*0.5);
    fire('pointermove', rect.left+rect.width*0.9);
    window.dispatchEvent(new PointerEvent('pointerup',{clientX:rect.left+rect.width*0.9,clientY:y,pointerId:1,bubbles:true}));
  });
  await page.waitForTimeout(300);

  const compInfo = await page.evaluate(()=>{
    // read internal comp state via a fresh eval of the module's compState through __AOS
    const segs = window.__AOS.CompPlayer.comp ? null : null;
    // compState isn't exposed; infer from strip segments count
    return { stripSegs: document.querySelectorAll('#comp-strip .seg').length };
  });
  ok(compInfo.stripSegs>=2, 'swipe created a multi-segment comp ('+compInfo.stripSegs+' segments in strip)');

  // render the comped result
  let dl=null; page.on('download',d=>dl=d.suggestedFilename());
  await page.evaluate(()=>document.querySelector('[data-act="comp-render"]').click());
  await page.waitForTimeout(3500);
  ok(dl && dl.endsWith('-comp.wav'), 'comp rendered + downloaded ('+dl+')');
  await page.screenshot({path:'/tmp/comp-ui.png', fullPage:true});
  ok(errs.length===0,'no page errors'+(errs.length?': '+errs[0]:''));
  console.log('\n  '+pass+' comp UI assertions passed');
  await b.close(); server.close(); process.exit(errs.length?1:0);
})().catch(e=>{console.error('FAIL:',e.message);process.exit(1)});
