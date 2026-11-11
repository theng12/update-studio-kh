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
      return this.getAttribute(part.slice(1, eq)) == part.slice(eq + 1).replace(/^["']|["']$/g, '');
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
  addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); }
  fire(type, event) {
    const e = Object.assign({ target: this, currentTarget: this, stopPropagation() {} }, event);
    (this.handlers[type] || []).forEach(fn => fn(e));
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
const window = { webkit: { messageHandlers: { khu: { postMessage: m => posts.push(m) } } } };
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
assert.match(document.querySelector('.card .reason').textContent, /^Last attempt: the app did not quit\.$/,
  'R5 a retried app says whose failure it is instead of pairing "Failed" with a live progress bar');
assert.equal(line(), 'Preparing installation…', 'R5 the live phase of this attempt is shown beside it');
assert.match(document.querySelector('.card .chip').textContent, /^Updating$/, 'R5 the row itself reads as running, not as failed');
render(state([row({ status: 'Failed', reason: failed })]));
assert.equal(document.querySelector('.card .reason').textContent, 'the app did not quit.',
  'R5 a row that is not being worked on shows its failure plainly, with no progress bar');
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
posts.length=0; manual.fire('click');
assert.equal(posts[0].action,'install');
assert.equal(posts[0].app,'story');
render(state([row({ id:'story', statusOnly:true, manuallyInstallable:true, managed:true, installed:'1.0', available:'2.0', status:'Update available' })]));
manual=document.querySelectorAll('.card button').find(b=>b.textContent=='Update');
assert(manual,'an installed self-updating app with a newer version offers Update');
posts.length=0; manual.fire('click');
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
console.log('PASS: Launcher rendering, source choices, offline state, delta/fallback bytes, editing focus, Story/Hub routes and save feedback');
