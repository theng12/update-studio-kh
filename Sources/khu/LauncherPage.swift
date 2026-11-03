// The Studio Launcher KH page. Same tokens as Update Studio KH's page, so the suite reads as one.
// Every value from the feed or an SSD is set as text, never parsed as HTML.
enum LauncherPage {
    static let html = #"""
<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>
:root{--bg:#f5f6f5;--panel:#fff;--line:#e2e5e3;--line2:#eef0ef;--text:#16201c;--sub:#5b6762;--accent:#1d6b51;--accent-ink:#fff;--ok:#1a7448;--ok-bg:#e2f3e9;--warn:#875800;--warn-bg:#fcefd2;--bad:#b42318;--bad-bg:#fde8e6;--info:#1d5fa8;--info-bg:#e5eefb;--muted-bg:#eef0ef;--focus:#2e8b6a;--field:#9aa6a0;--shadow:0 14px 40px rgba(15,30,25,.18)}
@media (prefers-color-scheme:dark){:root{--bg:#101513;--panel:#171e1b;--line:#29332f;--line2:#202926;--text:#e6ece9;--sub:#a9b5af;--accent:#3fa37f;--accent-ink:#06120d;--ok:#62d19a;--ok-bg:#15301f;--warn:#f0b450;--warn-bg:#33270f;--bad:#ff8a7e;--bad-bg:#3a1714;--info:#8ab8f2;--info-bg:#15263c;--muted-bg:#212a26;--focus:#62d19a;--field:#5f6e67;--shadow:0 16px 44px rgba(0,0,0,.55)}}
*{box-sizing:border-box}html{background:var(--bg);color:var(--text);font:13.5px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased;-webkit-user-select:none;cursor:default}
body{margin:0;min-height:100vh;display:flex;flex-direction:column}::selection{background:var(--accent);color:var(--accent-ink)}
.num,.ver{font-variant-numeric:tabular-nums}.ver{font:12px/1.3 ui-monospace,Menlo,monospace;color:var(--sub)}.ver b{color:var(--text);font-weight:600}
.sub{color:var(--sub)}.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}button,select,input{font:inherit;color:inherit}
.menu .check svg{width:13px;height:13px}
:focus-visible{outline:2px solid var(--focus);outline-offset:2px}
::-webkit-scrollbar{width:11px;height:11px}::-webkit-scrollbar-thumb{background:var(--line);border-radius:8px;border:3px solid var(--bg)}::-webkit-scrollbar-track{background:transparent}
header{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:12px;padding:14px 22px;background:var(--panel);border-bottom:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:10px;margin-right:auto}.brand svg{width:30px;height:30px;flex:none}.brand h1{font-size:16px;margin:0;letter-spacing:-.015em}.brand p{margin:0;font-size:12px;color:var(--sub)}
.btn{height:30px;padding:0 13px;border-radius:7px;border:1px solid var(--line);background:var(--panel);font-weight:550;white-space:nowrap}
.btn:hover:not(:disabled){border-color:var(--field)}.btn:active:not(:disabled){transform:translateY(.5px)}.btn:disabled{opacity:.45}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}.btn.primary:hover:not(:disabled){filter:brightness(1.07)}
.btn.icon{width:30px;padding:0;display:inline-grid;place-items:center}.btn.icon svg{width:15px;height:15px}
.btn.danger{color:var(--bad)}
.seg{display:inline-flex;padding:2px;background:var(--muted-bg);border-radius:8px;gap:2px}.seg button{height:26px;min-width:30px;padding:0 9px;border:0;border-radius:6px;background:none;color:var(--sub);display:inline-grid;place-items:center}
.seg button[aria-pressed=true]{background:var(--panel);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.12)}.seg svg{width:14px;height:14px}
select,input[type=search]{height:30px;border:1px solid var(--line);border-radius:7px;background:var(--panel);padding:0 9px}input[type=search]{width:190px}
.set input[type=text]{flex:1;min-width:0;height:30px;border:1px solid var(--line);border-radius:7px;background:var(--panel);padding:0 9px;font:12px/1.4 ui-monospace,Menlo,monospace}
input::placeholder{color:var(--sub)}
main{flex:1;padding:18px 22px 8px}
h2{font-size:13px;font-weight:600;margin:22px 0 10px;color:var(--sub)}h2:first-child{margin-top:4px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:15px 16px 14px;display:flex;flex-direction:column;gap:10px;min-height:196px;transition:border-color .15s}
.card:hover{border-color:var(--field)}.card.click{cursor:pointer}
.head{display:flex;gap:12px;align-items:center}.head img,.ph{width:46px;height:46px;flex:none;border-radius:11px}.ph{background:var(--muted-bg);display:grid;place-items:center;color:var(--sub)}
.head .t{min-width:0}.name{font-weight:650;font-size:14.5px;letter-spacing:-.012em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tag{color:var(--sub);font-size:12.5px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.meta{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.chip{font-size:11.5px;font-weight:600;padding:2px 8px;border-radius:99px;background:var(--muted-bg);color:var(--sub);white-space:nowrap}
.chip.ok{background:var(--ok-bg);color:var(--ok)}.chip.warn{background:var(--warn-bg);color:var(--warn)}.chip.bad{background:var(--bad-bg);color:var(--bad)}.chip.info{background:var(--info-bg);color:var(--info)}
.reason{color:var(--bad);font-size:12px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.when{font-size:12px;color:var(--sub)}
.foot{margin-top:auto;display:flex;gap:8px;align-items:center}.foot .main{flex:1}
.prog{flex:1;display:flex;flex-direction:column;gap:6px}.prog .line{font-size:12px}.bar{height:4px;border-radius:4px;background:var(--line2);overflow:hidden}
.bar i{display:block;height:100%;background:var(--app,var(--accent));border-radius:4px;transition:width .4s cubic-bezier(.16,1,.3,1)}
.bar.loose i{width:35%;animation:loose 1.4s cubic-bezier(.45,0,.55,1) infinite}@keyframes loose{0%{transform:translateX(-100%)}100%{transform:translateX(290%)}}
@media (prefers-reduced-motion:reduce){.bar.loose i{animation:none;width:100%;opacity:.5}}
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
th{font-size:11.5px;font-weight:600;color:var(--sub);text-align:left;padding:9px 14px;border-bottom:1px solid var(--line)}
td{padding:9px 14px;border-bottom:1px solid var(--line2);vertical-align:middle}tr:last-child td{border-bottom:0}tbody tr:hover{background:var(--line2)}
td .head img,td .ph{width:32px;height:32px;border-radius:8px}td .name{font-size:13.5px}td.act{width:1%;white-space:nowrap;text-align:right}td.act .btn+.btn{margin-left:6px}
footer{position:sticky;bottom:0;display:flex;gap:14px;align-items:center;padding:9px 22px;font-size:12px;color:var(--sub);background:var(--bg);border-top:1px solid var(--line)}
footer .link{background:none;border:0;color:var(--accent);padding:0;cursor:pointer}footer .err{color:var(--bad)}
.empty{padding:40px 0;text-align:center;color:var(--sub)}
.scrim{position:fixed;inset:0;background:rgba(10,18,15,.32);z-index:10;display:flex;justify-content:center;align-items:flex-start;padding:34px 24px;overflow:auto}
@media (prefers-color-scheme:dark){.scrim{background:rgba(0,0,0,.5)}}
.sheet{background:var(--panel);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);width:min(920px,100%);animation:rise .22s cubic-bezier(.16,1,.3,1)}
@keyframes rise{from{opacity:0;transform:translateY(8px)}}
.sheet .top{display:flex;gap:18px;align-items:flex-start;padding:22px 24px;border-bottom:1px solid var(--line)}
.sheet .top img,.sheet .top .ph{width:88px;height:88px;border-radius:20px}.sheet h3{font-size:23px;letter-spacing:-.025em;margin:2px 0 3px}
.sheet .top .t{flex:1;min-width:0}.sheet .nav{display:flex;gap:6px}
.cols{display:grid;grid-template-columns:1.35fr 1fr;gap:26px;padding:20px 24px 24px}
.desc{font-size:14px;line-height:1.55;max-width:62ch;margin:0 0 18px}
h4{font-size:13px;margin:0 0 10px;font-weight:650}
ol.feat{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:8px;counter-reset:f}
ol.feat li{counter-increment:f;display:grid;grid-template-columns:28px 1fr;gap:2px 8px;padding:10px 12px;border:1px solid var(--line2);border-radius:10px}
ol.feat li::before{content:counter(f,decimal-leading-zero);font:600 11.5px/1.6 ui-monospace,Menlo,monospace;color:var(--accent);grid-row:span 2}
ol.feat b{font-weight:600}ol.feat span{color:var(--sub);font-size:12.5px}
.facts{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:20px}.facts div{border:1px solid var(--line2);border-radius:10px;padding:9px 11px}
.facts dt{font-size:11.5px;color:var(--sub);margin-bottom:2px}.facts dd{margin:0;font-weight:600}
ul.changes{margin:0;padding-left:17px}ul.changes li{margin-bottom:6px}.more{background:none;border:0;color:var(--accent);padding:2px 0;cursor:pointer;font-weight:550}
.menu{position:fixed;z-index:20;min-width:210px;background:var(--panel);border:1px solid var(--line);border-radius:10px;box-shadow:var(--shadow);padding:5px;animation:rise .14s cubic-bezier(.16,1,.3,1)}
.menu button{display:flex;width:100%;text-align:left;border:0;background:none;padding:6px 10px;border-radius:6px;gap:8px;align-items:center}
.menu button:hover,.menu button:focus-visible{background:var(--accent);color:var(--accent-ink);outline:0}.menu button.danger{color:var(--bad)}.menu button.danger:hover{color:var(--accent-ink)}
.menu hr{border:0;border-top:1px solid var(--line2);margin:5px 4px}.menu .check{width:14px;text-align:center}
.set{width:min(640px,100%)}.set .body{padding:6px 24px 22px}.set section{padding:14px 0;border-bottom:1px solid var(--line2)}.set section:last-child{border-bottom:0}
.set h4{margin-bottom:12px}.row{display:flex;justify-content:space-between;align-items:center;gap:16px;margin:8px 0}
.row label{display:flex;gap:9px;align-items:flex-start}.row input[type=checkbox]{accent-color:var(--accent);width:15px;height:15px;margin:1px 0 0}
.note{font-size:12px;color:var(--sub);margin:2px 0 0 24px}.dis{opacity:.5}
.bottom{display:flex;justify-content:flex-end;padding:14px 24px;border-top:1px solid var(--line)}
@media (max-width:820px){input[type=search]{width:130px}.cols{grid-template-columns:1fr}.brand p{display:none}}
</style></head><body>
<header>
 <div class=brand><svg viewBox="0 0 32 32" aria-hidden=true><rect width=32 height=32 rx=8 fill="var(--accent)"/><g fill="#fff"><rect x=8 y=8 width=7 height=7 rx=1.8 /><rect x=17 y=8 width=7 height=7 rx=1.8 /><rect x=8 y=17 width=7 height=7 rx=1.8 /><rect x=17 y=17 width=7 height=7 rx=1.8 /></g></svg>
 <div><h1>Studio Launcher KH</h1><p id=mac>Apps for this Mac</p></div></div>
 <button class="btn primary" id=all hidden></button>
 <label class=sr for=sort>Sort</label><select id=sort aria-label="Sort"><option value=name>Name</option><option value=recent>Recently updated</option></select>
 <input type=search id=q placeholder="Search apps" aria-label="Search apps">
 <div class=seg role=group aria-label="View"><button id=vgrid title="Grid" aria-label="Grid"><svg viewBox="0 0 16 16" fill=currentColor><rect x=1 y=1 width=6 height=6 rx=1.5 /><rect x=9 y=1 width=6 height=6 rx=1.5 /><rect x=1 y=9 width=6 height=6 rx=1.5 /><rect x=9 y=9 width=6 height=6 rx=1.5 /></svg></button><button id=vlist title="List" aria-label="List"><svg viewBox="0 0 16 16" fill=currentColor><rect x=1 y=2 width=14 height=2.4 rx=1.2 /><rect x=1 y=6.8 width=14 height=2.4 rx=1.2 /><rect x=1 y=11.6 width=14 height=2.4 rx=1.2 /></svg></button></div>
 <button class="btn icon" id=check title="Check for updates now" aria-label="Check for updates now"><svg viewBox="0 0 16 16" fill=none stroke=currentColor stroke-width=1.7 stroke-linecap=round stroke-linejoin=round><path d="M13.5 8A5.5 5.5 0 1 1 11.9 4.1"/><path d="M12.5 1.8v2.7H9.8"/></svg></button>
 <button class="btn icon" id=gear title="Settings" aria-label="Settings"><svg viewBox="0 0 16 16" fill=none stroke=currentColor stroke-width=1.6 stroke-linecap=round><path d="M2 4.5h7M12.5 4.5H14M2 11.5h2M7.5 11.5H14"/><circle cx=10.8 cy=4.5 r=1.7 /><circle cx=5.8 cy=11.5 r=1.7 /></svg></button>
</header>
<main id=main></main>
<footer><span id=checked></span><span id=hiddenNote></span><span id=err class=err></span></footer>
<script>
const S={apps:[],sources:[],settings:{}},post=m=>window.webkit.messageHandlers.khu.postMessage(m);
window.onerror=(msg,src,line)=>post({action:'log',text:msg+' (line '+line+')'});
// The page has no origin of its own, so storage may refuse; the choice then lasts while the window is open.
const store={get:k=>{try{return localStorage.getItem(k)}catch(e){return null}},set:(k,v)=>{try{store.set(k,v)}catch(e){}}};
let view=store.get('view')||'grid',sort=store.get('sort')||'name',q='',detail=null,settingsOpen=false,showHidden=false,showAll={};
const $=id=>document.getElementById(id);
function el(tag,attrs,...kids){const e=document.createElement(tag);for(const k in attrs||{}){const v=attrs[k];if(v==null||v===false)continue;
 if(k=='class')e.className=v;else if(k.startsWith('on'))e.addEventListener(k.slice(2),v);else if(k=='style')e.style.cssText=v;else e.setAttribute(k,v===true&&!k.startsWith('aria-')?'':String(v))}
 for(const c of kids.flat()){if(c==null||c===false)continue;e.append(c.nodeType?c:document.createTextNode(String(c)))}return e}
const day=iso=>{if(!iso)return null;const d=new Date(iso);return isNaN(d)?null:d.toLocaleDateString(undefined,{month:'short',day:'numeric',year:'numeric'})};
const mb=b=>b==null?null:(b>=1e9?(b/1e9).toFixed(1)+' GB':b>=1e6?Math.round(b/1e6)+' MB':Math.max(1,Math.round(b/1e3))+' KB');
function ago(iso){if(!iso)return 'Not checked yet';const s=(Date.now()-new Date(iso))/1000;if(s<60)return 'Checked just now';if(s<3600)return 'Checked '+Math.round(s/60)+' min ago';return 'Checked '+Math.round(s/3600)+' h ago'}
// A failure in plain words; the Mac's own text stays in Copy error report.
function plain(r){if(!r)return '';const t=r.toLowerCase();
 if(t.includes('hdiutil')||t.includes('image not recognized')||t.includes('no mountable'))return 'The installer file couldn’t be opened. It may be damaged; try Update again.';
 if(t.includes('does not match its checksum'))return 'The copy on the SSD doesn’t match its checksum, so it wasn’t used. Try the SSD again or update from the feed.';
 if(t.includes('dmg holds')||t.includes('this mac\'s app is'))return 'The installer holds a different app than the one on this Mac. Nothing was changed.';
 if(t.includes('cancelled on this mac'))return 'Cancelled. Nothing was changed.';
 if(t.includes('did not finish')||t.includes('download')||t.includes('could not connect')||t.includes('timed out'))return 'The download didn’t finish. Check the network and try Update again.';
 if(t.includes('not healthy')||t.includes('rolled back'))return 'The new version didn’t start properly, so the previous version is running again.';
 return r.split(/[;.]/)[0]+'.'}
function installed(a){return a.installed!=null&&a.managed}
function chip(a){const m={'Up to date':['Installed','ok'],'Update available':['Update available','warn'],'Updating…':['Updating','info'],'Failed':['Failed','bad'],
 'Not installed':['Not installed',''],'Updates itself':['Updates itself',''],'Not in the feed':['Installed','ok']}[a.status]||[a.status,''];
 if(!a.managed)return el('span',{class:'chip'},a.available?'Not installed':'Not available');return el('span',{class:'chip '+m[1]},m[0])}
function versionLine(a){if(a.installed&&a.available&&a.installed!=a.available&&a.status!='Updates itself')return el('span',{class:'ver'},a.installed+' → ',el('b',{},a.available));
 const v=a.installed||a.available;return v?el('span',{class:'ver'},el('b',{},v)):null}
function mainAction(a){if(a.status=='Updating…')return null;
 if(a.statusOnly)return a.setup?['Open Setup Folder','setup','']:(a.open?['Open','open','']:null);
 if(!a.managed||a.installed==null)return a.available?['Install','install','primary']:null;
 if((a.status=='Update available'||a.status=='Failed')&&a.available)return ['Update','update','primary'];
 return a.open&&!a.helper?['Open','open','']:null}
function progress(a){const p=a.progress||{},box=el('div',{class:'prog'});let line,bar;
 if(p.done!=null&&p.total>0){const pct=Math.min(100,Math.round(p.done/p.total*100));line=(p.paused?'Paused · ':'Downloading ')+mb(p.done)+' of '+mb(p.total)+' · '+pct+'%';bar=el('div',{class:'bar'},el('i',{style:'width:'+pct+'%'}))}
 else if(p.copying){line='Copying from '+p.copying;bar=el('div',{class:'bar loose'},el('i'))}else{line='Installing…';bar=el('div',{class:'bar loose'},el('i'))}
 box.append(el('span',{class:'line num'},line),bar);
 const ctl=el('div',{class:'foot',style:'margin:0'},box);
 if(p.done!=null){ctl.append(el('button',{class:'btn icon',title:p.paused?'Resume':'Pause','aria-label':p.paused?'Resume':'Pause',onclick:e=>{e.stopPropagation();post({action:'pause',on:!p.paused})}},
   svg(p.paused?'M5 3.5v9l7-4.5z':'M5 3.5v9M11 3.5v9')),el('button',{class:'btn icon',title:'Cancel','aria-label':'Cancel',onclick:e=>{e.stopPropagation();post({action:'cancel'})}},svg('M4 4l8 8M12 4l-8 8')))}
 return ctl}
function svg(d){const s=document.createElementNS('http://www.w3.org/2000/svg','svg');s.setAttribute('viewBox','0 0 16 16');const p=document.createElementNS('http://www.w3.org/2000/svg','path');
 p.setAttribute('d',d);p.setAttribute('fill',d.includes('z')?'currentColor':'none');p.setAttribute('stroke','currentColor');p.setAttribute('stroke-width','1.8');p.setAttribute('stroke-linecap','round');s.append(p);return s}
function icon(a){return a.icon?el('img',{src:a.icon,alt:''}):el('div',{class:'ph','aria-hidden':true},svg('M3 3h4v4H3zM9 3h4v4H9zM3 9h4v4H3zM9 9h4v4H9z'))}
function buttons(a,big){const out=[],m=mainAction(a);
 if(a.status=='Updating…'&&!big)return [progress(a)];
 if(m)out.push(el('button',{class:'btn main '+m[2],onclick:e=>{e.stopPropagation();post({action:m[1],app:a.id})}},m[0]));
 out.push(el('button',{class:'btn icon',title:'More','aria-label':'More for '+a.name,'aria-haspopup':'menu',onclick:e=>{e.stopPropagation();openMenu(a,e.currentTarget)}},svg('M3.5 8h.01M8 8h.01M12.5 8h.01')));return out}
function card(a){const tag=a.tagline||a.description||(a.statusOnly?'Updates itself from its own installer.':null);
 const when=installed(a)?day(a.installedAt):day(a.released);
 const c=el('article',{class:'card click',style:a.accent?'--app:'+a.accent:null,onclick:()=>openDetail(a.id),tabindex:0,onkeydown:e=>{if(e.key=='Enter')openDetail(a.id)}},
  el('div',{class:'head'},icon(a),el('div',{class:'t'},el('div',{class:'name'},a.name),tag?el('div',{class:'tag'},tag):null)),
  el('div',{class:'meta'},chip(a),versionLine(a)),
  a.status=='Failed'&&a.reason?el('div',{class:'reason'},plain(a.reason)):null,
  when?el('div',{class:'when'},(installed(a)?'Last updated ':'Released ')+when):null,
  el('div',{class:'foot'},...buttons(a)));return c}
function tableOf(list){return el('table',{},el('thead',{},el('tr',{},el('th',{},'App'),el('th',{},'Status'),el('th',{},'Version'),el('th',{},'Updated'),el('th',{},''))),
 el('tbody',{},list.map(a=>el('tr',{onclick:()=>openDetail(a.id),style:(a.accent?'--app:'+a.accent+';':'')+'cursor:pointer'},
  el('td',{},el('div',{class:'head'},icon(a),el('div',{class:'t'},el('div',{class:'name'},a.name),a.tagline?el('div',{class:'tag'},a.tagline):null))),
  el('td',{},chip(a)),el('td',{},versionLine(a)),el('td',{class:'when num'},day(installed(a)?a.installedAt:a.released)||'—'),
  el('td',{class:'act'},a.status=='Updating…'?el('div',{style:'min-width:240px'},progress(a)):buttons(a))))))}
function visible(){const hidden=S.apps.filter(a=>a.hidden);let list=S.apps.filter(a=>showHidden||!a.hidden);
 if(q)list=list.filter(a=>(a.name+' '+(a.tagline||'')).toLowerCase().includes(q));
 const key=a=>new Date(installed(a)?a.installedAt||0:a.released||0).getTime();
 list.sort(sort=='recent'?(x,y)=>key(y)-key(x):(x,y)=>x.name.localeCompare(y.name));return [list,hidden]}
function render(state){if(state)Object.assign(S,state);
 const [list,hidden]=visible(),mine=list.filter(installed),others=list.filter(a=>!installed(a));
 const n=S.apps.filter(a=>a.managed&&!a.statusOnly&&a.status=='Update available').length;
 $('all').hidden=n==0;$('all').textContent='Update all ('+n+')';
 $('vgrid').setAttribute('aria-pressed',view=='grid');$('vlist').setAttribute('aria-pressed',view=='list');$('sort').value=sort;
 const m=$('main');m.replaceChildren();
 if(!S.apps.length)m.append(el('p',{class:'empty'},'Checking…'));
 else if(!list.length)m.append(el('p',{class:'empty'},'No app matches “'+q+'”.'));
 for(const [title,group] of [['Installed',mine],['Not installed',others]]){if(!group.length)continue;
  m.append(el('h2',{},title+' · '+group.length),view=='grid'?el('div',{class:'grid'},group.map(card)):tableOf(group))}
 $('checked').textContent=ago(S.lastRun)+' · Feed'+(S.sources.length?' + '+S.sources.join(', '):'')+(S.paused?' · Automatic updates paused':'');
 $('hiddenNote').replaceChildren(hidden.length?el('button',{class:'link',onclick:()=>{showHidden=!showHidden;render()}},showHidden?'Hide hidden apps':hidden.length+' hidden · Show'):'');
 $('err').textContent=S.error?'Last check failed: '+S.error:'';
 document.documentElement.style.colorScheme=S.settings.appearance=='dark'?'dark':S.settings.appearance=='light'?'light':'light dark';
 if(detail)drawDetail();if(settingsOpen)drawSettings()}
function closeLayers(){document.querySelectorAll('.scrim,.menu').forEach(x=>x.remove())}
function openMenu(a,anchor){document.querySelectorAll('.menu').forEach(x=>x.remove());const items=[];
 const add=(label,action,cls)=>items.push(el('button',{class:cls||'',role:'menuitem',onclick:()=>{m.remove();action()}},label));
 if(a.notes&&a.notes.length)add('Release notes',()=>openDetail(a.id,true));
 if(a.open&&!a.helper){add('Open',()=>post({action:'open',app:a.id}));add('Show in Finder',()=>post({action:'finder',app:a.id}))}
 if(a.managed&&a.installed&&a.available&&!a.statusOnly&&!a.helper)add('Reinstall',()=>post({action:'reinstall',app:a.id}));
 if(a.canRollBack)add('Roll back to the previous version',()=>post({action:'rollback',app:a.id}));
 if(a.status=='Failed'&&a.reason)add('Copy error report',()=>post({action:'copyReport',app:a.id}));
 if(a.managed&&!a.statusOnly){items.push(el('hr'));items.push(el('button',{role:'menuitemcheckbox','aria-checked':a.automatic,onclick:()=>{m.remove();post({action:'automatic',app:a.id,on:!a.automatic})}},el('span',{class:'check'},a.automatic?svg('M3.5 8.5l3 3 6-7'):''),'Update automatically'))}
 items.push(el('hr'));
 if(a.open&&!a.helper)add('Uninstall…',()=>post({action:'uninstall',app:a.id}),'danger');
 add(a.hidden?'Show app':'Hide app',()=>post({action:a.hidden?'unhide':'hide',app:a.id}));
 const m=el('div',{class:'menu',role:'menu'},items);document.body.append(m);
 const r=anchor.getBoundingClientRect(),w=m.offsetWidth,h=m.offsetHeight;
 m.style.left=Math.max(8,Math.min(innerWidth-w-8,r.right-w))+'px';m.style.top=(r.bottom+h+8>innerHeight?r.top-h-4:r.bottom+4)+'px';m.querySelector('button')?.focus()}
function openDetail(id,notes){detail={id,notes};drawDetail()}
function drawDetail(){const list=visible()[0],i=list.findIndex(a=>a.id==detail.id),a=list[i]||S.apps.find(x=>x.id==detail.id);if(!a){detail=null;return}
 document.querySelectorAll('.scrim.d').forEach(x=>x.remove());
 const step=d=>{const n=list[(i+d+list.length)%list.length];if(n){detail={id:n.id};drawDetail()}};
 const facts=[['Version',a.available||a.installed],['Released',day(a.released)],['Size',mb(a.bytes)],['From',a.fromSSD||(a.source||null)]].filter(f=>f[1]);
 const notes=a.notes||[],limit=showAll[a.id]?notes.length:5;
 const sheet=el('div',{class:'sheet',role:'dialog','aria-modal':true,'aria-label':a.name,style:a.accent?'--app:'+a.accent:null,onclick:e=>e.stopPropagation()},
  el('div',{class:'top'},icon(a),el('div',{class:'t'},el('h3',{},a.name),a.tagline?el('div',{class:'sub'},a.tagline):null,
    el('div',{class:'meta',style:'margin-top:8px'},chip(a),versionLine(a),a.released?el('span',{class:'when'},'· '+day(a.released)):null),
    a.status=='Failed'&&a.reason?el('div',{class:'reason',style:'margin-top:6px'},plain(a.reason)):null,
    a.status=='Updating…'?el('div',{style:'margin-top:10px;max-width:420px'},progress(a)):el('div',{class:'foot',style:'margin-top:12px;max-width:340px'},...buttons(a,true))),
   el('div',{class:'nav'},el('button',{class:'btn icon',title:'Previous app','aria-label':'Previous app',onclick:()=>step(-1)},svg('M10 3 5 8l5 5')),
    el('button',{class:'btn icon',title:'Next app','aria-label':'Next app',onclick:()=>step(1)},svg('M6 3l5 5-5 5')),
    el('button',{class:'btn icon',title:'Close','aria-label':'Close',onclick:()=>{detail=null;closeLayers()}},svg('M4 4l8 8M12 4l-8 8')))),
  el('div',{class:'cols'},
   el('div',{},a.description?el('p',{class:'desc'},a.description):el('p',{class:'desc sub'},a.statusOnly?'This app updates itself from its own installer. Its setup folder on the SSD has the steps.':'No description yet.'),
    a.features&&a.features.length?[el('h4',{},'Features'),el('ol',{class:'feat'},a.features.map(f=>el('li',{},el('b',{},f.title),f.text?el('span',{},f.text):null)))]:null),
   el('div',{},facts.length?[el('h4',{},'Latest release'),el('dl',{class:'facts'},facts.map(f=>el('div',{},el('dt',{},f[0]),el('dd',{class:'num'},f[1]))))]:null,
    el('h4',{id:'changes'},'What’s changed'),notes.length?el('ul',{class:'changes'},notes.slice(0,limit).map(n=>el('li',{},n))):el('p',{class:'sub'},'No notes for this version.'),
    notes.length>5?el('button',{class:'more',onclick:()=>{showAll[a.id]=!showAll[a.id];drawDetail()}},showAll[a.id]?'Show fewer':'Show '+(notes.length-5)+' more'):null)));
 const scrim=el('div',{class:'scrim d',onclick:()=>{detail=null;closeLayers()}},sheet);document.body.append(scrim);
 if(detail.notes){detail.notes=false;sheet.querySelector('#changes').scrollIntoView({block:'center'})}}
function drawSettings(){document.querySelectorAll('.scrim.s').forEach(x=>x.remove());const s=S.settings,c=S.connection||{destination:'',machine:''};
 const set=(key,value)=>post({action:'setting',key,value});
 const check=(key,label,on,note,disabled)=>el('div',{},el('div',{class:'row'+(disabled?' dis':'')},el('label',{},el('input',{type:'checkbox',checked:on,disabled,onchange:e=>set(key,e.target.checked)}),label)),note?el('p',{class:'note'},note):null);
 const seg=(key,opts,cur)=>el('div',{class:'seg',role:'group'},opts.map(([v,l])=>el('button',{'aria-pressed':String(cur==v),onclick:()=>set(key,v)},l)));
 const connStatus=()=>c.checking?el('p',{class:'note',style:'margin-left:0'},'Checking the connection…')
  :c.note?el('p',{style:'color:var(--bad);font-size:12px;margin:6px 0 0'},c.note)
  :(c.ok&&c.checkedAt)?el('div',{class:'meta',style:'margin-top:6px'},el('span',{class:'chip ok'},'Connected'),el('span',{class:'when num'},ago(c.checkedAt)))
  :el('p',{class:'note',style:'margin-left:0'},'Not checked yet.');
 const chInput=el('input',{type:'text',value:c.destination||'',placeholder:'http://100.64.0.7:8790/release.json','aria-label':'Update Studio address'});
 const connSection=el('section',{},el('h4',{},'Connection'),
  el('div',{class:'row'},el('span',{},'Update Studio'),el('span',{class:'ver'},c.destination)),
  el('div',{class:'row'},el('span',{},'This Mac'),el('span',{},c.machine)),
  connStatus(),
  el('div',{class:'row'},el('button',{class:'btn',disabled:!!c.checking,onclick:()=>post({action:'connectionCheck'})},c.checking?'Checking…':'Check connection')),
  // Offered only after a check the publisher refused with 401/403 (pairAvailable); the
  // confirmation and the pairing code are collected by the native window that follows.
  c.pairAvailable?el('div',{class:'row'},el('button',{class:'btn',disabled:!!c.checking,onclick:()=>post({action:'pairAgain'})},'Pair again now')):null,
  el('div',{class:'row'},chInput,el('button',{class:'btn',disabled:!!c.checking,onclick:()=>post({action:'changeServer',value:chInput.value})},'Use this address')),
  el('p',{class:'note',style:'margin-left:0'},'This Mac only accepts an address where Update Studio serves the updates its own key already signed. A different Update Studio needs its setup kit, not an address.'),
  c.serverNote?el('p',{style:'font-size:12px;margin:6px 0 0;color:'+(c.serverOk?'var(--ok)':'var(--bad)')},c.serverNote):null);
 const updater=S.apps.find(a=>a.id=='updater');
 const sheet=el('div',{class:'sheet set',role:'dialog','aria-modal':true,'aria-label':'Settings',onclick:e=>e.stopPropagation()},
  el('div',{class:'top'},el('div',{class:'t'},el('h3',{},'Settings'),el('div',{class:'sub'},'Studio Launcher KH '+S.version))),
  el('div',{class:'body'},
   el('section',{},el('h4',{},'Updates'),el('div',{class:'row'},el('span',{},'Check for updates'),seg('checkManually',[[false,'Automatically'],[true,'Manually']],s.checkManually)),
    check('autoInstall','Install updates automatically',s.autoInstall&&!s.checkManually,s.checkManually?'Off while checking manually. Use Check for updates now, then Update.':'Each app’s own switch is in its … menu.',s.checkManually),
    check('notify','Notify me when an update is ready',s.notify,null),
    // The updater's own switch is live data, and its automatic-on-connect default is stated, not implied.
    updater?check('updaterAutomatic','Update Studio KH updates itself automatically',!!updater.automatic,'Automatic is on when a Mac connects; change it in Update Studio KH’s … menu.',true):null),
   connSection,
   el('section',{},el('h4',{},'Appearance'),seg('appearance',[['system','Match system'],['dark','Dark'],['light','Light']],s.appearance)),
   el('section',{},el('h4',{},'In the background'),check('menuBarWhenClosed','Keep the icon in the menu bar when this window is closed',s.menuBarWhenClosed,null),
    check('login','Start at login',true,'Always on: the helper starts at login so this Mac keeps getting updates.',true)),
   el('section',{},el('h4',{},'What’s new in '+S.version),S.whatsNew.length?el('ul',{class:'changes'},S.whatsNew.map(n=>el('li',{},n))):el('p',{class:'sub'},'No notes.'))),
  el('div',{class:'bottom'},el('button',{class:'btn primary',onclick:()=>{settingsOpen=false;closeLayers()}},'Done')));
 document.body.append(el('div',{class:'scrim s',onclick:()=>{settingsOpen=false;closeLayers()}},sheet))}
$('vgrid').onclick=()=>{view='grid';store.set('view',view);render()};$('vlist').onclick=()=>{view='list';store.set('view',view);render()};
$('sort').onchange=e=>{sort=e.target.value;store.set('sort',sort);render()};$('q').oninput=e=>{q=e.target.value.trim().toLowerCase();render()};
$('all').onclick=()=>post({action:'updateAll'});$('check').onclick=()=>post({action:'check'});$('gear').onclick=()=>{settingsOpen=true;drawSettings()};
document.addEventListener('click',e=>{if(!e.target.closest('.menu'))document.querySelectorAll('.menu').forEach(x=>x.remove())});
document.addEventListener('keydown',e=>{if(e.key=='Escape'){if(document.querySelector('.menu'))document.querySelectorAll('.menu').forEach(x=>x.remove());else{detail=null;settingsOpen=false;closeLayers()}}
 if(detail&&!settingsOpen&&(e.key=='ArrowRight'||e.key=='ArrowLeft')){const l=visible()[0],i=l.findIndex(a=>a.id==detail.id),n=l[(i+(e.key=='ArrowRight'?1:-1)+l.length)%l.length];if(n){detail={id:n.id};drawDetail()}}
 if((e.metaKey&&e.key=='f')){e.preventDefault();$('q').focus()}});
setInterval(()=>{if(S.lastRun)$('checked').textContent=ago(S.lastRun)+' · Feed'+(S.sources.length?' + '+S.sources.join(', '):'')},30000);
</script></body></html>
"""#
}
