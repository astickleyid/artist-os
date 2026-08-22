const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../../docs');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };

const server = http.createServer((req, res) => {
  const pathname = req.url === '/' ? '/app.html' : req.url.split('?')[0];
  const file = path.join(ROOT, pathname);
  try {
    res.setHeader('Content-Type', MIME[path.extname(file)] || 'text/plain');
    res.end(fs.readFileSync(file));
  } catch (error) {
    res.statusCode = 404;
    res.end('not found');
  }
});

const assert = (condition, message) => {
  if (!condition) throw new Error(`ASSERT FAIL: ${message}`);
  console.log(`  ✓ ${message}`);
};

(async () => {
  await new Promise(resolve => server.listen(8932, resolve));
  const browser = await chromium.launch();
  const page = await browser.newPage();

  try {
    await page.goto('http://localhost:8932/app.html');
    await page.waitForFunction(() => window.__AOS && window.AOSCanonicalWeb && window.AOSCanonicalWeb.persistChanges);

    const ids = {
      song: '11111111-1111-4111-8111-111111111111',
      source: '22222222-2222-4222-8222-222222222222',
      decision: '33333333-3333-4333-8333-333333333333',
      master: '44444444-4444-4444-8444-444444444444',
      section: '55555555-5555-4555-8555-555555555555'
    };

    await page.evaluate(async ids => {
      const t = Date.now() + 5000;
      await window.AOSCanonicalWeb.persistChanges([
        {
          kind: 'song', id: ids.song, updatedAt: t,
          data: {
            id: ids.song,
            title: 'Canonical Reload Song',
            status: 'review',
            created: t - 1000,
            updatedAt: t,
            sections: [{
              id: ids.section,
              name: 'Hook',
              role: 'Melody',
              assetId: 'legacy-source',
              state: 'open',
              conf: 0.1,
              note: 'legacy mirror'
            }],
            masterAssetId: 'legacy-master',
            progress: 0,
            risk: 'In assembly'
          }
        },
        {
          kind: 'decision', id: ids.decision, updatedAt: t + 1,
          data: {
            id: ids.decision,
            songId: ids.song,
            target: 'Hook',
            selectedAssetId: ids.source,
            rationale: 'Artist selected this take',
            created: t + 1,
            updatedAt: t + 1
          }
        },
        {
          kind: 'masterComposition', id: ids.master, updatedAt: t + 2,
          data: {
            id: ids.master,
            songId: ids.song,
            updatedAt: t + 2,
            outputAssetId: ids.source,
            sections: [{
              id: ids.section,
              name: 'Hook',
              role: 'hook',
              state: 'needsDecision',
              confidence: 0.95,
              note: 'Canonical source survives reload',
              selections: [{ kind: 'sourceAsset', referenceId: ids.source }]
            }]
          }
        }
      ]);
    }, ids);

    await page.reload();
    await page.waitForFunction(() => window.__AOS && Array.isArray(window.__AOS.state.masterCompositions));
    await page.waitForTimeout(500);

    const hydrated = await page.evaluate(ids => {
      const state = window.__AOS.state;
      const song = state.songs.find(item => item.id === ids.song);
      const decision = (state.decisions || []).find(item => item.id === ids.decision);
      const master = (state.masterCompositions || []).find(item => item.id === ids.master);
      const runtimeSection = song && song.sections && song.sections.find(item => item.id === ids.section);
      return {
        songTitle: song && song.title,
        decisionRationale: decision && decision.rationale,
        outputAssetId: master && master.outputAssetId,
        sourceAssetId: master && master.sections && master.sections[0] &&
          master.sections[0].selections && master.sections[0].selections[0] &&
          master.sections[0].selections[0].referenceId,
        runtimeMasterAssetId: song && song.masterAssetId,
        runtimeSourceAssetId: runtimeSection && runtimeSection.assetId,
        runtimeSectionState: runtimeSection && runtimeSection.state,
        runtimeRisk: song && song.risk,
        eventPollution: state.events.some(event => event.id === ids.decision || event.id === ids.master)
      };
    }, ids);

    assert(hydrated.songTitle === 'Canonical Reload Song', 'remote Song survives browser reload');
    assert(hydrated.decisionRationale === 'Artist selected this take', 'Creative Decision survives browser reload');
    assert(hydrated.outputAssetId === ids.source, 'Master Composition output survives browser reload');
    assert(hydrated.sourceAssetId === ids.source, 'canonical section source survives browser reload');
    assert(hydrated.runtimeMasterAssetId === ids.source, 'web runtime current master follows canonical output');
    assert(hydrated.runtimeSourceAssetId === ids.source, 'web runtime section source follows canonical selection');
    assert(hydrated.runtimeSectionState === 'needsDecision', 'web runtime decision state follows canonical section');
    assert(hydrated.runtimeRisk === 'Hook decision unresolved', 'web runtime risk follows canonical unresolved state');
    assert(hydrated.eventPollution === false, 'Decision/Master Composition are not misclassified as Creative Events');

    console.log('canonical web reload e2e passed');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
