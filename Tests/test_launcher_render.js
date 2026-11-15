// Focused regression for the Studio Launcher page's render and dialog lifecycle. It runs the page's
// own embedded script (extracted from Sources/khu/LauncherPage.swift) against a small DOM, the way
// Tests/test_publisher_ui.js runs the publisher's handler. Run: node Tests/test_launcher_render.js
//
// The owner's live bug, 2026-11-10: the window strobed twice a second even with a dialog open, and a
// stopped or failed attempt went on reading "Installing…". Both came from the same place — every
// state push rebuilt the whole page *and* both dialogs, so the dialog replayed its entry animation,
// keyboard focus was dropped, what had been typed in Settings was erased, and the only thing that
// re-pushed state after work stopped was the end of an agent run.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const sourcePath = process.argv[2] || path.join(__dirname, '..', 'Sources', 'khu', 'LauncherPage.swift');
const source = fs.readFileSync(sourcePath, 'utf8');
const markup = source.slice(source.indexOf('<body>'), source.indexOf('<script>'));
const script = source.slice(source.indexOf('<script>') + 8, source.indexOf('</script>'));
assert(script.includes('function render('), 'the embedded page script must be found');

// --- the smallest DOM the page can run in: elements, attributes, text, simple selectors, events ---
const kebab = k => k.replace(/[A-Z]/g, c => '-' + c.toLowerCase());
// A browser hands inline style back both ways: written as `style="width:30%"` or as
// `style.width='30%'`. The fixture has to do the same or a comparison means nothing.
function makeStyle() {
  const decl = new Map();
  const read = () => [...decl].map(([k, v]) => k + ': ' + v).join('; ');
  return new Proxy({}, {
    get(_t, key) {
      if (key == 'cssText') return read();
      const v = decl.get(kebab(String(key)));
      return v === undefined ? '' : v;
    },
    set(_t, key, value) {
      if (key == 'cssText') {
        decl.clear();
        for (const part of String(value).split(';')) {
          const at = part.indexOf(':');
          if (at > 0) decl.set(part.slice(0, at).trim(), part.slice(at + 1).trim());
        }
        return true;
      }
      if (value === '') decl.delete(kebab(String(key))); else decl.set(kebab(String(key)), String(value));
      return true;
    },
  });
}
class Text {
  constructor(text) { this.nodeType = 3; this.text = text; this.parentNode = null; }
  get textContent() { return this.text; }
}
class El {
  constructor(tag) {
    this.tag = tag; this.nodeType = 1; this.attrs = {}; this.kids = []; this.parentNode = null;
    this.handlers = {}; this.style = makeStyle(); this.id = ''; this.value = ''; this.checked = false;
    this.disabled = false; this.hidden = false; this.offsetWidth = 140; this.offsetHeight = 90;
  }
  setAttribute(key, value) {
    this.attrs[key] = String(value);
    if (key == 'id') this.id = String(value);
    if (key == 'value') this.value = String(value);
    if (key == 'checked') this.checked = true;
    if (key == 'disabled') this.disabled = true;
  }
  getAttribute(key) { return key in this.attrs ? this.attrs[key] : null; }
  get className() { return this.attrs.class || ''; }
  set className(value) { this.attrs.class = String(value); }
  get firstChild() { return this.kids[0] || null; }
  get lastChild() { return this.kids[this.kids.length - 1] || null; }
  get children() { return this.kids.filter(k => k.nodeType == 1); }
  get textContent() { return this.kids.map(k => k.nodeType == 3 ? k.text : k.textContent).join(''); }
  set textContent(value) { this.clear(); if (value !== '') this.append(String(value)); }
  clear() { this.kids.forEach(k => { k.parentNode = null; }); this.kids = []; }
  append(...kids) {
    for (const k of kids.flat(Infinity)) {
      if (k == null || k === false) continue;
      const node = typeof k == 'string' || typeof k == 'number' ? new Text(String(k)) : k;
      if (node.parentNode) node.parentNode.drop(node);
      node.parentNode = this; this.kids.push(node);
    }
  }
  replaceChildren(...kids) { this.clear(); if (kids.length) this.append(...kids); }
  drop(node) { const i = this.kids.indexOf(node); if (i >= 0) this.kids.splice(i, 1); }
  remove() { if (this.parentNode) this.parentNode.drop(this); }
  contains(node) { for (let x = node; x; x = x.parentNode) if (x === this) return true; return false; }
  walk(out = []) { for (const k of this.kids) if (k.nodeType == 1) { out.push(k); k.walk(out); } return out; }
  one(part) {
    if (part.startsWith('.')) return this.className.split(/\s+/).includes(part.slice(1));
    if (part.startsWith('#')) return this.id == part.slice(1);
    if (part.startsWith('[')) {
      const eq = part.indexOf('=');
      if (eq < 0) return this.getAttribute(part.slice(1, -1)) !== null;
      return this.getAttribute(part.slice(1, eq)) == part.slice(eq + 1, -1).replace(/^["']|["']$/g, '');
    }
    return this.tag == part;
  }
  matches(selector) {
    const parts = selector.split(',').map(s => s.trim()).filter(Boolean);
    return parts.some(p => this.compound(p.split(/\s+/)));
  }
  compound(tokens) {
    if (!tokens[tokens.length - 1].split(/(?=[.#[])/).every(t => t == '' || this.one(t))) return false;
    let node = this;
    for (let i = tokens.length - 2; i >= 0; i--) {
      let found = false;
      for (node = node.parentNode; node; node = node.parentNode) {
        if (node.nodeType == 1 && node.compound(tokens.slice(0, i + 1))) { found = true; node = node.parentNode; break; }
      }
      if (!found) return false;
    }
    return true;
  }
  querySelectorAll(selector) { return this.walk().filter(n => n.matches(selector)); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  getBoundingClientRect() { return { top: 0, left: 0, right: 12, bottom: 12 }; }
  scrollIntoView() {}
  focus() { document.activeElement = this; }
  get isConnected() { let n = this; while (n) { if (n === document.documentElement || n === document.body) return true; n = n.parentNode; } return false; }
  addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); }
  fire(type, event) {
    const e = Object.assign({ target: this, currentTarget: this, stopPropagation() {} }, event);
    (this.handlers[type] || []).forEach(fn => fn(e));
    // A browser runs an element's `onclick` property on click too, not only addEventListener.
    if (type == 'click' && typeof this.onclick == 'function') this.onclick(e);
  }
}
const document = {
  createElement: tag => new El(tag),
  createElementNS: (_ns, tag) => new El(tag),
  createTextNode: text => new Text(text),
  documentElement: new El('html'), body: new El('body'), activeElement: null, handlers: {},
  getElementById(id) { return this.body.walk().find(n => n.id == id) || null; },
  querySelector(s) { return this.querySelectorAll(s)[0] || null; },
  querySelectorAll(s) { return this.body.querySelectorAll(s); },
  addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
  removeEventListener(type, fn) { const list = this.handlers[type] || []; const at = list.indexOf(fn); if (at >= 0) list.splice(at, 1); },
};
document.documentElement.append(document.body);
document.activeElement = document.body;

// The controls the page's own header and footer name, so its handlers have something to attach to.
for (const m of markup.matchAll(/(?:^|\s)id=(\w+)/g)) {
  const node = document.createElement('div');
  node.setAttribute('id', m[1]);
  document.body.append(node);
}
assert(document.getElementById('main') && document.getElementById('q') && document.getElementById('addr') === null,
  'the fixture must hand the page the controls its markup declares');

const stored = new Map();
const localStorage = { getItem: k => (stored.has(k) ? stored.get(k) : null), setItem: (k, v) => stored.set(k, String(v)) };
const posts = [];
// A main-action click opens the page's own confirmation; its label is the action's verb.
function confirmAction(label) {
  const button = document.querySelectorAll('button').filter(b => b.textContent === label).pop();
  assert(button, 'the in-page confirmation offers ' + label);
  button.fire('click');
}
const window = { confirm: () => true, webkit: { messageHandlers: { khu: { postMessage: m => posts.push(m) } } } };
const ctx = vm.createContext({ document, window, localStorage, setInterval: () => 0, innerWidth: 1000, innerHeight: 800 });
vm.runInContext(script, ctx, { filename: 'LauncherPage.swift <script>' });
const run = code => vm.runInContext(code, ctx);
const render = state => run('render(' + JSON.stringify(state) + ')');

// --- the state the helper sends, in the shape LauncherWindow.reload() builds ---
const row = (over = {}) => Object.assign({
  id: 'story', name: 'Story KH', status: 'Updating…', managed: true, statusOnly: false, automatic: true, hidden: false,
  open: true, setup: false, canRollBack: false, helper: false, installed: '1.0.0', available: '1.1.0', reason: null,
  source: 'Feed', fromSSD: null, released: null, installedAt: null, bytes: 1000000, tagline: '', description: '',
  accent: null, features: [], notes: [], icon: '',
}, over);
const state = (apps, extra = {}) => Object.assign({
  apps, sources: ['ATLAS'], error: null, lastRun: null, version: '0.1.15', whatsNew: [], paused: false,
  settings: { checkManually: false, autoInstall: true, notify: false, appearance: 'system', menuBarWhenClosed: true, retireHelpers: false, helperCleanupAvailable: true, helperHealthySeconds: 600 },
  connection: { destination: 'http://100.64.0.7:8790/release.json', machine: 'mac-a', checking: false, checkedAt: null, ok: null, note: null, serverNote: null, serverOk: null, pairAvailable: false },
}, extra);
const downloading = (done, over = {}) => Object.assign({ phase: 'downloading', done, total: 1000000, paused: false, cancelled: false }, over);
const line = () => (document.querySelector('.line') || {}).textContent;
const titles = selector => document.querySelectorAll(selector).map(b => b.getAttribute('title')).filter(Boolean);

// R1 a transfer tick must not rebuild the page: that rebuild was the flicker.
render(state([row({ progress: downloading(300000) })]));
const card = document.querySelector('.card'), fill = document.querySelector('.bar i');
assert(card, 'R1 an installing app is drawn with its progress');
assert.equal(line(), 'Downloading 300 KB of 1 MB · 30%', 'R1 the actual counters are shown');
assert.equal(fill.style.width, '30%', 'R1 the bar is filled to the same amount');
render(state([row({ progress: downloading(600000) })]));
assert.equal(document.querySelector('.card'), card, 'R1 counters moving must not replace the card');
const prog = document.querySelector('[data-prog]');
assert(prog && card.contains(prog), 'R1 the counters live in a named region, updated in place');
assert.equal(line(), 'Downloading 600 KB of 1 MB · 60%', 'R1 the counters still move');
assert.equal(fill.style.width, '60%', 'R1 the bar still follows them');
render(state([row({ progress: downloading(600000) })]));
assert.equal(document.querySelector('.card'), card, 'R1 a push that says nothing new redraws nothing');

// R2 an open dialog keeps its nodes, its typed text and its focus while work runs.
run('settingsOpen=true;drawSettings()');
const sheet = document.querySelector('.scrim.s .sheet');
assert(sheet && sheet.getAttribute('aria-modal') == 'true', 'R2 Settings opens as a modal dialog');
const addr = document.getElementById('addr');
addr.focus();
addr.value = 'http://10.0.0.9:8790/release.json';
addr.fire('input');
render(state([row({ progress: downloading(700000) })]));
assert.equal(document.querySelector('.scrim.s .sheet'), sheet, 'R2 a transfer tick must not rebuild the open dialog');
assert.equal(document.getElementById('addr'), addr, 'R2 …nor replace the field the person is typing in');
assert.equal(addr.value, 'http://10.0.0.9:8790/release.json', 'R2 what was typed is not thrown away');
assert.equal(document.activeElement, addr, 'R2 focus stays where the person left it');

// R3 real news does redraw, and the redraw must not replay the dialog's entrance or lose the draft.
const failed = 'the app did not quit; nothing was changed';
render(state([row({ status: 'Failed', reason: failed })], { error: failed }));
const redrawn = document.querySelector('.scrim.s .sheet');
assert(redrawn && redrawn !== sheet, 'R3 a real change does refresh the open dialog');
assert.match(redrawn.style.cssText || '', /animation:\s*none/, 'R3 …without replaying its entry animation (the flash)');
assert.equal(document.getElementById('addr').value, 'http://10.0.0.9:8790/release.json', 'R3 the unapplied draft outlives the redraw');
assert.equal(document.activeElement, document.getElementById('addr'), 'R3 focus is handed back to the same control');
assert.match(document.getElementById('err').textContent, /^Last check failed: the app did not quit/, 'R3 the failure is said loudly, in the footer too');

// R4 a stopped attempt must never read as ongoing work.
render(state([row({ progress: downloading(800000, { phase: 'installing', cancelled: true }) })], { error: null }));
assert.equal(line(), 'Stopping…', 'R4 a cancelled transfer says it is stopping, not Installing…');
assert(!titles('.card button').includes('Cancel'), 'R4 …and does not offer to cancel work already stopping');

// R5 a row being worked on shows its recorded failure as the attempt before, not as this one.
render(state([row({ status: 'Updating…', reason: failed, retrying: true, progress: { phase: 'preparing', cancelled: false, paused: false } })]));
assert.match(document.querySelector('.card .reason').textContent, /^Last attempt: the app did not quit; nothing was changed\.$/,
  'R5 a retried app says whose failure it is, in full, instead of pairing "Failed" with a live progress bar');
assert.equal(line(), 'Preparing installation…', 'R5 the live phase of this attempt is shown beside it');
assert.match(document.querySelector('.card .chip').textContent, /^Updating$/, 'R5 the row itself reads as running, not as failed');
render(state([row({ status: 'Failed', reason: failed })]));
assert.equal(document.querySelector('.card .reason').textContent, 'the app did not quit; nothing was changed.',
  'R5 a row that is not being worked on shows its failure plainly and whole, with no progress bar');
assert(!document.querySelector('[data-prog]'), 'R5 …and nothing about it looks like ongoing work');

// R6 an indeterminate bar keeps its element, so its animation runs instead of restarting twice a second.
render(state([row({ progress: { phase: 'installing', paused: false, cancelled: false } })]));
const loose = document.querySelector('.bar.loose');
assert(loose, 'R6 an install with no counters shows a running bar');
render(state([row({ progress: { phase: 'installing', paused: false, cancelled: false } })]));
assert.equal(document.querySelector('.bar.loose'), loose, 'R6 a second push leaves that bar alone');

// R7 the controls still reach the helper, and search keeps working after a push.
render(state([row({ progress: downloading(600000, { paused: true }) })]));
const resume = document.querySelectorAll('.card button').find(b => b.getAttribute('title') == 'Resume');
assert(resume, 'R7 a paused download offers Resume');
posts.length = 0;
resume.fire('click');
assert.equal(posts.length, 1, 'R7 the click sends exactly one request');
assert.equal(posts[0].action, 'pause');
assert.equal(posts[0].on, false, 'R7 clicking Resume asks the helper to resume that transfer');
document.getElementById('q').focus();
render(state([row({ status: 'Update available', installed: '1.0.0', available: '1.2.0' })], { error: null }));
assert.equal(document.activeElement, document.getElementById('q'), 'R7 the search box keeps focus across a real change');

// Source choice is explicit, with honest unknowns and no claim that full fallback saves bytes.
run('settingsOpen=false;detail=null;closeLayers()');
render(state([row({ id:'new-app', managed:false, installed:null, status:'Not installed', available:'2.0', serverVersion:'2.0', ssdVersion:'1.0', initialSSD:'Test SSD · 1.0' })]));
run("openDetail('new-app')");
assert.match(document.querySelector('.facts').textContent, /Server2.0SSD1.0/, 'source comparison shows each version separately');
assert.match(document.querySelector('.sheet').textContent, /Then Update offers the newer server version/, 'older SSD first install explains the next step');
run("openMenu(S.apps[0],document.querySelector('.card'))");
const older = document.querySelectorAll('.menu button').find(b=>b.textContent.startsWith('Install from Test SSD'));
assert(older, 'older SSD first install remains available');
posts.length=0; older.fire('click');
assert.equal(posts[0].action,'installSSD');
assert.equal(posts[0].app,'new-app');
render(state([row({ status:'Updating…', progress:{phase:'delta-downloading',done:100000,total:200000} })]));
assert.equal(line(),'Downloading changed data 100 KB of 200 KB · 50%','delta uses transferred bytes, not full artifact size');
render(state([row({ status:'Updating…', progress:{phase:'full-fallback',done:100000,total:1000000} })]));
assert.equal(line(),'Downloading full installer 100 KB of 1 MB · 10%','full fallback makes no savings claim');
render(state([row({ status:'Updating…', progress:{phase:'reconstructing'} })]));
assert.equal(line(),'Rebuilding and verifying installer…');
render(state([row({ status:'Not installed',managed:false,installed:null,serverVersion:null,ssdVersion:'1.0' })],{error:'Update Studio is unreachable. Server versions are unknown.'}));
run("openDetail('story')");
assert.match(document.querySelector('.facts').textContent,/ServerUnknown/,'offline never claims a current server version');
assert.match(document.getElementById('err').textContent,/unreachable/);
// A focused text field owns its arrow keys; details navigation must not consume them.
const beforeDetail=run('detail.id');
for(const handler of document.handlers.keydown||[]) handler({key:'ArrowRight',target:{tagName:'INPUT'}});
assert.equal(run('detail.id'),beforeDetail);
// An app that updates itself is still installed or updated by hand, when the person asks for it.
run('settingsOpen=false;detail=null;closeLayers()');
render(state([row({ id:'story', statusOnly:true, manuallyInstallable:true, managed:false, installed:null, available:'2.0', status:'Not installed' })]));
let manual=document.querySelectorAll('.card button').find(b=>b.textContent=='Install');
assert(manual,'a self-updating app with an installer offers Install');
posts.length=0; manual.fire('click'); confirmAction('Install');
assert.equal(posts[0].action,'install');
assert.equal(posts[0].app,'story');
render(state([row({ id:'story', statusOnly:true, manuallyInstallable:true, managed:true, installed:'1.0', available:'2.0', status:'Update available' })]));
manual=document.querySelectorAll('.card button').find(b=>b.textContent=='Update');
assert(manual,'an installed self-updating app with a newer version offers Update');
posts.length=0; manual.fire('click'); confirmAction('Update');
assert.equal(posts[0].action,'update');
render(state([row({ id:'story', statusOnly:true, manuallyInstallable:false, managed:false, installed:null, available:null, status:'Updates itself', setup:true })]));
assert(!document.querySelectorAll('.card button').find(b=>b.textContent=='Install'),'a self-updating app with no installer offers no Install');
assert(document.querySelectorAll('.card button').find(b=>b.textContent=='Open Setup Folder'),'its setup folder stays the way in');
// The hand route follows the agent's comparison, never the raw version strings.
render(state([row({ id:'story', statusOnly:true, manuallyInstallable:true, managed:true, installed:'2.0', available:'1.0', status:'Updates itself' })]));
assert(!document.querySelectorAll('.card button').find(b=>b.textContent=='Update'),'a newer installed self-updating app offers no Update');
assert.equal(run('mainAction(S.apps[0])[1]'),'open','the newer install is left to its own updater');
render(state([row({ id:'story', statusOnly:true, manuallyInstallable:true, managed:true, installed:'1.0.0-beta', available:'2.0', status:'Updates itself' })]));
assert.equal(run('mainAction(S.apps[0])')?.[1],'open','an incomparable installed version is never offered an Update');
// An app with no hand route keeps its own updater or its SSD setup, and says which.
for (const id of ['story','hub']) {
  run('settingsOpen=false;detail=null;closeLayers()');
  const own = row({id,name:id,status:'Not installed',managed:false,statusOnly:true,automatic:false,installed:null,open:false,setup:true});
  render(state([own]));
  posts.length=0;
  const setup = document.querySelectorAll('.card button').find(b=>b.textContent=='Open Setup Folder');
  assert(setup, id+' offers its existing manual SSD setup route');
  setup.fire('click');
  assert.equal(posts[0].action,'setup');
  assert.equal(posts[0].app,id);
  render(state([Object.assign({},own,{setup:false})]));
  run('openDetail('+JSON.stringify(id)+')');
  assert.match(document.querySelector('.sheet').textContent,/Remote installation through Launcher is not available/);
  assert.equal(run('mainAction(S.apps[0])'),null,id+' does not invent an install action without its setup');
  render(state([Object.assign({},own,{setup:false,managed:true,installed:'1.0',open:true})]));
  assert.equal(run('mainAction(S.apps[0])[1]'),'open',id+' opens the installed app for its own updater');
  run('openMenu(S.apps[0],document.querySelector(".card"))');
  assert(!document.querySelector('.menu').textContent.includes('Update automatically'));
}
// A failed check keeps the last successful freshness value and a separate failure time.
const checked='2026-11-11T00:00:00Z', attempted='2026-11-11T01:00:00Z';
render(state([row({status:'Up to date'})],{lastRun:checked,lastAttempt:attempted,error:'Offline',serverKnown:false}));
assert.equal(run('S.lastRun'),checked,'a failed check does not rewrite when the server last answered');
assert.match(document.getElementById('err').textContent,/Offline · /);
assert.match(document.getElementById('checked').textContent,/Server versions unknown/);
// Ordinary settings report their save; an address remains an explicit consequential action.
run('detail=null;settingsOpen=true;closeLayers();drawSettings()');
render(state([row()],{settingsNote:'Saved.'}));
assert.match(document.querySelector('.scrim.s .sheet').textContent,/Saved\./);
posts.length=0;
let draft=document.getElementById('addr');
draft.value='http://100.64.0.9:8790/release.json'; draft.fire('input');
assert.equal(posts.length,0,'typing an address never connects, enrolls or installs');
document.querySelectorAll('.scrim.s button').find(b=>b.textContent=='Use this address').fire('click');
assert.equal(posts[0].action,'changeServer');
const failedConnection=Object.assign({},state([]).connection,{serverOk:false,serverNote:'Address refused'});
render(state([row()],{settingsNote:'Could not save that change. Your previous settings are kept.',connection:failedConnection}));
assert.match(document.querySelector('.scrim.s .sheet').textContent,/Could not save that change/);
assert.equal(document.getElementById('addr').value,'http://100.64.0.9:8790/release.json','failed address check retains the editable draft');

// The Automatic switch names which setting it follows, in the agent's own words for its own decision.
run('settingsOpen=false;detail=null;closeLayers()');
for (const words of ['Set on this Mac','Set in Update Studio','This Mac’s default']) {
  render(state([row({status:'Up to date',automatic:words=='Set on this Mac',automaticOrigin:words})]));
  posts.length=0;
  run("openMenu(S.apps[0],document.querySelector('.card'))");
  const why=document.querySelector('.menu .why');
  assert(why&&why.textContent==words,words+' — the switch says which of the three settings rules');
  assert(!document.querySelectorAll('.menu button').some(b=>b.textContent.includes(words)),'the origin is a caption, never a control');
  assert.equal(posts.length,0,'a caption is not something the page acts on');
}
const box=document.querySelectorAll('.menu button').find(b=>b.getAttribute('role')=='menuitemcheckbox');
assert.equal(box.getAttribute('aria-describedby'),'automatic-origin-story','the switch is announced with its origin');
posts.length=0; box.fire('click');
assert.deepEqual(posts.map(p=>p.action),['automatic'],'the switch itself still sends exactly one request');
render(state([row({status:'Up to date',automatic:true})]));
posts.length=0; run("openMenu(S.apps[0],document.querySelector('.card'))");
assert(!document.querySelector('.menu .why'),'an origin the helper did not say is left unsaid, not guessed');
assert.equal(posts.length,0);
// A drive's copy that could not be used says why; the source in use says what it is. Neither claims
// a saving, a speed or readiness the helper has not proved.
run('settingsOpen=false;detail=null;closeLayers()');
const refused='The copy on ATLAS is not the bytes the server signed for 2.0.';
render(state([row({status:'Update available',installed:'1.0',available:'2.0',ssdNote:refused,fromSSD:null,ssdVersion:null})]));
run("openDetail('story')");
const sheetRefused=document.querySelector('.sheet').textContent;
assert.match(document.querySelector('.facts').textContent,/SSDNot used/,'a refused drive copy reads as not used, not as fine');
assert.match(sheetRefused,/not the bytes the server signed/,"the drive's own refusal reason is shown in full");
assert.doesNotMatch(sheetRefused,/saves|faster|ready to install|no download/,'no saving or readiness is implied');
render(state([row({status:'Up to date',installed:'2.0',available:'2.0',fromSSD:'ATLAS',source:'ATLAS',ssdVersion:'2.0',ssdNote:'The copy on NOVA is not the bytes the server signed for 2.0.'})]));
run("openDetail('story')");
const sheetSSD=document.querySelector('.sheet').textContent;
assert.match(sheetSSD,/The version on offer is the copy on ATLAS, read from that drive\./,'the source in use is named');
assert.doesNotMatch(sheetSSD,/NOVA/,'a drive that is not the source is not talked about');
render(state([row({status:'Update available',installed:'1.0',available:'2.0',fromSSD:null,source:'Feed',ssdNote:null,ssdVersion:null})]));
run("openDetail('story')");
assert.match(document.querySelector('.sheet').textContent,/comes from the signed feed, so its installer is downloaded/,'a feed offer is a download, said plainly');
// Settings says what leaves this Mac, where its own files stay, and the limits the updater applies.
run('detail=null;settingsOpen=true;closeLayers();drawSettings()');
posts.length=0;
render(state([row()],{stateDir:'/Users/test/Library/KHUpdater',replyLimitBytes:8388608}));
const said=document.querySelector('.scrim.s .sheet').textContent;
assert.match(said,/Update Studio is told this Mac’s name/,'what the controller is told is written out');
assert.match(said,/under \/Users\/test\/Library\/KHUpdater/,'the folder this Mac keeps its files in is named');
assert.match(said,/restorable _trash/,'replaced files are retired, not deleted');
assert.match(said,/a reply bigger than 8 MB is refused rather than buffered/,'the cap shown is the cap the updater carries');
assert.match(said,/no separate storage budget to set here/,'no budget is offered that nothing enforces');
assert.match(said,/A switch set on this Mac rules while it is the later change/,'the three-way rule is stated once, beside the switches');
assert.equal(posts.length,0,'reading the explanation sends nothing and starts nothing');
render(state([row()],{stateDir:null,replyLimitBytes:null}));
const unsaid=document.querySelector('.scrim.s .sheet').textContent;
assert.doesNotMatch(unsaid,/is refused rather than buffered/,'a limit the helper did not send is not stated as a number');
assert.match(unsaid,/this Mac’s own updater folder/,'the folder is still named in plain words');
// R9 What's New is the page's own pop-up, not a native alert: it shows the notes already in the
// state, sends nothing, and closes with one Done or Esc.
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers()');
const versionNotes = ['Opens What’s New in one simple pop-up.', 'Keeps your settings.'];
render(state([row({ status: 'Up to date' })], { version: '0.1.19', whatsNew: versionNotes }));
posts.length = 0;
document.getElementById('whatsNew').fire('click');
const wnSheet = document.querySelector('.scrim.w .sheet');
assert(wnSheet && wnSheet.getAttribute('aria-modal') == 'true', 'R9 What’s New opens as the page’s own modal dialog');
assert.match(wnSheet.textContent, /What’s New/, 'R9 the dialog is titled What’s New');
assert.match(wnSheet.textContent, /0\.1\.19/, 'R9 the current version sits beside the title');
assert.match(wnSheet.textContent, /one simple pop-up/, 'R9 the version’s own notes are shown');
assert.equal(document.querySelectorAll('.scrim.w .bottom button').length, 1, 'R9 there is exactly one Done button');
assert.equal(posts.length, 0, 'R9 opening it asks the helper for nothing');
for (const handler of document.handlers.keydown || []) handler({ key: 'Escape', target: { tagName: 'BODY' } });
assert(!document.querySelector('.scrim.w') && !run('whatsNewOpen'), 'R9 Esc closes it');
run('showWhatsNew()');
document.querySelector('.scrim.w .bottom button').fire('click');
assert(!document.querySelector('.scrim.w') && !run('whatsNewOpen'), 'R9 Done closes it');
render(state([row({ status: 'Up to date' })], { version: '0.1.19', whatsNew: [] }));
run('showWhatsNew()');
assert.match(document.querySelector('.scrim.w .sheet').textContent, /No notes for this version\./, 'R9 an empty changelog is said plainly');
// R10 the footer group: the version pill, an icon-only check, and an update button only when a
// newer Launcher is really offered; Support posts its own action.
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers()');
render(state([row({ id: 'updater', name: 'Studio Launcher KH', status: 'Update available', available: '0.1.21', installed: '0.1.20' })], { version: '0.1.20' }));
assert.match(document.getElementById('wnver').textContent, /v0\.1\.20/, 'R10 the pill carries this version');
assert.equal(document.getElementById('update').hidden, false, 'R10 a real offer shows the small update button');
assert.match(document.getElementById('update').getAttribute('aria-label'), /0\.1\.21/, 'R10 the button names the offered version');
render(state([row({ id: 'updater', status: 'Up to date', available: '0.1.20', installed: '0.1.20' })], { version: '0.1.20' }));
assert.equal(document.getElementById('update').hidden, true, 'R10 no offer, no button');
posts.length = 0;
document.getElementById('support').fire('click');
assert.equal(posts.length, 1, 'R10 Support posts one message');
assert.equal(posts[0] && posts[0].action, 'support', 'R10 Support asks the app to open the donation page, nothing else');
// R11 an empty app list says which publisher could not be reached, instead of "Checking…" forever.
render(state([], { error: 'The request timed out.' }));
assert.match(document.querySelector('.empty').textContent, /could not be reached: The request timed out\./, 'R11 an empty list names the failure');
assert.match(document.querySelector('.empty').textContent, /100\.64\.0\.7/, 'R11 and the address it tried');
render(state([]));
assert.match(document.querySelector('.empty').textContent, /^Checking…$/, 'R11 a first load still says Checking…');
// R12 the appearance segment offers exactly System, Light and Dark — no Default.
assert(!script.includes("'default','Default'"), 'R12 the appearance segment no longer offers Default');
assert.match(script, /\['system','System'\],\['light','Light'\],\['dark','Dark'\]/, 'R12 exactly three appearance choices');
// R13 a click is acknowledged at once: the row says the update is being received and offers no
// second action while it waits; an app with no recipe the agent would run draws no Install at all.
render(state([row({ status: 'Receiving update…' })]));
assert.match(document.querySelector('.card').textContent, /Receiving update…/, 'R13 a queued install says it is being received');
assert.equal(document.querySelectorAll('.card .btn.main').length, 0, 'R13 …and offers no second action while it waits');
render(state([row({ id: 'bad', name: 'Bad KH', status: 'Not installed', managed: false, installed: null,
                    available: '1.0', installable: false })]));
assert.equal(document.querySelectorAll('.card .btn.main').length, 0, 'R13 an app with no recipe the agent would run draws no Install');
render(state([row({ id: 'new-kh', name: 'New KH', status: 'Not installed', managed: false, installed: null,
                    available: '1.0', installable: true })]));
assert.equal(document.querySelectorAll('.card .btn.main').length, 1, 'R13 an installable new app still offers Install');

// R14 the release's own failure reason is shown whole: the job label is never cut mid-identifier and
// the next step is still there. plain() used to split on any '.', so "…launchctl bootstrap com."
// was all a person saw.
const restartReason = 'the app was installed but its background service did not restart (launchctl bootstrap com.theng12.printerstudio.airprint did not load the job (exited 5)); the install is kept and the next run tries again';
const shownReason = run('plain(' + JSON.stringify(restartReason) + ')');
assert.match(shownReason, /com\.theng12\.printerstudio\.airprint/, 'R14 the job label survives whole');
assert.match(shownReason, /exited 5/, 'R14 the exit code is shown');
assert.match(shownReason, /next run tries again/, 'R14 the next step is shown');
assert.doesNotMatch(shownReason, /com\.$/, 'R14 the reason never ends on a cut identifier');
const longReason = 'the app was installed but its background service did not restart (launchctl bootstrap com.example.a.very.long.job.label did not load the job (exited 7)); ' + 'x'.repeat(220);
const cutReason = run('plain(' + JSON.stringify(longReason) + ')');
assert.match(cutReason, /com\.example\.a\.very\.long\.job\.label/, 'R14 a long reason is cut only after a whole label');
assert.match(cutReason, /exited 7/, 'R14 and keeps the exit code');

// R15 the in-page confirmation is a real modal: the confirm button takes focus, Escape cancels,
// Tab stays inside the two buttons, and a click on the backdrop cancels.
const keyCountBefore = (document.handlers.keydown || []).length;
run('window.askAnswer=null; ask("Update Studio KH to 1.0.39?", "Update", r => { window.askAnswer = r })');
const askDialog = () => document.querySelector('[role=dialog]');
assert.equal((document.handlers.keydown || []).length, keyCountBefore + 1, 'R15 the dialog adds one key handler while it is open');
const askButtons = () => document.querySelectorAll('[role=dialog] button');
assert(askDialog(), 'R15 the confirmation opens as a dialog');
assert.equal(document.activeElement, askButtons()[1], 'R15 the confirm button takes focus on open');
for (const handler of [...(document.handlers.keydown || [])]) handler({ key: 'Tab' });
assert.equal(document.activeElement, askButtons()[0], 'R15 Tab moves to Cancel, inside the dialog');
for (const handler of [...(document.handlers.keydown || [])]) handler({ key: 'Tab' });
assert.equal(document.activeElement, askButtons()[1], 'R15 Tab wraps back to the confirm button');
for (const handler of [...(document.handlers.keydown || [])]) handler({ key: 'Escape' });
assert.equal(askDialog(), null, 'R15 Escape closes it');
assert.equal(run('window.askAnswer'), false, 'R15 Escape answers Cancel');
assert.equal((document.handlers.keydown || []).length, keyCountBefore, 'R15 its key listener is removed with it');
run('window.askAnswer=null; ask("Update Studio KH to 1.0.39?", "Update", r => { window.askAnswer = r })');
askDialog().fire('click');
assert.equal(askDialog(), null, 'R15 a click on the backdrop closes it');
assert.equal(run('window.askAnswer'), false, 'R15 a backdrop click answers Cancel');
run('window.askAnswer=null; ask("Update Studio KH to 1.0.39?", "Update", r => { window.askAnswer = r })');
askButtons()[1].fire('click');
assert.equal(run('window.askAnswer'), true, 'R15 the confirm button answers yes');


// R16 the card shows the whole reason: no line clamp on .reason, and a rendered failure card carries
// the job label, the exit code and the next step. The CSS used to clamp it to two lines, so the text
// existed but a person saw 86 of 204 characters.
const reasonRule = (source.match(/\.reason\{[^}]*\}/) || [''])[0];
assert(reasonRule && !/line-clamp|overflow:hidden/.test(reasonRule), 'R16 .reason is not line-clamped');
assert(/\.tablewrap\{[^}]*overflow-x:auto/.test(source), 'R16 the list table scrolls inside its own box');
assert(/header\{[^}]*flex-wrap:wrap/.test(source), 'R16 the header wraps instead of pushing controls off-screen');
assert(/#hiddenNote\{display:none\}/.test(source), 'R16 the hidden-apps note is dropped at the narrow width');
assert(/\.sheet\{[^}]*max-height:calc\(100dvh - 68px\)/.test(source), 'R16 a sheet cannot grow past the window');
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers()');
render(state([row({ status: 'Failed', reason: restartReason })]));
const renderedReason = document.querySelector('.card .reason').textContent;
assert.match(renderedReason, /com\.theng12\.printerstudio\.airprint/, 'R16 the card carries the whole job label');
assert.match(renderedReason, /exited 5/, 'R16 the card carries the exit code');
assert.match(renderedReason, /next run tries again/, 'R16 the card carries the next step');

// R17 the confirmation returns focus to whatever opened it.
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers()');
render(state([row({ status: 'Up to date' })]));
document.getElementById('gear').focus();
const opener = document.activeElement;
run('ask("Update Studio KH to 1.0.39?", "Update", () => {})');
for (const handler of [...(document.handlers.keydown || [])]) handler({ key: 'Escape' });
assert.equal(document.activeElement, opener, 'R17 closing the confirmation returns focus to its opener');


// R17b a helper state push can redraw the row that opened the confirmation, detaching it; closing
// must then land on the always-present Settings button, never on the window body.
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers()');
render(state([row({ status: 'Update available', available: '2.0.0', installed: '1.0.0' })]));
const rowOpener = document.querySelector('.card .btn.main');
rowOpener.focus();
run('ask("Update Studio KH to 1.0.41?", "Update", () => {})');
render(state([row({ status: 'Update available', available: '2.0.0', installed: '1.0.0' }),
             row({ id: 'second', name: 'Second KH', status: 'Up to date', installed: '1.0.0', available: '1.0.0' })]));
assert.equal(rowOpener.isConnected, false, 'R17b the redraw detached the opening row button');
for (const handler of [...(document.handlers.keydown || [])]) handler({ key: 'Escape' });
assert(document.activeElement && document.activeElement.id === 'gear',
  'R17b focus falls back to the connected Settings button, never the body');
assert.notEqual(document.activeElement, document.body, 'R17b focus is never left on the body');
console.log('PASS: Launcher rendering, source choices and refusal reasons, offline state, delta/fallback bytes, editing focus, Story/Hub routes, Automatic origin, data-flow limits, save feedback, the page’s own What’s New pop-up, the footer group, the click’s immediate feedback and the empty list’s reason');
