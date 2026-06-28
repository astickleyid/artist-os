
let data, currentSongId='golden-state', tab='master', panel='songs', query='';
const $ = s => document.querySelector(s);
function fmt(sec){ if(!sec) return '—'; let m=Math.floor(sec/60), s=Math.floor(sec%60).toString().padStart(2,'0'); return `${m}:${s}`; }
function track(id){ return data.tracks.find(t=>t.id===id); }
function song(){ return data.songs.find(s=>s.id===currentSongId) || data.songs[0]; }
function setPanel(p){ panel=p; document.querySelectorAll('.nav').forEach(n=>n.classList.toggle('active',n.dataset.panel===p)); renderMain(); }
function setTab(t){ tab=t; renderWorkbench(); }
function selectSong(id){ currentSongId=id; tab='master'; renderAll(); }
function renderAll(){ renderSongList(); renderWorkbench(); renderInspector(); }
function renderSongList(){
  const q=query.toLowerCase();
  $('#song-list').innerHTML = data.songs.filter(s=>!q || (s.title+s.subtitle+s.status+s.risk).toLowerCase().includes(q)).map(s=>`
    <div class="song-card ${s.id===currentSongId?'active':''}" onclick="selectSong('${s.id}')">
      <div class="song-card-top"><h3>${s.title}</h3><span class="badge">${s.status}</span></div>
      <p>${s.subtitle}</p>
      <div class="meter"><span style="width:${s.progress}%"></span></div>
    </div>
  `).join('');
}
function renderWorkbench(){
  const s=song();
  $('#song-title').textContent=s.title; $('#song-subtitle').textContent=s.subtitle; $('#song-score').textContent=s.quality;
  $('#score-circle').style.strokeDashoffset = 113 - (113*s.quality/100);
  document.querySelectorAll('.seg').forEach(b=>b.classList.toggle('active',b.dataset.tab===tab));
  if(tab==='master') renderMaster(s);
  if(tab==='changes') renderChanges(s);
  if(tab==='assets') renderAssets(s);
}
function renderMaster(s){
  $('#tab-content').innerHTML = `<div class="master-board">${s.sections.map((x,i)=>{
    const a=track(x.asset);
    const cls=x.state.split(' ')[0];
    return `<div class="section-row" onclick="inspectAsset('${x.asset}','${x.name}')">
      <div class="handle">${String(i+1).padStart(2,'0')}</div>
      <div><div class="section-name">${x.name}</div><div class="section-role">${x.role}</div></div>
      <div><div class="asset-name">${a?a.title:'Missing asset'}</div><div class="asset-file">${a?a.filename:'—'}</div>${a && a.url ? `<audio class="audio-mini" controls preload="none" src="${a.url}"></audio>` : '<div class="audio-placeholder">Preview unavailable in sanitized repo</div>'}</div>
      <div><div class="state ${cls}">${x.state}</div><div class="small">${x.score}%</div></div>
    </div>`
  }).join('')}</div>`;
}
function renderChanges(s){
  $('#tab-content').innerHTML = `<div class="change-list">${s.events.map(e=>{
    const after = data.tracks.find(t=>t.filename===e.after);
    return `<div class="change-row">
      <div class="change-time">${e.time}</div>
      <div class="change-target">${e.target}</div>
      <div class="change-op">${e.op}</div>
      <div class="change-summary">${e.summary}<br>
        ${e.before && e.before!=='none'?`<span class="file-token">Before: ${e.before}</span>`:''}
        ${e.after && e.after!=='pending'?`<span class="file-token">After: ${e.after}</span>`:''}
        ${after?`${after && after.url ? `<audio class="audio-mini" controls preload="none" src="${after.url}"></audio>` : ''}`:''}
      </div>
    </div>`
  }).join('')}</div>`;
}
function renderAssets(s){
  const assets = s.sections.map(x=>track(x.asset)).filter(Boolean);
  $('#tab-content').innerHTML = `<div class="assets-grid">${assets.map(a=>`
    <div class="asset-card" onclick="inspectAsset('${a.id}','Asset')">
      <h4>${a.title}</h4>
      <p>${a.filename}</p>
      <p>${fmt(a.duration)} · Created ${new Date(a.created).toLocaleDateString()}</p>
      ${a.url ? `<audio controls preload="none" src="${a.url}"></audio>` : '<div class="audio-placeholder">No audio committed</div>'}
    </div>
  `).join('')}</div>`;
}
function inspectAsset(id, section){
  const a=track(id);
  if(!a) return;
  $('#selected-asset').innerHTML = `<b>${section}</b><br>${a.title}<br><span class="small">${a.filename}</span><br><span class="small">Created ${new Date(a.created).toLocaleString()}</span><br><audio class="audio-mini" controls preload="none" src="${a.url}"></audio>`;
}
function renderInspector(){
  const s=song();
  $('#risk').textContent=s.risk; $('#progress-num').textContent=s.progress+'%'; $('#progress-bar').style.width=s.progress+'%';
}
function renderMain(){
  if(panel==='songs'){ document.querySelector('.stage').style.display='grid'; renderAll(); return; }
  const stage=$('.stage'); stage.style.display='block';
  if(panel==='assets'){
    $('.stage').innerHTML = `<div class="workbench" style="height:calc(100vh - 90px)"><div class="hero"><div><div class="crumb">Library</div><h1>Assets</h1><p>${data.tracks.length} audio files imported</p></div></div><div class="assets-grid">${data.tracks.map(a=>`<div class="asset-card"><h4>${a.title}</h4><p>${a.filename}</p><p>${fmt(a.duration)}</p>${a.url ? `<audio controls preload="none" src="${a.url}"></audio>` : '<div class="audio-placeholder">No audio committed</div>'}</div>`).join('')}</div></div>`;
  } else if(panel==='timeline'){
    const ev=data.songs.flatMap(s=>s.events.map(e=>({...e,song:s.title})));
    $('.stage').innerHTML = `<div class="workbench" style="height:calc(100vh - 90px)"><div class="hero"><div><div class="crumb">Library</div><h1>Timeline</h1><p>Universal event language: target + operation + evidence</p></div></div><div class="change-list">${ev.map(e=>`<div class="change-row"><div class="change-time">${e.time}</div><div class="change-target">${e.song} · ${e.target}</div><div class="change-op">${e.op}</div><div class="change-summary">${e.summary}</div></div>`).join('')}</div></div>`;
  } else {
    $('.stage').innerHTML = `<div class="workbench" style="height:calc(100vh - 90px)"><div class="hero"><div><div class="crumb">Alpha</div><h1>DNA</h1><p>Not claimed as production intelligence yet.</p></div></div><div class="assets-grid"><div class="asset-card"><h4>${data.tracks.length}</h4><p>Audio assets imported</p></div><div class="asset-card"><h4>${data.songs.length}</h4><p>Song workspaces</p></div><div class="asset-card"><h4>${data.songs.reduce((n,s)=>n+s.sections.length,0)}</h4><p>Master composition slots</p></div><div class="asset-card"><h4>${data.songs.reduce((n,s)=>n+s.events.length,0)}</h4><p>Creative changes</p></div></div></div>`;
  }
}
document.querySelectorAll('.nav').forEach(b=>b.onclick=()=>setPanel(b.dataset.panel));
document.querySelectorAll('.seg').forEach(b=>b.onclick=()=>setTab(b.dataset.tab));
$('#search').oninput=e=>{query=e.target.value; if(panel==='songs') renderSongList(); };
fetch('catalog.json').then(r=>r.json()).then(j=>{data=j; $('#asset-count').textContent=data.tracks.length; renderAll();});
