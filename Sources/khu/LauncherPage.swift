// The Studio Launcher KH page. Same tokens as Update Studio KH's page, so the suite reads as one.
// Every value from the feed or an SSD is set as text, never parsed as HTML.
enum LauncherPage {
    static let html = #"""
<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https://github.com https://raw.githubusercontent.com; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
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
header{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:12px;padding:14px 22px;background:var(--panel);border-bottom:1px solid var(--line);flex-wrap:wrap;min-width:0}
.viewTools{display:flex;gap:12px;align-items:center;margin-left:auto}
.brand{display:flex;align-items:center;gap:10px;margin-right:auto;min-width:0;flex-wrap:wrap}.brand svg{width:30px;height:30px;flex:none}.brand h1{font-size:16px;margin:0;letter-spacing:-.015em}.brand p{margin:0;font-size:12px;color:var(--sub)}
.btn{height:30px;padding:0 13px;border-radius:7px;border:1px solid var(--line);background:var(--panel);font-weight:550;white-space:nowrap}
.btn:hover:not(:disabled){border-color:var(--field)}.btn:active:not(:disabled){transform:translateY(.5px)}.btn:disabled{opacity:.45}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}.btn.primary:hover:not(:disabled){filter:brightness(1.07)}
.btn.icon{width:30px;padding:0;display:inline-grid;place-items:center}.btn.icon svg{width:15px;height:15px}
.btn.danger{color:var(--bad)}
.seg{display:inline-flex;padding:2px;background:var(--muted-bg);border-radius:8px;gap:2px}.seg button{height:26px;min-width:30px;padding:0 9px;border:0;border-radius:6px;background:none;color:var(--sub);display:inline-grid;place-items:center}
.seg button[aria-pressed=true]{background:var(--panel);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.12)}.seg svg{width:14px;height:14px}
select,input[type=search]{height:30px;border:1px solid var(--line);border-radius:7px;background:var(--panel);padding:0 9px}input[type=search]{width:190px}
.set input[type=text]{flex:1;min-width:0;height:30px;border:1px solid var(--line);border-radius:7px;background:var(--panel);padding:0 9px;font:12px/1.4 ui-monospace,Menlo,monospace}
input::placeholder{color:var(--sub)}input,textarea{cursor:text;-webkit-user-select:text;caret-color:var(--accent)}
main{flex:1;padding:18px 22px 8px}
/* One row of sections across the top at any width where all eight fit; below that it wraps rather
   than scrolls, so no section is ever hidden behind a sideways swipe. */
.tabs{display:flex;flex-wrap:wrap;gap:6px;padding:8px 14px;background:var(--panel);border-bottom:1px solid var(--line)}
/* A tab is a control, not a word on a line: its own 32px target, a 6px gap, and the selected one
   filled with the accent the owner chose (2026-11-24). The fill is the cue, so the underline is
   gone; the accent appears on the selected tab only, never on hover. */
.tabs [role=tab]{height:32px;padding:0 14px;border:1px solid transparent;border-radius:6px;background:none;color:var(--sub);font-weight:600;white-space:nowrap;flex:none}
.tabs [role=tab]:hover{color:var(--text);background:var(--muted-bg)}
.tabs [role=tab][aria-selected=true]{background:var(--accent);border-color:var(--accent);color:var(--accent-ink);box-shadow:0 1px 2px rgba(0,0,0,.16)}
@media (max-width:520px){.tabs{gap:6px;padding:6px 10px}.tabs [role=tab]{height:32px;padding:0 12px}}
.tabnote{margin:0;padding:8px 22px;color:var(--sub);font-size:12.5px;background:var(--panel);border-bottom:1px solid var(--line2)}
#extPanel p{margin:8px 0;color:var(--sub);overflow-wrap:anywhere}
.extRow{display:flex;justify-content:space-between;align-items:center;gap:8px 16px;flex-wrap:wrap;padding:10px 0;border-bottom:1px solid var(--line)}
.extRow p{margin:2px 0 0}.extRow strong{overflow-wrap:anywhere}.extRow .btn{flex:none}
h2{font-size:13px;font-weight:600;margin:22px 0 10px;color:var(--sub)}h2:first-child{margin-top:4px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:12px}
.card.selected{outline:2px solid var(--accent);outline-offset:2px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:15px 16px 14px;display:flex;flex-direction:column;gap:10px;min-height:196px;transition:border-color .15s}
.card:hover{border-color:var(--field)}.card.click{cursor:pointer}
.head{display:flex;gap:12px;align-items:center}.head img,.ph{width:46px;height:46px;flex:none;border-radius:11px}.ph{background:var(--muted-bg);display:grid;place-items:center;color:var(--sub)}
.head .t{min-width:0}.name{font-weight:650;font-size:14.5px;letter-spacing:-.012em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tag{color:var(--sub);font-size:12.5px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.meta{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.chip{font-size:11.5px;font-weight:600;padding:2px 8px;border-radius:99px;background:var(--muted-bg);color:var(--sub);white-space:nowrap}
.chip.ok{background:var(--ok-bg);color:var(--ok)}.chip.warn{background:var(--warn-bg);color:var(--warn)}.chip.bad{background:var(--bad-bg);color:var(--bad)}.chip.info{background:var(--info-bg);color:var(--info)}
.reason{color:var(--bad);font-size:12px;display:block;overflow-wrap:anywhere}
.src{color:var(--sub);font-size:12px;margin-top:6px;overflow-wrap:anywhere}
.when{font-size:12px;color:var(--sub)}
.foot{margin-top:auto;display:flex;gap:8px;align-items:center}.foot .main{flex:1}
.prog{flex:1;display:flex;flex-direction:column;gap:6px}.prog .line{font-size:12px}.bar{height:4px;border-radius:4px;background:var(--line2);overflow:hidden}
.bar i{display:block;height:100%;background:var(--app,var(--accent));border-radius:4px;transition:width .4s cubic-bezier(.16,1,.3,1)}
.bar.loose i{width:35%;animation:loose 1.4s cubic-bezier(.45,0,.55,1) infinite}@keyframes loose{0%{transform:translateX(-100%)}100%{transform:translateX(290%)}}
@media (prefers-reduced-motion:reduce){.bar.loose i{animation:none;width:100%;opacity:.5}}
.tablewrap{overflow-x:auto;max-width:100%}table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
th{font-size:11.5px;font-weight:600;color:var(--sub);text-align:left;padding:9px 14px;border-bottom:1px solid var(--line)}
td{padding:9px 14px;border-bottom:1px solid var(--line2);vertical-align:middle}tr:last-child td{border-bottom:0}tbody tr:hover{background:var(--line2)}tbody tr[aria-selected=true]{background:var(--ok-bg)}
td .head img,td .ph{width:32px;height:32px;border-radius:8px}td .name{font-size:13.5px}td.act{width:1%;white-space:nowrap;text-align:right}td.act .btn+.btn{margin-left:6px}
footer{position:sticky;bottom:0;display:flex;gap:8px;align-items:center;padding:8px 18px;font-size:12px;color:var(--sub);background:var(--bg);border-top:1px solid var(--line)}
footer .link{background:none;border:0;color:var(--accent);padding:0;cursor:pointer;white-space:nowrap}footer .stat{font-size:12px;color:var(--sub);min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}footer .stat.err{color:var(--bad);font-weight:550}#checked{white-space:normal;overflow-wrap:anywhere}
footer .btn{height:26px;min-height:26px;padding:0 10px;font-size:12px}footer .btn.icon{width:26px;padding:0}footer .btn.icon.upd{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.pill{display:inline-flex;align-items:center;gap:5px;height:26px;min-height:26px;min-width:0;padding:0 9px;border-radius:999px;border:1px solid var(--line);background:var(--panel);color:var(--text);font-size:11px;font-weight:550;cursor:pointer;white-space:nowrap;flex:none}
.pill:hover{border-color:var(--field)}.pill .v{font:10px/1 ui-monospace,Menlo,monospace;color:var(--sub);font-variant-numeric:tabular-nums}
header .link{background:none;border:0;color:var(--accent);padding:0 4px;cursor:pointer;font-size:12px;white-space:nowrap}
.empty{padding:40px 0;text-align:center;color:var(--sub)}
.scrim{position:fixed;inset:0;background:rgba(10,18,15,.32);z-index:10;display:flex;justify-content:center;align-items:flex-start;padding:34px 24px;overflow:auto}
@media (prefers-color-scheme:dark){.scrim{background:rgba(0,0,0,.5)}}
.sheet{background:var(--panel);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);width:min(920px,100%);animation:rise .22s cubic-bezier(.16,1,.3,1);max-height:calc(100dvh - 68px);overflow:auto}
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
.menu .why{margin:0 10px 5px 32px;font-size:11.5px;line-height:1.35;color:var(--sub)}
.set{width:min(640px,100%)}.set .body{padding:6px 24px 22px}.set section{padding:14px 0;border-bottom:1px solid var(--line2)}.set section:last-child{border-bottom:0}
.set h4{margin-bottom:12px}.row{display:flex;justify-content:space-between;align-items:center;gap:16px;margin:8px 0}
.set details{margin:12px 0 0}.set summary{cursor:pointer;font-weight:600;color:var(--sub);font-size:12.5px;padding:4px 0}
.row label{display:flex;gap:9px;align-items:flex-start}.row input[type=checkbox]{accent-color:var(--accent);width:15px;height:15px;margin:1px 0 0}
.note{font-size:12px;color:var(--sub);margin:2px 0 0 24px}.dis{opacity:.5}
.bottom{display:flex;justify-content:flex-end;padding:14px 24px;border-top:1px solid var(--line);position:sticky;bottom:0;background:var(--panel);z-index:1}
.wn{width:min(460px,100%)}.wn .body{padding:16px 24px 4px}.wn .body .sub{margin:0}
.notice{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:14px 24px 0;padding:10px 14px;border:1px solid var(--line);border-radius:10px;background:var(--panel)}
.adopt{margin:14px 24px 0;padding:12px 14px;border:1px solid var(--line);border-radius:10px;background:var(--panel)}
.extRow{margin:10px 24px;display:flex;gap:12px;align-items:flex-start}
.extTile{padding:12px;border:1px solid var(--line);border-radius:10px;background:var(--panel);flex-wrap:wrap}
.extBody{flex:1;min-width:180px}
.extIcon,.extShot{display:grid;place-items:center;overflow:hidden;background:var(--bg);border:1px solid var(--line);border-radius:8px;flex:none}
.extIcon{width:40px;height:40px;font-size:15px;color:var(--sub)}
.extShot{width:200px;height:112px;font-size:11px;color:var(--sub)}
.extIcon .ph,.extShot .ph{display:grid;place-items:center;width:100%;height:100%;font-size:14px;color:var(--sub)}
.extShot .ph{font-size:11px}
.extIcon img,.extShot img{max-width:100%;max-height:100%;display:block}
.extNote{margin:4px 0 0}
.adopt .row{display:flex;gap:10px;align-items:center;padding:6px 0;flex-wrap:wrap}
.adopt code{font-size:12px;color:var(--sub);word-break:break-all}
@media (max-width:820px){input[type=search]{width:130px}.cols{grid-template-columns:1fr}.brand p{display:none}#hiddenNote{display:none}footer{flex-wrap:wrap;min-width:0}}
</style></head><body>
<header>
 <div class=brand><svg viewBox="0 0 32 32" aria-hidden=true><rect width=32 height=32 rx=8 fill="var(--accent)"/><g fill="#fff"><rect x=8 y=8 width=7 height=7 rx=1.8 /><rect x=17 y=8 width=7 height=7 rx=1.8 /><rect x=8 y=17 width=7 height=7 rx=1.8 /><rect x=17 y=17 width=7 height=7 rx=1.8 /></g></svg>
 <div><h1>Studio Launcher KH</h1><p id=mac>Apps for this Mac</p></div></div>
 <button class="btn primary" id=all hidden></button>
 <label class=sr for=sort>Sort</label><select id=sort aria-label="Sort"><option value=name>Name</option><option value=type>Type</option><option value=recent>Recently updated</option></select>
 <input type=search id=q placeholder="Search apps" aria-label="Search apps">
 <div class=viewTools><div class=seg id=viewseg role=group aria-label="View"><button id=vgrid title="Grid" aria-label="Grid"><svg viewBox="0 0 16 16" fill=currentColor><rect x=1 y=1 width=6 height=6 rx=1.5 /><rect x=9 y=1 width=6 height=6 rx=1.5 /><rect x=1 y=9 width=6 height=6 rx=1.5 /><rect x=9 y=9 width=6 height=6 rx=1.5 /></svg></button><button id=vlist title="List" aria-label="List"><svg viewBox="0 0 16 16" fill=currentColor><rect x=1 y=2 width=14 height=2.4 rx=1.2 /><rect x=1 y=6.8 width=14 height=2.4 rx=1.2 /><rect x=1 y=11.6 width=14 height=2.4 rx=1.2 /></svg></button></div>
 <button class="btn" id=check title="Check the saved feed and scan for installer drives" aria-label="Check the saved feed and scan for installer drives">Check sources</button><span id=hiddenNote></span><button class="btn icon" id=gear title="Settings" aria-label="Settings"><svg viewBox="0 0 16 16" fill=none stroke=currentColor stroke-width=1.6 stroke-linecap=round><path d="M2 4.5h7M12.5 4.5H14M2 11.5h2M7.5 11.5H14"/><circle cx=10.8 cy=4.5 r=1.7 /><circle cx=5.8 cy=11.5 r=1.7 /></svg></button>
 </div>
</header>
<nav class=tabs id=tabs role=tablist aria-label="Sections"></nav>
<p class=tabnote id=tabNote hidden role=status></p>
<div id=notices hidden></div>
<section id=adoptions hidden></section>
<main id=main role=tabpanel></main>
<footer><button class=pill id=whatsNew title="What’s New in Studio Launcher KH"><span>Studio Launcher KH</span><span class=v id=wnver></span></button><button class="btn icon upd" id=update hidden title="Update Studio Launcher KH" aria-label="Update Studio Launcher KH"><svg viewBox="0 0 16 16" fill=none stroke=currentColor stroke-width=1.7 stroke-linecap=round stroke-linejoin=round><path d="M8 2.6v6.2M5.2 6.2 8 9l2.8-2.8M2.8 11.4v1.6h10.4v-1.6"/></svg></button><button class=pill id=auto aria-pressed=false hidden></button><span id=checked class=stat></span><span id=err class="stat err" role=status aria-live=polite></span><button class=link id=support style="margin-left:auto" aria-label="Support this app">♡ Support this app</button></footer>
<script>
const S={apps:[],sources:[],settings:{}},post=m=>window.webkit.messageHandlers.khu.postMessage(m);
window.onerror=(msg,src,line)=>post({action:'log',text:msg+' (line '+line+')'});
// The page has no origin of its own, so storage may refuse; the choice then lasts while the window is open.
const store={get:k=>{try{return localStorage.getItem(k)}catch(e){return null}},set:(k,v)=>{try{localStorage.setItem(k,v)}catch(e){}}};
let view=store.get('view')||'grid',viewFromMac=false,sort=store.get('sort')||'name',tab=store.get('tab')||'all',q='',detail=null,settingsOpen=false,whatsNewOpen=false,showHidden=false,showAll={},joinAddr=null,joinCode=null,selected=new Set();
const $=id=>document.getElementById(id);
function el(tag,attrs,...kids){const e=document.createElement(tag);for(const k in attrs||{}){const v=attrs[k];if(v==null||v===false)continue;
 if(k=='class')e.className=v;else if(k.startsWith('on'))e.addEventListener(k.slice(2),v);else if(k=='style')e.style.cssText=v;else e.setAttribute(k,v===true&&!k.startsWith('aria-')?'':String(v))}
 for(const c of kids.flat()){if(c==null||c===false)continue;e.append(c.nodeType?c:document.createTextNode(String(c)))}return e}
const day=iso=>{if(!iso)return null;const d=new Date(iso);return isNaN(d)?null:d.toLocaleDateString(undefined,{month:'short',day:'numeric',year:'numeric'})};
const mb=b=>b==null?null:(b>=1e9?(b/1e9).toFixed(1)+' GB':b>=1e6?Math.round(b/1e6)+' MB':b>=1e3?Math.round(b/1e3)+' KB':b+' B');
function ago(iso){const s=(Date.now()-new Date(iso))/1000;return s<60?'just now':s<3600?Math.round(s/60)+' min ago':Math.round(s/3600)+' h ago'}
// A failure in plain words; the Mac's own text stays in Copy error report.
function plain(r){if(!r)return '';const t=r.toLowerCase();
 if(t.includes('hdiutil')||t.includes('image not recognized')||t.includes('no mountable'))return 'The installer file couldn’t be opened. It may be damaged; try Update again.';
 if(t.includes('does not match its checksum'))return 'The copy on the SSD doesn’t match its checksum, so it wasn’t used. Try the SSD again or update from the feed.';
 if(t.includes('dmg holds')||t.includes('this mac\'s app is'))return 'The installer holds a different app than the one on this Mac. Nothing was changed.';
 if(t.includes('cancelled on this mac'))return 'Cancelled. Nothing was changed.';
 if(t.includes('the install did not finish, and the system gave no reason'))return 'The download didn’t finish. Check the network and try Update again.';
 if(t.includes('not healthy')||t.includes('rolled back'))return 'The new version didn’t start properly, so the previous version is running again.';
 // The Mac's own sentence, kept whole when it is short enough to read. Otherwise its first clause
 // is kept, cut only at a real boundary — never inside parentheses (a job label such as
 // com.example.helper) and never mid-word, so "what happened" stays answerable.
 const text=String(r).trim();
 if(text.length<=240)return /[.!?]$/.test(text)?text:text+'.';
 let depth=0,end=text.length;
 for(let i=0;i<text.length;i++){const ch=text[i];
  if(ch==='(')depth++;else if(ch===')')depth=Math.max(0,depth-1);
  else if(depth===0&&(ch===';'||ch==='.')&&(i+1===text.length||text[i+1]===' ')){end=i;break}}
 const first=text.slice(0,end).trim();
 return (first||text).replace(/[.;,]+$/,'')+'.'}
function installed(a){return a.installed!=null&&a.managed}
function chip(a){const m={'Up to date':['Installed','ok'],'Update available':['Update available','warn'],'Updating…':['Updating','info'],'Receiving update…':['Receiving update…','info'],
 'Downloaded':['Downloaded','info'],'Failed':['Failed','bad'],'Needs attention':['Needs attention','bad'],'Not installed':['Not installed',''],'Updates itself':['Updates itself',''],'Not in the feed':['Installed','ok']}[a.status]||[a.status,''];
 if(!a.managed)return el('span',{class:'chip'},a.available?'Not installed':'Not available');return el('span',{class:'chip '+m[1]},m[0])}
function versionLine(a){if(a.installed&&a.available&&a.installed!=a.available&&a.status!='Updates itself')return el('span',{class:'ver'},a.installed+' → ',el('b',{},a.available));
 const v=a.installed||a.available;return v?el('span',{class:'ver'},el('b',{},v)):null}
function mainAction(a){if(a.status=='Updating…'||a.status=='Receiving update…')return null;
 // Nothing is offered when the agent has no recipe it would really run for this app.
 if(!a.installable&&!a.statusOnly&&!a.managed)return null;
 if(a.statusOnly){
  // An app that updates itself is never installed by KH Updater on its own, but the person at
  // this Mac may install or update it here, by choosing it.
  if(a.manuallyInstallable&&a.available&&!a.installed)return ['Install','install','primary'];
  // The agent already compared the versions: only a real offer becomes a button, so a newer or
  // incomparable installed build keeps "Updates itself" instead of a dead Update.
  if(a.manuallyInstallable&&a.available&&(a.status=='Update available'||a.status=='Failed'||a.status=='Downloaded'))return ['Update','update','primary'];
  return a.setup?['Open Setup Folder','setup','']:(a.open?['Open','open','']:null);
 }
 if(!a.managed||a.installed==null)return a.available?['Install','install','primary']:null;
 if((a.status=='Update available'||a.status=='Failed'||a.status=='Downloaded')&&a.available)return ['Update','update','primary'];
 return a.open&&!a.helper?['Open','open','']:null}
function progress(a){const p=a.progress||{},box=el('div',{class:'prog','data-prog':a.id});
 box.append(el('span',{class:'line num'}),el('div',{class:'bar'},el('i')));paint(box,p);
 const ctl=el('div',{class:'foot',style:'margin:0'},box);
 if(p.done!=null&&!p.cancelled){ctl.append(el('button',{class:'btn icon',title:p.paused?'Resume':'Pause','aria-label':p.paused?'Resume':'Pause',onclick:e=>{e.stopPropagation();post({action:'pause',on:!p.paused})}},
   svg(p.paused?'M5 3.5v9l7-4.5z':'M5 3.5v9M11 3.5v9')),el('button',{class:'btn icon',title:'Cancel','aria-label':'Cancel',onclick:e=>{e.stopPropagation();post({action:'cancel'})}},svg('M4 4l8 8M12 4l-8 8')))}
 return ctl}
/// What the counters mean, in one place: the line a person reads and the bar's filled per cent.
function phase(p){if(p.cancelled)return ['Stopping…',null];
 const label=p.phase=='delta-downloading'?'Downloading changed data ':p.phase=='full-fallback'?'Downloading full installer ':'Downloading ';
 if(p.done!=null&&p.total>0){const pct=Math.min(100,Math.round(p.done/p.total*100));
  return [(p.paused?'Paused · ':label)+mb(p.done)+' of '+mb(p.total)+' · '+pct+'%',pct]}
 if(p.done!=null)return [(p.paused?'Paused · ':label)+mb(p.done),null];
 if(p.copying)return ['Copying from '+p.copying,null];
 const labels={'held':'Held new work · settling what is in flight…','resumed':'Resuming work…','installing':'Installing…','checking':'Checking download…','checking-base':'Checking saved installer…','reconstructing':'Rebuilding and verifying installer…','full-fallback':'Changed data unavailable · using full installer…'};
 return [labels[p.phase]||'Preparing installation…',null]}
/// Counters only: the line's words, the loose or filled bar and its width. Never a new element, so
/// an open dialog keeps its focus and an indeterminate bar keeps running instead of restarting.
function paint(box,p){const t=phase(p),line=box.firstChild,bar=box.lastChild,i=bar.firstChild,w=t[1]==null?'':t[1]+'%';
 if(line.textContent!=t[0])line.textContent=t[0];
 const cls=t[1]==null?'bar loose':'bar';if(bar.className!=cls)bar.className=cls;
 if((i.style.width||'')!=w)i.style.width=w}
function svg(d){const s=document.createElementNS('http://www.w3.org/2000/svg','svg');s.setAttribute('viewBox','0 0 16 16');const p=document.createElementNS('http://www.w3.org/2000/svg','path');
 p.setAttribute('d',d);p.setAttribute('fill',d.includes('z')?'currentColor':'none');p.setAttribute('stroke','currentColor');p.setAttribute('stroke-width','1.8');p.setAttribute('stroke-linecap','round');s.append(p);return s}
function icon(a){return a.icon?el('img',{src:a.icon,alt:''}):el('div',{class:'ph','aria-hidden':true},svg('M3 3h4v4H3zM9 3h4v4H9zM3 9h4v4H3zM9 9h4v4H9z'))}
// An in-page confirmation. window.confirm() does not work in the packaged webview, which made
// Update/Install look dead: it returned false without showing anything.
function ask(question,confirmLabel,done){
 const restore=document.activeElement;
 const back=el('div',{role:'dialog','aria-modal':'true',style:'position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:99'});
 const box=el('div',{style:'background:var(--panel,#fff);color:var(--text,#111);border-radius:14px;padding:20px 20px 16px;max-width:380px;box-shadow:0 20px 60px rgba(0,0,0,.35);font:14px -apple-system,BlinkMacSystemFont,sans-serif'});
 box.append(el('p',{style:'margin:0 0 16px;line-height:1.4'},question));
 const row=el('div',{style:'display:flex;gap:10px;justify-content:flex-end'});
 const cancel=el('button',{class:'btn',onclick:()=>close(false)},'Cancel');
 const confirm=el('button',{class:'btn main',onclick:()=>close(true)},confirmLabel);
 row.append(cancel,confirm);box.append(row);back.append(box);
 // A real modal: the confirm button takes focus, Escape cancels, Tab stays inside these two
 // buttons, and a click on the backdrop cancels. window.confirm() is a silent no-op in the
 // packaged webview, so this is the only confirmation a person ever sees.
 function close(result){if(back.parentNode)back.remove();document.removeEventListener('keydown',keys,true);
  // A state push can redraw the row that opened this dialog, detaching it: focus then goes to the
  // always-present Settings button, never to the window body.
  const back2=restore&&restore.isConnected?restore:document.getElementById('gear');
  if(back2&&back2.focus)back2.focus();done(result)}
 function keys(e){
  if(e.key==='Escape'){if(e.preventDefault)e.preventDefault();if(e.stopPropagation)e.stopPropagation();close(false);return}
  if(e.key==='Tab'){if(e.preventDefault)e.preventDefault();if(e.stopPropagation)e.stopPropagation();(document.activeElement===confirm?cancel:confirm).focus()}}
 back.addEventListener('click',e=>{if(e.target===back)close(false)});
 document.addEventListener('keydown',keys,true);
 document.body.append(back);
 confirm.focus();
}
function buttons(a,big){const out=[],m=mainAction(a);
 if(a.status=='Updating…'&&!big)return [progress(a)];
 // The click has been taken; the agent starts on it now. No counters exist yet, so say just this.
 if(a.status=='Receiving update…')return [el('div',{class:'reason'},'Receiving update…')];
 if(m)out.push(el('button',{class:'btn main '+m[2],onclick:e=>{e.stopPropagation();
  // Nothing changes a Mac without being asked first. A webview confirm() is not reliable here,
  // so the dialog is an in-page one and the action waits for its answer.
  if(['update','install','reinstall'].includes(m[1])){
   const verb=m[1]=='update'?'Update':'Install';
   const what=(a.installed&&a.available)?a.name+' '+a.installed+' → '+a.available:a.name+' '+(a.available||'');
   ask(verb+' '+what.trim()+'?',verb,ok=>{if(ok)post({action:m[1],app:a.id})});
   return;
  }
  post({action:m[1],app:a.id})}},m[0]));
 out.push(el('button',{class:'btn icon',title:'More','aria-label':'More for '+a.name,'aria-haspopup':'menu',onclick:e=>{e.stopPropagation();openMenu(a,e.currentTarget)}},svg('M3.5 8h.01M8 8h.01M12.5 8h.01')));return out}
const typeName=a=>(S.appTypes||[]).includes(a.type)?a.type[0].toUpperCase()+a.type.slice(1):'Unlabelled';
function byType(a,b){const x=typeName(a),y=typeName(b);return Number(x==='Unlabelled')-Number(y==='Unlabelled')||x.localeCompare(y)}
const typeLine=a=>adopted(a)?null:el('div',{class:'tag'},typeName(a)+(a.unrecognised?' · Unrecognised':''));
// The eight sections the owner asked for, in his order: five of the feed's labels, then the two
// things that are not apps at all. Plugin and Extension read the same published list, split by kind.
const TABS=[['all','All'],['business','Business'],['media','Media'],['utility','Utilities'],['entertainment','Entertainment'],['system','System'],['plugin','Plugin'],['extension','Extension']];
const CATEGORIES=new Set(['business','media','utility','entertainment','system']);
const appsTab=()=>tab==='all'||CATEGORIES.has(tab);
// A row that exists because the app is installed on this Mac is not a feed row: it carries no feed
// label, and "No category yet" would read as the feed's mistake and ours. Its heading says what it
// is, and the version shown is the one read from its bundle (owner, 2026-11-24).
const adopted=a=>a.adopted===true;
const unlabelled=a=>!(S.appTypes||[]).includes(a.type)&&!adopted(a);
function card(a){const tag=a.tagline||a.description||(a.source=='Official vendor'?'Installed from its official vendor installer.':(a.statusOnly?'Updates itself from its own installer.':null));
 const when=installed(a)?day(a.installedAt):day(a.released);
 const c=el('article',{class:'card click'+(selected.has(a.id)?' selected':''),'aria-selected':String(selected.has(a.id)),style:a.accent?'--app:'+a.accent:null,onclick:()=>openDetail(a.id),tabindex:0,onkeydown:e=>{if(e.key=='Enter'&&e.target===e.currentTarget){openDetail(a.id);return}const cards=[...document.querySelectorAll('.card')],i=cards.indexOf(e.currentTarget),d=e.key=='ArrowRight'||e.key=='ArrowDown'?1:e.key=='ArrowLeft'||e.key=='ArrowUp'?-1:0;if(d){e.preventDefault();cards[(i+d+cards.length)%cards.length]?.focus()}}},
  el('div',{class:'head'},icon(a),el('div',{class:'t'},el('div',{class:'name'},a.name),typeLine(a),tag?el('div',{class:'tag'},tag):null)),
  el('div',{class:'meta'},chip(a),versionLine(a)),
  a.reason?el('div',{class:'reason'},(a.retrying?'Last attempt: ':'')+plain(a.reason)):null,
  // What this Mac has and what each other copy carries, in one sentence the comparison produced:
  // an older drive copy is named as older, a newer one as newer, never silently treated as current.
  a.sourcesText?el('div',{class:'src'},a.sourcesText):null,
  when?el('div',{class:'when'},(installed(a)?'Last updated ':'Released ')+when):null,
  el('div',{class:'foot'},...buttons(a)));return c}
function tableOf(list){return el('div',{class:'tablewrap'},el('table',{},el('thead',{},el('tr',{},el('th',{},'App'),el('th',{},'Installed'),el('th',{},'Latest'),el('th',{},'Released'),el('th',{},'State'),el('th',{},''))),
 el('tbody',{},list.map(a=>el('tr',{'aria-selected':String(selected.has(a.id)),onclick:()=>openDetail(a.id),style:(a.accent?'--app:'+a.accent+';':'')+'cursor:pointer'},
  el('td',{},el('div',{class:'head'},icon(a),el('div',{class:'t'},el('div',{class:'name'},a.name),typeLine(a),a.tagline?el('div',{class:'tag'},a.tagline):null))),
  el('td',{class:'num'},a.installed||'Not installed'),el('td',{class:'num'},a.available||a.serverVersion||'—'),el('td',{class:'when num'},day(a.released)||'—'),
  el('td',{},chip(a),a.reason?el('div',{class:'reason',style:'margin-top:4px'},(a.retrying?'Last attempt: ':'')+plain(a.reason)):null),
  el('td',{class:'act'},a.status=='Updating…'?el('div',{style:'min-width:240px'},progress(a)):buttons(a)))))))}
function visible(){const hidden=S.apps.filter(a=>a.hidden);let list=S.apps.filter(a=>showHidden||!a.hidden);
 // A category tab is the app list narrowed to that label; All is everything, unlabelled rows included.
 if(CATEGORIES.has(tab))list=list.filter(a=>a.type===tab);
 if(q)list=list.filter(a=>(a.name+' '+(a.tagline||'')).toLowerCase().includes(q));
 const key=a=>new Date(installed(a)?a.installedAt||0:a.released||0).getTime();
 list.sort((x,y)=>(sort=='recent'?key(y)-key(x):sort=='type'?byType(x,y):0)||x.name.localeCompare(y.name));return [list,hidden]}
// A push from the helper is either news or a transfer tick. News redraws the page; a tick writes
// its counters into the nodes already on screen. Redrawing for both was the flicker: every push
// destroyed the whole grid and any open dialog and re-made it, which replayed the dialog's entry
// animation twice a second, dropped keyboard focus and erased what had been typed in Settings.
const tickOnly=(k,v)=>k==='extensions'?undefined:k=='progress'&&v?{c:v.done!=null,z:v.paused,x:v.cancelled,ph:v.phase,cp:v.copying||''}:v;
// What the page would look like if it were drawn from the state it holds right now — transfer
// counters excepted, since those are written in rather than redrawn.
const signature=()=>JSON.stringify([view,sort,tab,q,showHidden,detail,settingsOpen,whatsNewOpen,showAll,selected.size,S],tickOnly);
let sig='';
function render(state){if(state)Object.assign(S,state);
 if(!viewFromMac&&S.settings&&S.settings.viewMode){view=S.settings.viewMode;viewFromMac=true}
 // A join that took effect clears both drafts, so a later open does not offer an address this Mac left.
 if(joinAddr!==null&&S.connection?.destination===joinAddr.trim()){joinAddr=null;joinCode=null}
 const macLabel=S.connection?.displayName||S.connection?.machine;
 $('mac').textContent=macLabel?'Apps for '+macLabel:'Apps for this Mac';
 $('wnver').textContent=S.version?'v'+S.version:'';
 const u=S.apps.find(a=>a.id=='updater'&&a.status=='Update available'&&a.available&&!a.statusOnly);
 $('update').hidden=!u;if(u){$('update').title='Studio Launcher KH Helper '+u.available;$('update').setAttribute('aria-label','Studio Launcher KH Helper to '+u.available)}
 paintStatus();paintAuto();
 // The published list is polled by nothing: a new answer writes into the open panel's own node,
 // exactly as a transfer tick does, because `extensions` is excluded from the redraw signature.
 if(!appsTab()&&$('extPanel'))drawExtensions(tab);
 const s=signature();
 if(s==sig){move();return}
 sig=s;draw()}
/// The counters moved and nothing else did: write them in, touch no other node.
function move(){document.querySelectorAll('[data-prog]').forEach(n=>{const a=S.apps.find(x=>x.id==n.getAttribute('data-prog'));paint(n,(a&&a.progress)||{})})}
function drawTabs(){const appTab=appsTab();
 $('main').setAttribute('aria-labelledby','tab-'+tab);
 $('tabs').replaceChildren(...TABS.map(([id,label])=>{const on=tab==id;
  return el('button',{role:'tab',id:'tab-'+id,'aria-selected':String(on),'aria-controls':'main',tabindex:on?'0':'-1',
   onclick:()=>selectTab(id),
   onkeydown:e=>{const i=TABS.findIndex(t=>t[0]==id),d=e.key=='ArrowRight'?1:e.key=='ArrowLeft'?-1:0;
    if(d){e.preventDefault();const n=TABS[(i+d+TABS.length)%TABS.length][0];selectTab(n);$('tab-'+n)?.focus()}
    else if(e.key=='Home'||e.key=='End'){e.preventDefault();const n=(e.key=='Home'?TABS[0]:TABS[TABS.length-1])[0];selectTab(n);$('tab-'+n)?.focus()}}},label)}));
 // Extensions and plugins are not apps: the controls that only shape an app list would do nothing
 // on those tabs, so they are not offered there rather than offered and inert.
 $('sort').hidden=!appTab;$('q').hidden=!appTab;$('viewseg').hidden=!appTab}
function selectTab(id){if(tab===id)return;tab=id;store.set('tab',tab);detail=null;closeLayers();
 // Nothing polls: the published list is asked for when someone first opens a tab that holds it.
 if(!appsTab()&&(!S.extensions||S.extensions.status==='idle'))post({action:'checkExtensions'});
 render()}
function draw(){const active=document.activeElement||{},fk=active.id,selection=[active.selectionStart,active.selectionEnd];
 drawTabs();
 const appTab=appsTab();
 const [list,hidden]=visible();
 // Under All the unlabelled rows get their own named group, so they are not counted twice here.
 const labelled=tab=='all'?list.filter(a=>!unlabelled(a)):list;
 // Installed here, absent from the feed: its own group, so it is neither labelled by the feed nor
 // pushed into a category the feed never gave it.
 const here=labelled.filter(adopted);
 const mine=labelled.filter(a=>installed(a)&&!adopted(a)),others=labelled.filter(a=>!installed(a)&&!adopted(a));
 const unlabelledRows=tab=='all'?list.filter(unlabelled):[];
 const n=S.apps.filter(a=>a.managed&&!a.statusOnly&&a.available&&(a.status=='Update available'||a.status=='Failed'||a.status=='Downloaded')).length;
 $('all').hidden=n==0||!appTab;$('all').textContent='Update all ('+n+')';
 $('vgrid').setAttribute('aria-pressed',view=='grid');$('vlist').setAttribute('aria-pressed',view=='list');$('sort').value=sort;
 const m=$('main');m.replaceChildren();
 if(appTab){
  if(Number.isInteger(S.feedCount)&&S.feedPublishedAt){
   const stamp=new Date(S.feedPublishedAt).toLocaleString(undefined,{day:'numeric',month:'short',hour:'numeric',minute:'2-digit'});
   const missing=S.missingFromFeed||[];
   const source='This feed';
   m.append(el('p',{class:'note',style:'margin:2px 0 8px'},source+' carries '+S.feedCount+' '+(S.feedCount===1?'app':'apps')+', last updated '+stamp+(missing.length?' · Not on it: '+missing.join(', '):'')));
  }
  if(!S.apps.length)m.append(el('p',{class:'empty'},S.error?'The publisher at '+(S.connection.destination||'the saved address')+' could not be reached: '+S.error:'Checking…'));
  else if(!list.length){
   // An empty category is a fact about the feed's labels, and the sentence says so instead of
   // leaving a blank panel that reads as a broken screen.
   const none=S.apps.filter(a=>!a.hidden&&unlabelled(a)).length;
   m.append(el('p',{class:'empty'},q?'No app matches “'+q+'”.':CATEGORIES.has(tab)?'No '+TABS.find(t=>t[0]==tab)[1]+' apps on this feed yet.'+(none?' '+none+' '+(none===1?'app has':'apps have')+' no category yet; they are under All.':''):'No app matches “'+q+'”.'));
  }
  for(const [title,group] of [['Installed',mine],['Installed on this Mac',here],['Not installed',others]]){if(!group.length)continue;
   m.append(el('h2',{},title+' · '+group.length),view=='grid'?el('div',{class:'grid'},group.map(card)):tableOf(group))}
  if(unlabelledRows.length)m.append(el('h2',{},'No category yet · '+unlabelledRows.length),view=='grid'?el('div',{class:'grid'},unlabelledRows.map(card)):tableOf(unlabelledRows));
 }else{
  const box=el('div',{id:'extPanel','aria-live':'polite'});m.append(box);drawExtensions(tab);
 }
 // The note belongs to the category tabs: under All the group heading already says it, and on the
 // two non-app tabs it would describe a list that is not on screen.
 const none=appTab&&tab!='all'?S.apps.filter(a=>!a.hidden&&unlabelled(a)).length:0;
 // A whole app labelled plugin or extension is still an app; it is named here rather than drawn as
 // an index row, so neither tab hides it.
 const asApps=!appTab?S.apps.filter(a=>!a.hidden&&a.type===tab).length:0;
 const note=asApps?asApps+(asApps===1?' app is':' apps are')+' labelled '+TABS.find(t=>t[0]==tab)[1]+'; they are apps, under All.'
  :none?none+(none===1?' app has':' apps have')+' no category on the feed yet; they are under All.':'';
 $('tabNote').hidden=!note;$('tabNote').textContent=note;
 drawNotices();drawAdoptions();
 $('hiddenNote').replaceChildren(hidden.length?el('button',{class:'link',onclick:()=>{showHidden=!showHidden;render()}},showHidden?'Hide hidden apps':hidden.length+' hidden · Show'):'');
 document.documentElement.style.colorScheme=S.settings.appearance=='dark'?'dark':S.settings.appearance=='light'?'light':'light dark';
 if(detail)drawDetail();if(settingsOpen)drawSettings();if(whatsNewOpen)drawWhatsNew();
 // shortcut: focus comes back only where the control has an id (search, sort, the address field);
 // cards carry none, so a redraw cannot hand focus back to the card the person was on.
 if(fk&&$(fk)){$(fk).focus();if(selection[0]!=null)$(fk).setSelectionRange?.(...selection)}}
// Plugin and Extension are rows, not app cards: neither has an installer of its own, so neither
// gets an Install button, a version chip of an installed build, or a place in the app list.
// A picture is never a reason to wait: the tile paints its placeholder at once and the picture
// swaps in only if it arrives, at most 2048 pixels a side and within 5 seconds. A picture that is
// skipped says why in the page's own words instead of leaving a broken frame or a spinner.
const EXT_PIXELS=2048,EXT_WAIT=5000;
function extPicture(x,src,cls,label,note,alt){
 const box=el('div',{class:cls}),ph=el('span',{class:'ph'},label);
 const img=el('img',{alt:(alt||label)+' for '+x.name,loading:'lazy',decoding:'async','data-src':src});
 box.append(ph);
 if(!src)return box;
 img.hidden=true;box.append(img);
 const skip=why=>{img.remove();note.textContent=why};
 const later=fn=>{try{return setTimeout(fn,EXT_WAIT)}catch(e){return null}},timer=later(()=>skip('The '+label.toLowerCase()+' did not arrive within 5 seconds, so the tile keeps its placeholder.'));
 img.onload=()=>{try{clearTimeout(timer)}catch(e){}
  if(img.naturalWidth>EXT_PIXELS||img.naturalHeight>EXT_PIXELS){
   skip('The '+label.toLowerCase()+' is '+img.naturalWidth+'×'+img.naturalHeight+', over the '+EXT_PIXELS+'-pixel limit, so it is not shown.');return}
  ph.remove();img.hidden=false};
 img.onerror=()=>{try{clearTimeout(timer)}catch(e){}skip('The '+label.toLowerCase()+' could not be loaded, so the tile keeps its placeholder.')};
 img.src=src;return box}
function extTile(x){const note=el('p',{class:'sub extNote'});
 return el('div',{class:'extRow extTile'},
  extPicture(x,x.icon,'extIcon',(x.name.trim()[0]||'?').toUpperCase(),note,'Icon'),
  el('div',{class:'extBody'},el('strong',{},x.name),' · ',x.version,el('p',{},x.summary),note),
  extPicture(x,x.screenshot,'extShot','Screenshot',note,'Screenshot'),
  x.download?el('button',{class:'btn','aria-label':'Download '+x.name,onclick:()=>post({action:'downloadExtension',app:x.id})},'Download')
            :el('span',{class:'tag'},'No public download yet'))}
function drawExtensions(kind){const state=S.extensions||{status:'idle'};
 const box=$('extPanel');if(!box)return;
 const check=()=>post({action:'checkExtensions'});
 const message={idle:'Check for public Chrome extension downloads.',loading:'Checking for published extensions…',
  unpublished:'Extensions and plugins are not published yet; nothing to download.',failed:'Could not check for published extensions. Try again.'}[state.status];
 if(message){box.replaceChildren(el('p',{},message));if(state.status!=='loading')box.append(
  el('button',{class:'btn',onclick:check},state.status==='idle'?'Check downloads':'Check again'));return}
 const rows=(state.entries||[]).filter(x=>(x.kind==='plugin')===(kind==='plugin'));
 box.replaceChildren(el('p',{class:'sub'},kind==='plugin'
  ?'Published plugins. A plugin has no installer of its own; it arrives with the app that carries it.'
  :'Download and unzip the file, then use Load unpacked in Chrome’s Extensions page.'));
 if(!rows.length)box.append(el('p',{},kind==='plugin'?'No published plugin yet.':'No published extension yet.'));
 for(const x of rows)box.append(extTile(x));
 if(state.note)box.append(el('p',{role:'status'},state.note));}
/// One quiet notice per new version: no badge, no count, and a dismissal is remembered by version.
function drawNotices(){const n=S.notices||[],box=$('notices');box.hidden=!n.length;
 box.replaceChildren(...n.map(x=>el('div',{class:'notice'},el('span',{},x.name+' '+x.version+' is ready.'),
  el('button',{class:'btn',onclick:()=>ask('Update '+x.name+' '+x.version+'?','Update',ok=>{if(ok)post({action:'update',app:x.id})})},'Update'),
  el('button',{class:'link',onclick:()=>post({action:'dismissNotice',app:x.id,version:x.version})},'Dismiss'))))}
/// Copies of our apps already on this Mac: offered once, managed where they are, or left alone.
function drawAdoptions(){const list=S.adoptions||[],box=$('adoptions');box.hidden=!list.length;if(!list.length){box.replaceChildren();return}
 box.replaceChildren(el('div',{class:'adopt'},el('b',{},'Installed by hand'),
  el('p',{class:'sub'},'These copies are already on this Mac. Managing one keeps it where it is and updates it in place — nothing is moved, renamed or reinstalled over it.'),
  ...list.map(o=>el('div',{class:'row'},el('span',{},o.name+' '+o.version),el('code',{},o.path),
   el('button',{class:'btn',onclick:()=>post({action:'adopt',app:o.id})},'Manage it'),
   el('button',{class:'link',onclick:()=>post({action:'declineAdoption',app:o.id})},'Not now')))))}
/// One compact status line: a failure replaces the freshness line rather than sitting beside it.
/// Nothing on this screen names a service, a provider or a kit: the feed is "the saved feed".
function paintStatus(){const e=$('err'),c=$('checked'),err=S.error?'Last check failed: '+S.error+(S.lastAttempt?' · '+new Date(S.lastAttempt).toLocaleString():''):'';
 const source='the saved feed', n=S.sources.length;
 const drives=n===1?'1 installer drive':n+' installer drives';
 const title='Check '+source+(n?' and '+drives:', and scan for installer drives');
 const refresh=$('check');if(refresh.getAttribute('title')!==title){refresh.setAttribute('title',title);refresh.setAttribute('aria-label',title)}
 e.textContent=err;e.hidden=!err;
 c.textContent=(S.serverKnown&&S.lastRun?'Checked '+source+' '+ago(S.lastRun):'Not checked yet')
  +(S.lastDriveScan?(n?' · Scanned '+drives:' · No installer drives found'):' · Drives not scanned yet')
  +(S.paused?' · Automatic updates paused':'');c.hidden=!!err}
/// The one Automatic switch on this Mac's own screen. It shows what the helper will really do —
/// manual checking turns it off — and flipping it writes the same setting Settings shows. Each
/// app's own switch stays in that app's … menu, where its origin is named.
function autoOn(){return !S.settings.checkManually&&S.settings.autoInstall!==false}
function paintAuto(){const a=$('auto'),manual=!!S.settings.checkManually,on=autoOn();
 a.hidden=!S.apps.length;a.disabled=manual;a.setAttribute('aria-pressed',String(on));
 a.textContent='Automatic updates '+(on?'on':'off');
 a.title=manual?'Updates are checked by hand. Choose Automatically in Settings to use this switch.'
  :on?'Updates install by themselves. Press to make them wait for you.':'Updates wait for you. Press to install them by themselves.'}
function closeLayers(){document.querySelectorAll('.scrim,.menu').forEach(x=>x.remove())}
function openMenu(a,anchor){document.querySelectorAll('.menu').forEach(x=>x.remove());const items=[];
 const add=(label,action,cls)=>items.push(el('button',{class:cls||'',role:'menuitem',onclick:()=>{m.remove();action()}},label));
 // The drive's own first copy. Newer than the feed, it is the update and comes first; older, it is
 // a deliberate choice that names both versions and never reads as the update. It is never hidden:
 // it is this Mac's offline fallback (owner, 2026-11-24).
 if(a.initialSSD&&!a.installed&&(!a.statusOnly||a.manuallyInstallable)){
  const parts=a.initialSSD.split(' · '),volume=parts[0],driveVersion=parts[1]||'';
  if(a.initialSSDNewer)add('Install from '+a.initialSSD+' first',()=>post({action:'installSSD',app:a.id}));
  else add('Copy '+(driveVersion||'that copy')+' from '+volume+' anyway',()=>post({action:'installSSD',app:a.id}))}
 if(a.notes&&a.notes.length)add('Release notes',()=>openDetail(a.id,true));
 if(a.open&&!a.helper){add('Open',()=>post({action:'open',app:a.id}));add('Show in Finder',()=>post({action:'finder',app:a.id}))}
 if(a.managed&&a.installed&&a.available&&!a.statusOnly&&!a.helper)add('Reinstall',()=>post({action:'reinstall',app:a.id}));
 if(a.canRollBack)add('Roll back to the previous version',()=>post({action:'rollback',app:a.id}));
 if((a.status=='Failed'||a.status=='Needs attention')&&a.reason)add('Copy error report',()=>post({action:'copyReport',app:a.id}));
 if(a.managed&&!a.statusOnly){items.push(el('hr'));const why='automatic-origin-'+a.id;
  items.push(el('button',{role:'menuitemcheckbox','aria-checked':a.automatic,'aria-describedby':a.automaticOrigin?why:null,onclick:()=>{m.remove();post({action:'automatic',app:a.id,on:!a.automatic})}},el('span',{class:'check'},a.automatic?svg('M3.5 8.5l3 3 6-7'):''),'Update automatically'));
  // The words come from the agent's own decision, so this line can never disagree with the switch.
  // Clearing this Mac's switch is not offered: the controller keeps the last value it was told, so
  // what a cleared switch would fall back to is this Mac's own earlier choice, not a page setting.
  if(a.automaticOrigin)items.push(el('p',{class:'why',id:why},a.automaticOrigin))}
 items.push(el('hr'));
 if(a.open&&!a.helper)add('Uninstall…',()=>post({action:'uninstall',app:a.id}),'danger');
 add(a.hidden?'Show app':'Hide app',()=>post({action:a.hidden?'unhide':'hide',app:a.id}));
 const m=el('div',{class:'menu',role:'menu'},items);document.body.append(m);
 const r=anchor.getBoundingClientRect(),w=m.offsetWidth,h=m.offsetHeight;
 m.style.left=Math.max(8,Math.min(innerWidth-w-8,r.right-w))+'px';m.style.top=(r.bottom+h+8>innerHeight?r.top-h-4:r.bottom+4)+'px';m.querySelector('button')?.focus()}
function openDetail(id,notes){detail={id,notes};drawDetail()}
function drawDetail(){const list=visible()[0],i=list.findIndex(a=>a.id==detail.id),a=list[i]||S.apps.find(x=>x.id==detail.id);if(!a){detail=null;return}
 const again=!!document.querySelector('.scrim.d');
 document.querySelectorAll('.scrim.d').forEach(x=>x.remove());
 const step=d=>{const n=list[(i+d+list.length)%list.length];if(n){detail={id:n.id};drawDetail()}};
 const facts=[['Installed',a.installed||'Not installed'],['Server',a.serverVersion||'Unknown'],['SSD',a.ssdVersion||(a.ssdNote?'Not used':'Not available')],['Selected',a.available||'Not available'],['Size',mb(a.bytes)||'Unknown'],['From',a.fromSSD||(a.source||'Unknown')],['Released',day(a.released)]].filter(f=>f[1]);
 const notes=a.notes||[],limit=showAll[a.id]?notes.length:5;
 const sheet=el('div',{class:'sheet',role:'dialog','aria-modal':true,'aria-label':a.name,style:(a.accent?'--app:'+a.accent+';':'')+(again?'animation:none':''),onclick:e=>e.stopPropagation()},
  el('div',{class:'top'},icon(a),el('div',{class:'t'},el('h3',{},a.name),a.tagline?el('div',{class:'sub'},a.tagline):null,
    el('div',{class:'meta',style:'margin-top:8px'},chip(a),versionLine(a),a.released?el('span',{class:'when'},'· '+day(a.released)):null),
    a.reason?el('div',{class:'reason',style:'margin-top:6px'},(a.retrying?'Last attempt: ':'')+plain(a.reason)):null,
    a.status=='Updating…'?el('div',{style:'margin-top:10px;max-width:420px'},progress(a)):el('div',{class:'foot',style:'margin-top:12px;max-width:340px'},...buttons(a,true))),
   el('div',{class:'nav'},el('button',{class:'btn icon',title:'Previous app','aria-label':'Previous app',onclick:()=>step(-1)},svg('M10 3 5 8l5 5')),
    el('button',{class:'btn icon',title:'Next app','aria-label':'Next app',onclick:()=>step(1)},svg('M6 3l5 5-5 5')),
    el('button',{class:'btn icon',title:'Close','aria-label':'Close',onclick:()=>{detail=null;closeLayers()}},svg('M4 4l8 8M12 4l-8 8')))),
  el('div',{class:'cols'},
   el('div',{},a.description?el('p',{class:'desc'},a.description):el('p',{class:'desc sub'},a.statusOnly?(a.manuallyInstallable?'This app updates itself from its own installer. You can still install or update it here whenever you choose.':(a.source=='Official vendor'?(a.setup?'The verified official installer is waiting in its setup folder.':'This app is installed from its official vendor’s installer.'):'This app uses its own installer and updater.')):'No description yet.'),
    // The hand route needs an installer offer this Mac can check and the app's own identity; with
    // neither, the app's own updater or its SSD setup folder is the way in, and the page says so.
    a.statusOnly&&a.source!='Official vendor'&&!a.manuallyInstallable?el('p',{class:'sub'},a.setup?'Use Open Setup Folder to install. Open the installed app for its own updates.':a.open?'Open this app to use its own updater.':'No setup folder is connected. Connect the installer SSD to use this app’s setup. Remote installation through Launcher is not available for this app yet.'):null,
    a.features&&a.features.length?[el('h4',{},'Features'),el('ol',{class:'feat'},a.features.map(f=>el('li',{},el('b',{},f.title),f.text?el('span',{},f.text):null)))]:null),
   el('div',{},facts.length?[el('h4',{},'Latest release'),el('dl',{class:'facts'},facts.map(f=>el('div',{},el('dt',{},f[0]),el('dd',{class:'num'},f[1]))))]:null,
    // Where the offer comes from, and why a drive's own copy was not used, in the words the Catalog
    // chose. Neither line claims a saving or that anything is ready: bytes are read where they are.
    a.fromSSD?el('p',{class:'sub'},'The version on offer is the copy on '+a.fromSSD+', read from that drive.'):
     a.source=='Feed'?el('p',{class:'sub'},'The version on offer comes from the signed feed, so its installer is downloaded.'):null,
    a.ssdNote&&!a.fromSSD?el('p',{class:'sub'},a.ssdNote):null,
    a.sourcesText?el('p',{class:'sub'},a.sourcesText+(a.initialSSD&&!a.initialSSDNewer?' Install from the feed above, or copy the drive’s copy from the More menu.':'')):null,
    el('h4',{id:'changes'},'What’s changed'),notes.length?el('ul',{class:'changes'},notes.slice(0,limit).map(n=>el('li',{},n))):el('p',{class:'sub'},'No notes for this version.'),
    notes.length>5?el('button',{class:'more',onclick:()=>{showAll[a.id]=!showAll[a.id];drawDetail()}},showAll[a.id]?'Show fewer':'Show '+(notes.length-5)+' more'):null)));
 const scrim=el('div',{class:'scrim d',onclick:()=>{detail=null;closeLayers()}},sheet);document.body.append(scrim);
 if(detail.notes){detail.notes=false;sheet.querySelector('#changes').scrollIntoView({block:'center'})}
 // The dialog now shows exactly what the state holds, so a following tick writes counters into it
 // instead of rebuilding it under the person's hands.
 sig=signature()}
// What's New is the page's own pop-up: the notes for this version already arrive in the state, so
// opening it asks the helper for nothing. One Done; Esc or the backdrop closes it.
function showWhatsNew(){settingsOpen=false;detail=null;whatsNewOpen=true;closeLayers();drawWhatsNew()}
function drawWhatsNew(){const again=!!document.querySelector('.scrim.w');document.querySelectorAll('.scrim.w').forEach(x=>x.remove());
 const notes=S.whatsNew||[],close=()=>{whatsNewOpen=false;closeLayers()};
 const sheet=el('div',{class:'sheet wn',role:'dialog','aria-modal':true,'aria-label':'What’s New',style:again?'animation:none':'',onclick:e=>e.stopPropagation()},
  el('div',{class:'top'},el('div',{class:'t'},el('h3',{},'What’s New'),el('div',{class:'sub'},'Studio Launcher KH '+(S.version||'')))),
  el('div',{class:'body'},notes.length?el('ul',{class:'changes'},notes.map(n=>el('li',{},n))):el('p',{class:'sub'},'No notes for this version.')),
  el('div',{class:'bottom'},el('button',{class:'btn primary',onclick:close},'Done')));
 document.body.append(el('div',{class:'scrim w',onclick:close},sheet));sig=signature()}
function drawSettings(){const again=!!document.querySelector('.scrim.s');document.querySelectorAll('.scrim.s').forEach(x=>x.remove());const s=S.settings,c=S.connection||{destination:'',machine:''};
 const set=(key,value)=>post({action:'setting',key,value});
 const check=(key,label,on,note,disabled)=>el('div',{},el('div',{class:'row'+(disabled?' dis':'')},el('label',{},el('input',{type:'checkbox',checked:on,disabled,onchange:e=>set(key,e.target.checked)}),label)),note?el('p',{class:'note'},note):null);
 const seg=(key,opts,cur)=>el('div',{class:'seg',role:'group'},opts.map(([v,l])=>el('button',{'aria-pressed':String(cur==v),onclick:()=>set(key,v)},l)));
 // The address in use, never a guess: a saved one, else the default a Mac with no saved address
 // starts on.
 const shownAddress=c.destination||c.defaultFeed||'';
 // Only a Mac that saved a non-default address has anything to disclose, and only a Mac that runs or
 // joined a Studio has those controls at all. Everything else is one line and one button.
 const customAddress=!!c.destination&&!!c.defaultFeed&&c.destination!==c.defaultFeed;
 const studio=!!c.studio;
 const pubAddr=el('input',{id:'pubaddr',type:'text',value:joinAddr===null?((c.destination&&!c.publicFeed)?c.destination:''):joinAddr,placeholder:'http://name.tail1234.ts.net:8790/release.json','aria-label':'Studio address for joining',oninput:e=>{joinAddr=e.target.value}});
 const pubCode=el('input',{id:'pubcode',type:'text',value:joinCode===null?'':joinCode,placeholder:'123-456','aria-label':'Pairing code',oninput:e=>{joinCode=e.target.value}});
 // The Studio's own controls — the address, pairing, joining, leaving and the fleet — live behind
 // Advanced, which exists only where an address other than the saved feed is in use and only on a
 // Mac that runs a Studio or has joined one. A single-Mac screen cannot reach any of it.
 const advanced=studio&&customAddress?el('details',{class:'adv'},el('summary',{},'Advanced'),
  el('p',{class:'ver',style:'margin:8px 0 4px'},shownAddress),
  el('p',{class:'note',style:'margin-left:0'},'This Mac reports its apps and versions to the Studio it joined. Nothing else leaves this Mac.'),
  el('p',{class:'note',style:'margin-left:0'},'This Mac: '+(c.displayName&&c.machine&&c.displayName!==c.machine?c.displayName+' ('+c.machine+')':(c.displayName||c.machine||''))),
  el('div',{class:'row'},el('button',{class:'btn',disabled:!!c.checking,onclick:()=>post({action:'connectionCheck'})},c.checking?'Checking\u2026':'Check the connection'),
   el('button',{class:'btn',onclick:()=>post({action:'fleet'})},'Open the fleet\u2026')),
  c.pairAvailable?el('div',{class:'row'},el('button',{class:'btn',disabled:!!c.checking,onclick:()=>post({action:'pairAgain'})},'Pair again now')):null,
  c.canLeave?null:el('div',{},
   el('div',{class:'row'},pubAddr),
   el('div',{class:'row'},pubCode,el('button',{class:'btn',disabled:!!c.checking,onclick:()=>post({action:'joinFleet',value:pubAddr.value,code:pubCode.value})},'Join')),
   el('p',{class:'note',style:'margin-left:0'},'Type that Mac\u2019s address and the pairing code it shows; nothing is sent until you press Join.')),
  el('div',{class:'row'},el('button',{class:'btn',disabled:!!c.checking,onclick:()=>post({action:'changeServer',value:c.defaultFeed})},'Use the saved feed instead')),
  c.canLeave?el('div',{class:'row'},el('button',{class:'btn',disabled:!!c.checking,onclick:()=>ask('Leave this Studio? This Mac keeps every app and every model. It stops taking orders from it and updates from the saved feed instead.','Leave this Studio',yes=>{if(yes)post({action:'leaveFleet'})})},'Leave this Studio')):null,
  c.serverNote?el('p',{style:'font-size:12px;margin:6px 0 0;color:'+(c.serverOk?'var(--ok)':'var(--bad)')},c.serverNote):null):null;
 const updater=S.apps.find(a=>a.id=='updater');
 const sheet=el('div',{class:'sheet set',role:'dialog','aria-modal':true,'aria-label':'Settings',style:again?'animation:none':'',onclick:e=>e.stopPropagation()},
  el('div',{class:'top'},el('div',{class:'t'},el('h3',{},'Settings'),el('div',{class:'sub'},'Studio Launcher KH '+S.version))),
  el('div',{class:'body'},
   S.settingsNote?el('p',{class:'note',role:'status','aria-live':'polite'},S.settingsNote):null,
   el('section',{},el('h4',{},'Updates'),
    el('p',{class:'note',style:'margin-left:0'},studio?'Updates come from the Studio\u2019s signed feed.':'Updates come from this Mac\u2019s signed feed.'),
    el('div',{class:'row'},el('span',{class:'sub',style:'min-width:0;overflow-wrap:anywhere'},c.checking?'Checking the connection\u2026':(c.note||c.serverNote||(c.ok&&c.checkedAt?'Connected \u00b7 checked '+ago(c.checkedAt):''))),
     el('button',{class:'btn',disabled:!!c.checking,onclick:()=>post({action:'connectionCheck'})},c.checking?'Checking\u2026':'Check now')),
    el('div',{class:'row'},el('span',{},'Check for updates'),seg('checkManually',[[false,'Automatically'],[true,'Manually']],s.checkManually)),
    check('autoInstall','Install updates automatically',s.autoInstall&&!s.checkManually,s.checkManually?'Off while checking manually. Use Check for updates now, then Update.':'Each app’s own switch is in its … menu.',s.checkManually),
    check('notify','Notify me when an update is ready',s.notify,null),
    // One app's Automatic value comes from one of three places; the app's … menu names which, using
    // the agent's own decision. Nothing here clears a Mac's switch: the controller keeps the value
    // it was last given, so a cleared switch would inherit this Mac's earlier choice, not a page one.
    studio?el('p',{class:'note'},'A switch set on this Mac rules while it is the later change; otherwise the Studio’s value does, and where neither has one this Mac’s default does. Each app’s menu names which of the three is in force.'):null,
    check('retireHelpers','Keep the current and previous helper versions',s.retireHelpers,s.helperCleanupAvailable?'Older versions move to restorable _trash after '+(s.helperHealthySeconds/60).toLocaleString()+' minutes of repeated healthy reports.':'Cleanup settings could not be read. Older versions are kept.',!s.helperCleanupAvailable),
    // The updater's own switch is live data, and its automatic-on-connect default is stated, not implied.
    updater?check('updaterAutomatic','Studio Launcher KH updates itself automatically',!!updater.automatic,
      c.publicFeed?'From the signed feed: this Mac installs each new version that feed serves.':'Automatic is on when this Mac joins a Studio; change it in its own … menu.',
      !c.publicFeed):null,
    advanced),
   el('section',{},el('h4',{},'Appearance'),seg('appearance',[['system','System'],['light','Light'],['dark','Dark']],s.appearance),
    el('p',{class:'note',style:'margin-left:0'},'System matches this Mac. Light and Dark force that look.')),
   el('section',{},el('h4',{},'In the background'),check('menuBarWhenClosed','Keep the icon in the menu bar when this window is closed',s.menuBarWhenClosed,null),
    check('login','Start at login',true,'Always on: the helper starts at login so this Mac keeps getting updates.',true)),
   el('section',{},el('h4',{},'Log'),seg('logVerbosity',[['quiet','Quiet'],['normal','Normal'],['verbose','Verbose']],s.logVerbosity||'normal'),
    el('p',{class:'note',style:'margin-left:0'},'What the helper did on this Mac, kept for this run and the two before it. A change applies on the helper’s next start; no rebuild.'),
    el('p',{class:'note',style:'margin-left:0'},el('code',{style:'user-select:text;word-break:break-all'},S.logPath||'—'))),
   el('section',{},el('h4',{},'About'),el('p',{class:'ver'},'Studio Launcher KH v'+(S.version||'unknown')))),
  el('div',{class:'bottom'},el('button',{class:'btn primary',onclick:()=>{settingsOpen=false;closeLayers()}},'Done')));
 document.body.append(el('div',{class:'scrim s',onclick:()=>{settingsOpen=false;closeLayers()}},sheet));sig=signature()}
$('vgrid').onclick=()=>{view='grid';store.set('view',view);post({action:'setting',key:'viewMode',value:'grid'});render()};$('vlist').onclick=()=>{view='list';store.set('view',view);post({action:'setting',key:'viewMode',value:'list'});render()};
$('sort').onchange=e=>{sort=e.target.value;store.set('sort',sort);render()};$('q').oninput=e=>{q=e.target.value.trim().toLowerCase();render()};
$('all').onclick=()=>post({action:'updateAll'});$('check').onclick=()=>post({action:'check'});$('gear').onclick=()=>{settingsOpen=true;drawSettings()};$('whatsNew').onclick=showWhatsNew;
$('update').onclick=()=>post({action:'update',app:'updater'});$('support').onclick=()=>post({action:'support'});
$('auto').onclick=()=>{if(S.settings.checkManually)return;post({action:'setting',key:'autoInstall',value:!autoOn()})};
document.addEventListener('click',e=>{if(!e.target.closest('.menu'))document.querySelectorAll('.menu').forEach(x=>x.remove())});
document.addEventListener('keydown',e=>{if(e.key=='Escape'){if(document.querySelector('.menu'))document.querySelectorAll('.menu').forEach(x=>x.remove());else if(whatsNewOpen){whatsNewOpen=false;closeLayers()}else if(settingsOpen){settingsOpen=false;document.querySelectorAll('.scrim.s').forEach(x=>x.remove())}else{detail=null;if(selected.size){selected.clear();render()};closeLayers()}}
 const editing=['INPUT','TEXTAREA','SELECT'].includes((e.target?.tagName||'').toUpperCase())||e.target?.isContentEditable;
 if(detail&&!settingsOpen&&!editing&&(e.key=='ArrowRight'||e.key=='ArrowLeft')){const l=visible()[0],i=l.findIndex(a=>a.id==detail.id),n=l[(i+(e.key=='ArrowRight'?1:-1)+l.length)%l.length];if(n){detail={id:n.id};drawDetail()}}
 if(e.metaKey&&e.key==','){e.preventDefault();settingsOpen=true;drawSettings()}
 // Cmd+A picks every visible card that has a primary action, so the keyboard can do what Update all does.
 if((e.metaKey||e.ctrlKey)&&e.key=='a'&&!settingsOpen&&!whatsNewOpen&&!detail&&!editing){e.preventDefault();
  selected=new Set(visible()[0].filter(a=>{const m=mainAction(a);return m&&m[2]=='primary'}).map(a=>a.id));render();return}
 if(e.key=='Enter'&&selected.size&&!settingsOpen&&!whatsNewOpen&&!detail&&!editing){e.preventDefault();
  const n=selected.size;ask('Update '+n+' app'+(n==1?'':'s')+'?','Update',ok=>{if(ok)post({action:'updateAll'})});return}
 if(e.metaKey&&(e.key=='f'||e.key=='k')){e.preventDefault();$('q').focus()}});
setInterval(()=>{if(S.lastRun||S.lastDriveScan)paintStatus()},30000);
</script></body></html>
"""#.replacingOccurrences(of: "</style>", with: Changelog.layoutCSS + "</style>")
}
