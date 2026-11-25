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
    const e = Object.assign({ target: this, currentTarget: this, stopPropagation() {}, preventDefault() {} }, event);
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
// The Show filter is three named buttons in the real header. Built from that markup, so a label or a
// value that changes in the page changes here too instead of the test quietly testing nothing.
const segMarkup = markup.slice(markup.indexOf('id=instseg'), markup.indexOf('</div>', markup.indexOf('id=instseg')));
const segButtons = [...segMarkup.matchAll(/data-inst=(\w+) aria-pressed=(\w+)>([^<]+)</g)];
assert.equal(segButtons.length, 3, 'the header declares the three Show filters');
for (const m of segButtons) {
  const b = document.createElement('button');
  b.setAttribute('data-inst', m[1]); b.setAttribute('aria-pressed', m[2]); b.textContent = m[3];
  document.getElementById('instseg').append(b);
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
  connection: { destination: 'http://100.64.0.7:8790/release.json', machine: 'mac-a', checking: false, checkedAt: null, ok: null, note: null, serverNote: null, serverOk: null, pairAvailable: false, canLeave: false, studio: true },
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
const searchBox = document.getElementById('q');
searchBox.focus();
searchBox.value = 'sto';
render(state([row({ progress: downloading(700000) })]));
assert.equal(document.querySelector('.scrim.s .sheet'), sheet, 'R2 a transfer tick must not rebuild the open dialog');
assert.equal(document.getElementById('q'), searchBox, 'R2 …nor replace the field the person is typing in');
assert.equal(searchBox.value, 'sto', 'R2 what was typed is not thrown away');
assert.equal(document.activeElement, searchBox, 'R2 focus stays where the person left it');

// R3 real news does redraw, and the redraw must not replay the dialog's entrance or lose the draft.
const failed = 'the app did not quit; nothing was changed';
render(state([row({ status: 'Failed', reason: failed })], { error: failed }));
const redrawn = document.querySelector('.scrim.s .sheet');
assert(redrawn && redrawn !== sheet, 'R3 a real change does refresh the open dialog');
assert.match(redrawn.style.cssText || '', /animation:\s*none/, 'R3 …without replaying its entry animation (the flash)');
assert.equal(document.getElementById('q').value, 'sto', 'R3 what was typed outlives the redraw');
assert.equal(document.activeElement, document.getElementById('q'), 'R3 focus is handed back to the same control');
run('q="";document.getElementById("q").value=""');
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
// Source order (owner, 2026-11-24): one comparison, both directions, always visible. A drive's
// older copy is named as older and offered only as a deliberate choice; a newer one is named as
// newer and is the offer; an installed app is compared with every source too. The sentence comes
// from the agent's own comparison, so the page cannot answer the question a second way.
// A: first install, the feed newer than the drive's copy.
render(state([row({ id:'new-app', managed:false, installed:null, status:'Not installed', available:'0.1.81',
                    serverVersion:'0.1.81', ssdVersion:'0.1.75', initialSSD:'ATLAS · 0.1.75', initialSSDNewer:false,
                    sourcesText:'This Mac has no copy yet; ATLAS carries 0.1.75, older; the saved feed has 0.1.81.' })]));
assert.match(document.querySelector('.card .src').textContent,/ATLAS carries 0\.1\.75, older/,'A: the card names both versions in one sentence');
assert.match(document.querySelector('.card .src').textContent,/the saved feed has 0\.1\.81/);
run("openDetail('new-app')");
assert.match(document.querySelector('.facts').textContent,/Server0\.1\.81SSD0\.1\.75/,'A: both versions are shown side by side');
assert.match(document.querySelector('.sheet').textContent,/ATLAS carries 0\.1\.75, older/,'A: the sheet carries the same sentence');
run("openMenu(S.apps[0],document.querySelector('.card'))");
const older=document.querySelectorAll('.menu button').find(b=>b.textContent=='Copy 0.1.75 from ATLAS anyway');
assert(older,'A: the older copy is still offered, as a choice, never hidden');
assert(!document.querySelectorAll('.menu button').some(b=>b.textContent.startsWith('Install from ATLAS')),'A: and never as the install');
posts.length=0; older.fire('click');
assert.equal(posts[0].action,'installSSD'); assert.equal(posts[0].app,'new-app');
// B: first install, the drive newer than a stale feed — the drive is the better copy.
render(state([row({ id:'offline-app', managed:false, installed:null, status:'Not installed', available:'1.2',
                    serverVersion:'1.0', ssdVersion:'1.2', initialSSD:'NOVA · 1.2', initialSSDNewer:true,
                    sourcesText:'This Mac has no copy yet; NOVA carries 1.2, newer; the saved feed has 1.0.' })]));
run("openMenu(S.apps[0],document.querySelector('.card'))");
assert(document.querySelectorAll('.menu button').some(b=>b.textContent=='Install from NOVA · 1.2 first'),'B: a newer drive copy is offered as the install');
// C: installed from the drive, and the same drive carries a newer copy — it must be offered.
render(state([row({ id:'hub', managed:true, installed:'0.6.255', available:'0.6.256', status:'Update available',
                    sourcesText:'This Mac has 0.6.255; ATLAS carries 0.6.256, newer.' })]));
assert.match(document.querySelector('.card .src').textContent,/This Mac has 0\.6\.255; ATLAS carries 0\.6\.256, newer/,'C: the newer copy is named');
assert(document.querySelectorAll('.card button').some(b=>b.textContent=='Update'),'C: and it is offered as the update');
// D: installed newer than the drive's copy — the drive copy is older, never an upgrade.
render(state([row({ id:'hub', managed:true, installed:'0.6.256', available:'0.6.256', status:'Up to date',
                    sourcesText:'This Mac has 0.6.256; ATLAS carries 0.6.255, older.' })]));
assert.match(document.querySelector('.card .src').textContent,/ATLAS carries 0\.6\.255, older/,'D: the drive copy is named as older');
assert(!document.querySelectorAll('.card button').some(b=>b.textContent=='Update'),'D: and it is not offered as an upgrade');
// E: a source that cannot be compared is named unknown, never treated as current.
render(state([row({ id:'hub', managed:true, installed:'0.6.255', available:'0.6.255', status:'Up to date',
                    sourcesText:'This Mac has 0.6.255; ATLAS carries a copy that cannot be compared.' })]));
assert.match(document.querySelector('.card .src').textContent,/cannot be compared/,'E: an unreadable copy is unknown, not current');
render(state([row({ status:'Updating…', progress:{phase:'delta-downloading',done:100000,total:200000} })]));
assert.equal(line(),'Downloading changed data 100 KB of 200 KB · 50%','delta uses transferred bytes, not full artifact size');
render(state([row({ status:'Updating…', progress:{phase:'full-fallback',done:100000,total:1000000} })]));
assert.equal(line(),'Downloading full installer 100 KB of 1 MB · 10%','full fallback makes no savings claim');
render(state([row({ status:'Updating…', progress:{phase:'reconstructing'} })]));
assert.equal(line(),'Rebuilding and verifying installer…');
render(state([row({ status:'Updating…', progress:{phase:'held'} })]));
assert.equal(line(),'Held new work · settling what is in flight…','the hold gap says what it is doing, not a stall');
render(state([row({ status:'Updating…', progress:{phase:'resumed'} })]));
assert.equal(line(),'Resuming work…');
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
assert(!/Checked /.test(document.getElementById('checked').textContent), 'a failed check does not claim verified source coverage');
// Ordinary settings report their save; the feed's address is never a field a screen retypes, and
// the screen is one line plus one button unless a non-default address is saved.
run('detail=null;settingsOpen=true;closeLayers();drawSettings()');
render(state([row()],{settingsNote:'Saved.'}));
assert.match(document.querySelector('.scrim.s .sheet').textContent,/Saved\./);
posts.length=0;
const notifyBox=document.querySelectorAll('.scrim.s input[type=checkbox]').find(i=>i.parentNode&&/Notify me when an update is ready/.test(i.parentNode.textContent));
assert(notifyBox,'the notify switch is offered');
notifyBox.fire('change');
assert.equal(posts.length,1,'one switch change sends one message');
assert.equal(posts[0].action,'setting');
assert(!document.getElementById('addr'),'no screen offers a field that would change the feed');
const failedConnection=Object.assign({},state([]).connection,{serverOk:false,serverNote:'Address refused'});
render(state([row()],{settingsNote:'Could not save that change. Your previous settings are kept.',connection:failedConnection}));
assert.match(document.querySelector('.scrim.s .sheet').textContent,/Could not save that change/);
assert.match(document.querySelector('.scrim.s .sheet').textContent,/Address refused/,'a refused connection check is shown beside Check now');

// One source, one line, one button: the address is a fact behind Advanced, never a picker or a
// field. No screen names the service behind the feed.
const mirror='https://theng12.github.io/kh-releases/release.json';
const sheetNow=()=>document.querySelector('.scrim.s .sheet').textContent;
run('settingsOpen=false;closeLayers()');
render(state([row()],{connection:Object.assign({},state([]).connection,{destination:mirror,defaultFeed:mirror,studio:false})}));
run('settingsOpen=true;drawSettings()');
assert.match(sheetNow(),/Updates come from this Mac’s signed feed\./,'one line says where updates come from');
assert(document.querySelectorAll('.scrim.s button').some(b=>b.textContent=='Check now'),'one button checks it');
assert(!document.querySelector('.scrim.s details'),'with the saved feed in use there is nothing behind Advanced');
assert.doesNotMatch(sheetNow(),/Where updates come from/,'there is no source picker left in Settings');
assert(!document.getElementById('addr'),'the address is never a field to retype');
assert.doesNotMatch(sheetNow(),/GitHub/,'no screen names the service behind the feed');
assert.doesNotMatch(sheetNow(),/pairing code|fleet|Leave this/,'and no Studio wording reaches a plain Mac');

// A saved address that is not the signed feed is disclosed behind Advanced, for a Studio Mac.
const studioConn=Object.assign({},state([]).connection,{defaultFeed:mirror,canLeave:true});
run('settingsOpen=false;closeLayers()');
render(state([row()],{connection:studioConn}));
run('settingsOpen=true;drawSettings()');
const adv=document.querySelector('.scrim.s details');
assert(adv&&adv.querySelector('summary').textContent=='Advanced','a saved non-default address sits behind Advanced');
assert.match(adv.textContent,/http:\/\/100\.64\.0\.7:8790\/release\.json/,'Advanced shows the address in use');
assert(adv.textContent.includes('reports its apps and versions'),'and says plainly what the Studio is told');
posts.length=0;
const back=document.querySelectorAll('.scrim.s details button').find(b=>b.textContent=='Use the saved feed instead');
assert(back,'the way back to the saved feed is offered while a Studio address is saved');
back.fire('click');
assert.equal(posts[0].action,'changeServer');
assert.equal(posts[0].value,mirror,'it posts the saved feed as the new address');

// Leaving a Studio: offered only to a Mac enrolled to one, confirmed in the page, gone afterwards.
run('settingsOpen=false;closeLayers()');
render(state([row()],{connection:Object.assign({},studioConn,{canLeave:false})}));
run('settingsOpen=true;drawSettings()');
assert(!document.querySelectorAll('.scrim.s button').some(b=>b.textContent=='Leave this Studio'),
       'a Mac that has joined no Studio is never offered Leave');
run('settingsOpen=false;closeLayers()');
render(state([row()],{connection:studioConn}));
run('settingsOpen=true;drawSettings()');
posts.length=0;
document.querySelectorAll('.scrim.s details button').find(b=>b.textContent=='Leave this Studio').fire('click');
assert.equal(posts.length,0,'the button asks first, in the page, before anything is sent');
const leaveDialog=[...document.querySelectorAll('[role=dialog]')].find(d=>/Leave this Studio\?/.test(d.textContent));
assert(leaveDialog&&/keeps every app and every model/.test(leaveDialog.textContent)&&/saved feed instead/.test(leaveDialog.textContent),
       'the confirmation names what this Mac keeps and where it goes next');
confirmAction('Leave this Studio');
assert.equal(posts[0].action,'leaveFleet','confirming posts the one leave action');
run('settingsOpen=false;closeLayers()');
render(state([row()],{connection:Object.assign({},studioConn,{destination:mirror,canLeave:false})}));
run('settingsOpen=true;drawSettings()');
assert(!document.querySelector('.scrim.s details'),'after leaving, the Studio controls are gone with the address');

// Joining stays possible for a Mac that is meant for a Studio: the same address and code fields,
// inside Advanced, and only for a Mac that has not joined one yet.
const upd=()=>row({id:'updater',name:'Studio Launcher KH',status:'Up to date',automatic:true,installed:'0.1.76',available:null,managed:true,helper:true});
const sheetText=()=>document.querySelector('.scrim.s .sheet').textContent;
run('settingsOpen=false;closeLayers();joinAddr=null;joinCode=null');
render(state([upd()],{connection:Object.assign({},studioConn,{canLeave:false})}));
run('settingsOpen=true;drawSettings()');
assert(document.getElementById('pubaddr')&&document.getElementById('pubcode'),'a Studio Mac that has not joined one is offered its address and code');
posts.length=0;
document.getElementById('pubaddr').value='http://studio.tail1234.ts.net:8790/release.json';
document.getElementById('pubcode').value='123-456';
document.querySelectorAll('.scrim.s details button').find(b=>b.textContent=='Join').fire('click');
assert.equal(posts[0].action,'joinFleet');
assert.match(posts[0].value,/studio\.tail1234\.ts\.net/);
assert.equal(posts[0].code,'123-456');

// A single-Mac install — the walk's Macs, set up from the public feed — never sees a Studio, the
// fleet, a publisher or a pairing code. This is acceptance 3, asserted rather than described.
run('settingsOpen=false;closeLayers()');
render(state([upd()],{connection:Object.assign({},state([]).connection,{destination:mirror,defaultFeed:mirror,publicFeed:true,canLeave:false,studio:false})}));
run('settingsOpen=true;drawSettings()');
assert.match(sheetText(),/Updates come from this Mac’s signed feed\./,'a single-Mac install says where its updates come from');
for (const word of ['Update Studio','fleet','Fleet','GitHub','pairing code','Join','leave this','Advanced']) {
  assert(!sheetText().includes(word),'a single-Mac screen never shows "'+word+'"');
}
assert(!document.getElementById('pubaddr')&&!document.getElementById('pubcode'),'and offers no join fields');
const selfBox=document.querySelectorAll('.scrim.s input[type=checkbox]').find(i=>i.parentNode&&/updates itself automatically/.test(i.parentNode.textContent));
assert(selfBox&&!selfBox.disabled,'the self-update switch stays visible and usable on a single-Mac screen');
posts.length=0;selfBox.fire('change');
assert.equal(posts[0].key,'updaterAutomatic','changing it is this Mac’s own setting');
// And the footer carries no Fleet button at all: the fleet is a Studio function.
run('settingsOpen=false;closeLayers()');
assert(!document.getElementById('fleet'),'no Fleet button sits in the everyday footer');

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
// The Updates screen is one line and one button; the long privacy paragraphs are gone, and the
// Log section still says what it is. Reading it sends nothing.
run('detail=null;settingsOpen=true;closeLayers();drawSettings()');
posts.length=0;
render(state([row()],{stateDir:'/Users/test/Library/KHUpdater',replyLimitBytes:8388608}));
const said=document.querySelector('.scrim.s .sheet').textContent;
assert.match(said,/Updates come from (this Mac|the Studio)’s signed feed\./,'the source is one line');
assert.doesNotMatch(said,/is told this Mac’s name|refused rather than buffered|no separate storage budget/,'the three long privacy paragraphs are gone');
assert.match(said,/What the helper did on this Mac/,'the Log section still says what the log is');
assert.equal(posts.length,0,'reading Settings sends nothing and starts nothing');
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
// R15 the one Automatic switch on this Mac's own screen (owner, 2026-11-24): visible, on for a
// fresh Mac, adjustable, and honest when updates are checked by hand instead.
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers()');
render(state([row({ status: 'Up to date' })]));
const autoPill=document.getElementById('auto');
assert(autoPill&&!autoPill.hidden,'R15 the automatic switch is on the everyday screen');
assert.equal(autoPill.getAttribute('aria-pressed'),'true','R15 a fresh Mac shows it on');
assert.match(autoPill.textContent,/Automatic updates on/,'R15 and says so in words');
posts.length=0;autoPill.fire('click');
assert.deepEqual(posts.map(p=>p.action),['setting'],'R15 turning it off writes exactly one setting');
assert.equal(posts[0].key,'autoInstall');assert.equal(posts[0].value,false);
render(state([row({ status: 'Up to date' })],{settings:Object.assign({},state([]).settings,{autoInstall:false})}));
assert.equal(document.getElementById('auto').getAttribute('aria-pressed'),'false','R15 a stored off shows off');
assert.match(document.getElementById('auto').textContent,/Automatic updates off/);
posts.length=0;document.getElementById('auto').fire('click');
assert.equal(posts[0].value,true,'R15 pressing it again turns it back on');
render(state([row({ status: 'Up to date' })],{settings:Object.assign({},state([]).settings,{checkManually:true})}));
assert.equal(document.getElementById('auto').disabled,true,'R15 manual checking disables the switch rather than lying');
assert.equal(document.getElementById('auto').getAttribute('aria-pressed'),'false','R15 and shows it as off');
render(state([]));
assert.equal(document.getElementById('auto').hidden,true,'R15 with no apps there is nothing to switch');
// R11 an empty app list says which publisher could not be reached, instead of "Checking…" forever.
render(state([], { error: 'The request timed out.' }));
assert.match(document.querySelector('.empty').textContent, /could not be reached: The request timed out\./, 'R11 an empty list names the failure');
assert.match(document.querySelector('.empty').textContent, /100\.64\.0\.7/, 'R11 and the address it tried');
render(state([]));
assert.match(document.querySelector('.empty').textContent, /^Checking…$/, 'R11 a first load still says Checking…');
// R12 the appearance segment offers exactly System, Light and Dark — no Default.
assert(!script.includes("'default','Default'"), 'R12 the appearance segment no longer offers Default');
assert.match(script, /\['system','System'\],\['light','Light'\],\['dark','Dark'\]/, 'R12 exactly three appearance choices');
// R16 the tab bar is a row of controls, not a row of words (owner, 2026-11-24): a 6px gap, a 32px
// target, and the selected tab filled with the accent rather than underlined. The layout numbers
// are measured in the shipped window; this pins the rules that produce them.
const tabsBar = (source.match(/\.tabs\{[^}]*\}/) || [''])[0];
assert.match(tabsBar, /gap:6px/, 'R16 tabs are 6px apart');
assert.match(tabsBar, /padding:8px 14px/, 'R16 the bar has its own padding');
const tabRule = (source.match(/\.tabs \[role=tab\]\{[^}]*\}/) || [''])[0];
assert.match(tabRule, /height:32px/, 'R16 each tab is a 32px target');
assert.match(tabRule, /border-radius:6px/, 'R16 and reads as a control');
const tabSelected = (source.match(/\.tabs \[role=tab\]\[aria-selected=true\]\{[^}]*\}/) || [''])[0];
assert.match(tabSelected, /background:var\(--accent\)/, 'R16 the selected tab is filled with the accent');
assert.match(tabSelected, /color:var\(--accent-ink\)/, 'R16 with the ink the primary button uses');
assert.doesNotMatch(tabSelected, /border-bottom/, 'R16 the fill is the cue, so the underline is gone');
assert.doesNotMatch(tabRule, /:hover[^}]*accent/, 'R16 and accent never appears on hover');
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
// Failed rows below the ceiling count toward Update all and show their real failure reason;
// Needs attention (terminal after ceiling) stops offering Update all or primary Update, while
// More keeps Copy error report.
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers()');
render(state([
  row({ id: 'a1', name: 'App One', status: 'Update available', installed: '1.0', available: '2.0' }),
  row({ id: 'a2', name: 'App Two', status: 'Failed', installed: '1.0', available: '2.0', reason: 'App Two did not answer its update hold in time' }),
  row({ id: 'a3', name: 'App Three', status: 'Needs attention', installed: '1.0', available: '2.0', reason: 'App Three failed: HTTP 404 from download mirror' }),
], { connection: { destination: 'http://100.64.0.7:8790/release.json', machine: 'mac-id-1', displayName: 'Edit Suite 1103', checking: false, studio: true, defaultFeed: 'https://theng12.github.io/kh-releases/release.json' } }));
assert.equal(document.getElementById('all').textContent, 'Update all (2)', 'Update all counts Failed rows below ceiling, not Needs attention');
assert.equal(document.getElementById('mac').textContent, 'Apps for Edit Suite 1103', 'header names This Mac from displayName');
const holdTimeoutPlain = run('plain("demo did not answer its update hold within 35 s (it was asked to settle for 20 s); nothing was changed.")');
assert.match(holdTimeoutPlain, /update hold/, 'hold timeout is not hidden as a download failure');
assert.doesNotMatch(holdTimeoutPlain, /download didn’t finish/, 'hold timeout keeps its real reason');
const mirror404Plain = run('plain("download mirror returned HTTP 404")');
assert.match(mirror404Plain, /HTTP 404/, 'a download HTTP failure is not overwritten by a generic download-did-not-finish message');
const terminalCard = document.querySelectorAll('.card').find(c => c.textContent.includes('App Three'));
assert.match(terminalCard.textContent, /Needs attention/, 'terminal card shows Needs attention');
assert(![...terminalCard.querySelectorAll('button')].some(b => b.textContent === 'Update'), 'terminal card offers no primary Update button');
terminalCard.querySelector('button[title="More"]').fire('click');
assert.match(document.querySelector('.menu').textContent, /Copy error report/, 'terminal card keeps Copy error report in More');
document.querySelectorAll('.menu').forEach(x => x.remove());
run('settingsOpen=true;drawSettings()');
assert.match(document.querySelector('.scrim.s .sheet').textContent, /Edit Suite 1103 \(mac-id-1\)/, 'Settings This Mac shows displayName alongside machine id');
run('settingsOpen=false;closeLayers()');

// The fleet lives in the Studio section of Settings — a Studio function, not an everyday button.
// One click asks the helper to open it; the page itself reaches no network.
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers()');
render(state([row({ status: 'Up to date', installed: '0.1.53', available: '0.1.53' })], { version: '0.1.53', connection: Object.assign({}, state([]).connection, { defaultFeed: 'https://theng12.github.io/kh-releases/release.json' }) }));
assert(!document.getElementById('fleet'), 'no Fleet button sits in the everyday footer');
assert(!markup.includes('id=fleet'), 'and the markup carries none to show by accident');
run('settingsOpen=true;drawSettings()');
posts.length = 0;
const fleetButton = document.querySelectorAll('.scrim.s button').find(b => b.textContent == 'Open the fleet…');
assert(fleetButton, 'the Studio section offers the fleet');
fleetButton.fire('click');
assert.equal(posts.length, 1, 'one click sends exactly one message');
assert.equal(posts[0].action, 'fleet', 'it asks the helper to open the publisher page');
run('settingsOpen=false;closeLayers()');
render(state([row()], { connection: Object.assign({}, state([]).connection, { studio: false }) }));
run('settingsOpen=true;drawSettings()');
assert(!document.querySelectorAll('.scrim.s button').some(b => b.textContent == 'Open the fleet…'),
       'a single-Mac screen has no fleet entry at all');
run('settingsOpen=false;closeLayers()');

// F1–F6, 0.1.68: the list's own columns, one quiet notice per version, adoption offers, and the
// grid — remembered per Mac, the same facts as a row, and usable from the keyboard alone.
run('settingsOpen=false;detail=null;whatsNewOpen=false;selected.clear();closeLayers();view="list";viewFromMac=true');
render(state([
  row({ id: 'a1', name: 'App One', status: 'Update available', installed: '1.0', available: '2.0', released: '2026-11-18T00:00:00Z' }),
  row({ id: 'a2', name: 'App Two', status: 'Not installed', managed: true, installed: null, available: '2.0' }),
]));
const heads = [...document.querySelectorAll('thead th')].map(n => n.textContent);
assert.deepEqual(heads.slice(0, 5), ['App', 'Installed', 'Latest', 'Released', 'State'],
  'F1 the list names installed, latest, released and state columns, not a merged status');
const cells = [...document.querySelectorAll('tbody tr')].map(r => [...r.children].map(c => c.textContent));
assert.equal(cells[0][1], '1.0', 'F1 the installed column is the installed version');
assert.equal(cells[0][2], '2.0', 'F1 the latest column is the offered version');
assert.match(cells[0][3], /2026/, 'F1 the released column is the release date');
assert.match(cells[0][4], /Update available/, 'F1 the state column keeps the one state');
assert.equal(cells[1][1], 'Not installed', 'F1 "not installed" is a state in its own column, never blank');

// F2 one quiet notice per app and version; dismissing it records that version and posts it.
run('settingsOpen=false;detail=null;whatsNewOpen=false;closeLayers();view="grid"');
render(state([row({ id: 'a1', name: 'App One', status: 'Update available' })],
  { notices: [{ id: 'a1', name: 'App One', version: '2.0' }] }));
const notice = document.querySelector('.notice');
assert(notice, 'F2 a ready update gets one quiet notice');
assert.equal(document.querySelectorAll('.notice').length, 1, 'F2 exactly one, never a count or a badge');
assert.match(notice.textContent, /App One 2\.0 is ready/, 'F2 the notice names the app and version');
posts.length = 0;
notice.querySelectorAll('button').find(b => b.textContent === 'Dismiss').fire('click');
assert.equal(posts[0].action, 'dismissNotice', 'F2 Dismiss records the notice');
assert.equal(posts[0].app, 'a1', 'F2 …for this app');
assert.equal(posts[0].version, '2.0', 'F2 …at this version, so it never returns for it');
posts.length = 0;
notice.querySelectorAll('button').find(b => b.textContent === 'Update').fire('click');
confirmAction('Update');
assert.equal(posts[0].action, 'update', 'F2 the notice offers the same update, after the page asks');
assert.equal(posts[0].app, 'a1', 'F2 …for the app it names');
render(state([row({ id: 'a1', name: 'App One', status: 'Update available' })], { notices: [] }));
assert.equal(document.querySelector('.notice'), null, 'F2 no notices in the state, none on the page');

// F5 a hand-installed copy is offered once: managing records it where it is, declining remembers.
render(state([row({ id: 'a1', name: 'App One', status: 'Up to date' })],
  { adoptions: [{ id: 'a1', bundleID: 'com.kh.appone', version: '1.0', name: 'App One', path: '/Applications/App One.app' }] }));
const adopt = document.querySelector('.adopt');
assert(adopt && /Installed by hand/.test(adopt.textContent), 'F5 a hand-installed copy is shown as such');
assert.match(adopt.textContent, /\/Applications\/App One\.app/, 'F5 the copy\'s own location is named before anything changes');
assert.match(adopt.textContent, /nothing is moved, renamed or reinstalled over it/, 'F5 it says what managing does not do');
posts.length = 0;
adopt.querySelectorAll('button').find(b => b.textContent === 'Manage it').fire('click');
assert.equal(posts[0].action, 'adopt', 'F5 Manage it adopts that app id');
assert.equal(posts[0].app, 'a1', 'F5 …at its own path');
posts.length = 0;
adopt.querySelectorAll('button').find(b => b.textContent === 'Not now').fire('click');
assert.equal(posts[0].action, 'declineAdoption', 'F5 Not now is remembered as a decline');
assert.equal(posts[0].app, 'a1', 'F5 …for that app');
render(state([row({ id: 'a1', name: 'App One', status: 'Up to date' })], { adoptions: [] }));
assert.equal(document.querySelector('.adopt'), null, 'F5 a declined or managed app is not offered again');

// F6 the grid is the default, the choice is this Mac's, and the keyboard alone can act on it.
run('settingsOpen=false;detail=null;whatsNewOpen=false;selected.clear();closeLayers();view="grid";viewFromMac=false');
render(state([row({ id: 'a1', name: 'App One', status: 'Update available', installed: '1.0', available: '2.0', released: '2026-11-18T00:00:00Z' })],
  { settings: { checkManually: false, autoInstall: true, notify: false, appearance: 'system', menuBarWhenClosed: true, retireHelpers: false, helperCleanupAvailable: true, helperHealthySeconds: 600, viewMode: 'grid' } }));
assert(document.querySelector('.card'), 'F6 a fresh install opens as a grid');
assert.match(document.querySelector('.card').textContent, /2\.0/, 'F6 a card carries the latest version');
assert.match(document.querySelector('.card').textContent, /Update available/, 'F6 …and the same state a row shows');
assert.equal(document.querySelectorAll('.card .btn.main').length, 1, 'F6 a card carries exactly one action');
posts.length = 0;
run('view="list"');document.getElementById('vgrid').fire('click');
assert.equal(posts[0].action, 'setting', 'F6 choosing the grid is saved');
assert.equal(posts[0].key, 'viewMode', 'F6 …as this Mac\'s own view setting');
assert.equal(posts[0].value, 'grid', 'F6 …with the grid value');
posts.length = 0;
document.getElementById('vlist').fire('click');
assert.equal(posts[0].value, 'list', 'F6 …and choosing the list is saved the same way');
// The helper's saved value wins on the next launch, whichever the local storage says.
run('view="list";viewFromMac=false');
render(state([row({ id: 'a1', name: 'App One', status: 'Up to date' })],
  { settings: { checkManually: false, autoInstall: true, notify: false, appearance: 'system', menuBarWhenClosed: true, retireHelpers: false, helperCleanupAvailable: true, helperHealthySeconds: 600, viewMode: 'grid' } }));
assert(document.querySelector('.card'), 'F6 the grid saved on this Mac is what opens next launch');
// Arrows move between cards, Enter opens the one that has focus, Cmd+A picks them all.
run('view="grid";selected.clear()');
render(state([
  row({ id: 'a1', name: 'App One', status: 'Update available', available: '2.0' }),
  row({ id: 'a2', name: 'App Two', status: 'Update available', available: '2.0' }),
]));
const cards = document.querySelectorAll('.card');
const press = (node, key) => node.fire('keydown', { key, preventDefault() {}, stopPropagation() {} });
press(cards[0], 'ArrowRight');
assert.equal(document.activeElement, cards[1], 'F6 the right arrow moves focus to the next card');
press(cards[1], 'ArrowLeft');
assert.equal(document.activeElement, cards[0], 'F6 the left arrow moves back');
press(cards[0], 'ArrowDown');
assert.equal(document.activeElement, cards[1], 'F6 the down arrow moves too');
const key = ev => (document.handlers.keydown || []).forEach(fn => fn(Object.assign(
  { target: document.body, currentTarget: document.body, preventDefault() {}, stopPropagation() {} }, ev)));
key({ key: 'a', metaKey: true });
assert.equal(run('selected.size'), 2, 'F6 Cmd+A picks every card that has an action');
assert(document.querySelectorAll('.card.selected').length === 2, 'F6 …and the cards show they are picked');
posts.length = 0;
key({ key: 'Enter' });
confirmAction('Update');
assert.equal(posts[0].action, 'updateAll', 'F6 Enter on the selection asks once, then updates all of it');
key({ key: 'Escape' });
assert.equal(run('selected.size'), 0, 'F6 Escape clears the selection');
// R18 coverage counts the verified feed, not the rows visible through a filter.
const now = new Date().toISOString();
const gitHubSource = 'GitHub (theng12.github.io)', studioSource = 'the studio server at studio.example.test:8790';
const appRows = [
  row({id:'hub', name:'A Hub', type:'media'}),
  row({id:'new-app', name:'B New App', type:'future', unrecognised:true}),
  row({id:'launcher', name:'C Launcher', type:'system'}),
  row({id:'story', name:'D Story', type:'media'}),
  row({id:'wire', name:'E Wire'}),
  row({id:'printer', name:'F Printer', type:'utility'}),
  row({id:'library', name:'G Library', type:'entertainment'}),
  row({id:'business', name:'H Business', type:'business'}),
];
const appTypes=['business','entertainment','media','system','utility'];
render(state(appRows, {appTypes,feedPublishedAt:'2026-11-21T14:21:00Z',feedCount:11,checkedFeedSource:gitHubSource,
  missingFromFeed:['File Studio KH','Storage Studio KH']}));
assert.match(document.getElementById('main').textContent, /This feed carries 11 apps, last updated [^·]+ · Not on it: File Studio KH, Storage Studio KH/);
render(state(appRows, {feedPublishedAt:null,feedCount:null,missingFromFeed:['File Studio KH']}));
assert.doesNotMatch(document.getElementById('main').textContent,/Not on it:/,'no missing-app verdict without a verified feed');
// R19 the check names what it checks in plain words: the saved feed, never a service or a host.
render(state(appRows,{lastRun:now,lastDriveScan:now,serverKnown:true,sources:['One','Two','Three'],
  configuredFeedSource:studioSource,checkedFeedSource:gitHubSource}));
const checkButton=document.getElementById('check');
assert.match(markup, /<header[\s\S]*?id=vlist[\s\S]*?id=check[\s\S]*?<\/header>/);
assert.equal(checkButton.getAttribute('title'),'Check the saved feed and 3 installer drives');
assert.equal(checkButton.getAttribute('aria-label'),checkButton.getAttribute('title'));
assert.match(document.getElementById('checked').textContent,/^Checked the saved feed just now · Scanned 3 installer drives/);
assert.doesNotMatch(document.getElementById('checked').textContent,/GitHub|studio server/i,'no screen names the service behind the feed');
render(state(appRows,{lastRun:now,lastDriveScan:now,serverKnown:true,sources:['One'],
  configuredFeedSource:gitHubSource,checkedFeedSource:studioSource}));
assert.equal(checkButton.getAttribute('title'),'Check the saved feed and 1 installer drive');
assert.match(document.getElementById('checked').textContent,/^Checked the saved feed just now · Scanned 1 installer drive/);
posts.length=0;
checkButton.fire('click');
assert.deepEqual(posts.map(post=>post.action),['check']);
// R20 the native sort control reorders by type without inventing labels or losing selected IDs.
run("view='grid';sort='name';selected=new Set(['story'])");
render();
assert.deepEqual(Array.from(run('visible()[0]').map(a=>a.id)),['hub','new-app','launcher','story','wire','printer','library','business']);
const sortControl=document.getElementById('sort');
sortControl.focus();
sortControl.value='type';sortControl.onchange({target:sortControl});
assert.deepEqual(Array.from(run('visible()[0]').map(a=>a.id)),['business','library','hub','story','launcher','printer','new-app','wire']);
assert.equal(document.activeElement,sortControl);
assert.match(document.querySelector('.card.selected').textContent,/D Story/);
assert.match(document.getElementById('main').textContent,/B New AppUnlabelled · Unrecognised/);
assert.match(document.getElementById('main').textContent,/E WireUnlabelled/, 'a familiar app ID does not imply a type');
run("view='list';render()");
assert.match(document.getElementById('main').textContent,/A HubMedia/);
assert.match(document.querySelector('tr[aria-selected=true]').textContent,/D StoryMedia/);
assert.match(document.getElementById('main').textContent,/C LauncherSystem/);
const relabelled=appRows.map(a=>a.id==='story'?{...a,type:'entertainment'}:a);
render(state(relabelled));
assert.match(document.querySelector('tr[aria-selected=true]').textContent,/D StoryEntertainment/,'publisher can relabel without a new UI build');

// R21 the eight sections across the top: All, the five app labels, then Plugin and Extension,
// which are not apps. The owner asked for this row in place of the old bottom disclosure.
const tabButtons = () => document.querySelectorAll('#tabs [role=tab]');
run("tab='all';render()");
assert.deepEqual(tabButtons().map(t=>t.textContent),['All','Business','Media','Utilities','Entertainment','System','Plugin','Extension']);
assert.equal(tabButtons().find(t=>t.getAttribute('aria-selected')==='true').textContent,'All');
assert.doesNotMatch(markup,/Extensions and plugins<\/summary>/,'the bottom disclosure is gone');
// A row with no label is neither lost nor guessed into a category: it keeps its own named group.
assert.match(document.getElementById('main').textContent,/No category yet · 2/);
run("tab='media';render()");
assert.match(document.getElementById('main').textContent,/A Hub/);
assert.doesNotMatch(document.getElementById('main').textContent,/C Launcher/,'a category tab shows that label only');
assert.doesNotMatch(document.getElementById('main').textContent,/D Story/,'Story was relabelled entertainment above');
run("tab='entertainment';render()");
assert.match(document.getElementById('main').textContent,/D Story/);
assert.equal(document.getElementById('tabNote').hidden,false);
assert.match(document.getElementById('tabNote').textContent,/2 apps have no category on the feed yet; they are under All\./);
run("tab='utility';render()");
assert.match(document.getElementById('main').textContent,/F Printer/,'the feed calls it utility; the tab says Utilities');
assert.doesNotMatch(document.getElementById('main').textContent,/No category yet/,'the unlabelled group belongs to All');
assert.doesNotMatch(document.getElementById('main').textContent,/A Hub/);
run("tab='business';render()");
assert.match(document.getElementById('main').textContent,/H Business/);
// An empty category says so, and says where the unlabelled apps are, instead of a blank panel.
render(state(appRows.filter(a=>a.id!=='business'),{appTypes,feedCount:10}));
run("tab='business';render()");
assert.match(document.getElementById('main').textContent,/No Business apps on this feed yet\. 2 apps have no category yet; they are under All\./);
render(state(appRows,{appTypes,feedCount:11}));
// R22 a row that exists because the app is installed on this Mac is not a feed row: it keeps its
// own heading and the version read from its bundle, and is never "No category yet" — that sentence
// is for a feed row whose author forgot a label (owner, 2026-11-24).
const adoptedRows=appRows.concat([row({id:'hub-apps',name:'I Hub',type:null,managed:true,installed:'0.6.39',
  available:null,status:'Not in the feed',adopted:true,open:true})]);
run("tab='all';view='grid'");
render(state(adoptedRows,{appTypes,feedCount:11}));
const main22=document.getElementById('main').textContent;
assert.match(main22,/Installed on this Mac · 1/,'R22 an adopted app has its own heading');
assert.match(main22,/I Hub/);
assert.match(main22,/0\.6\.39/,'R22 the version read from the bundle is shown');
assert.doesNotMatch(main22,/I HubUnlabelled/,'R22 an adopted app is not labelled Unlabelled');
assert.match(main22,/No category yet · 2/,'R22 only feed rows without a label are counted');
run("tab='media';render()");
assert.doesNotMatch(document.getElementById('main').textContent,/Installed on this Mac/,'R22 no feed category to sit under, and none invented');
// R23 the mixed case: an app the feed carries sits under Installed with its update, and an app the
// feed genuinely lacks sits under its own heading on the same screen. Hub is on the feed since
// 2026-11-24, so the adoption case is carried by an app the feed does not list.
run("tab='all'");
render(state([
  row({id:'hub',name:'A Hub',type:'media',installed:'0.6.255',available:'0.6.258',status:'Update available'}),
  row({id:'capture',name:'B Capture',type:null,managed:true,installed:'0.4.1',available:'0.4.1',
      status:'Not in the feed',adopted:true,open:true}),
],{appTypes,feedCount:1}));
const mixed=document.getElementById('main').textContent;
assert.match(mixed,/Installed · 1/,'R23 the feed\'s app is Installed');
assert.match(mixed,/Installed on this Mac · 1/,'R23 and the app the feed lacks has its own heading');
assert.match(mixed,/A Hub.*0\.6\.255 → 0\.6\.258/,'R23 the feed app shows its update');
assert.doesNotMatch(mixed,/No category yet/,'R23 and neither is "No category yet"');
assert.doesNotMatch(mixed,/B CaptureUnlabelled/,'R23 the adopted app is never labelled Unlabelled');
run("tab='all'");
render(state(adoptedRows.map(a=>a.id=='hub-apps'?{...a,adopted:false}:a),{appTypes,feedCount:11}));
assert.match(document.getElementById('main').textContent,/No category yet · 3/,'R22 the same row without the flag reads as the feed row it claims to be');
render(state(appRows,{appTypes,feedCount:11}));
// The controls that only shape an app list are not offered on the two non-app tabs.
run("tab='plugin';render()");
assert.equal(document.getElementById('sort').hidden,true);
assert.equal(document.getElementById('q').hidden,true);
run("tab='all';render()");
assert.equal(document.getElementById('sort').hidden,false);
// Opening a non-app tab asks once, on demand, and never polls; only verified rows get a download.
posts.length=0;
tabButtons().find(t=>t.textContent==='Plugin').fire('click');
assert.deepEqual(posts.map(post=>post.action),['checkExtensions']);
run("tab='plugin';render()");
assert.equal(posts.length,1,'rendering the open tab again asks nothing');
render(state(appRows,{extensions:{status:'loading'}}));
assert.match(document.getElementById('main').textContent,/Checking for published extensions/);
assert.equal(document.querySelectorAll('#main button').length,0);
render(state(appRows,{extensions:{status:'unpublished'}}));
assert.match(document.getElementById('main').textContent,/Extensions and plugins are not published yet; nothing to download/);
assert(!document.querySelectorAll('#main button').some(b=>b.textContent==='Download'));
render(state(appRows,{extensions:{status:'failed'}}));
assert.match(document.getElementById('main').textContent,/Could not check/);
const extRows=['Video generator','Image generator','Audio generator'].map((name,i)=>({
  id:'test-extension-'+i,name,version:'10.20.'+i,summary:'Make '+name.split(' ')[0].toLowerCase()+' in Chrome.',
  kind:'extension',download:true}));
// A plugin is the other kind, listed only until it has a published download.
extRows.push({id:'efficient-orchestration',name:'Efficient Orchestration',version:'0.3.204',
  summary:'Coordinates work across Studio apps.',kind:'plugin',download:false});
render(state(appRows,{extensions:{status:'available',entries:extRows}}));
const extPanel = document.getElementById('extPanel');
assert.equal(extPanel.querySelectorAll('.extRow').length,1,'the Plugin tab lists the plugin entry only');
assert.match(extPanel.textContent,/EEfficient Orchestration · 0\.3\.204Coordinates work across Studio apps\.ScreenshotNo public download yet/);
assert.equal(extPanel.querySelectorAll('button').length,0,'a plugin without a download offers no dead button');
run("tab='extension';render()");
assert.equal(document.getElementById('extPanel').querySelectorAll('.extRow').length,3,'the Extension tab lists the extension entries only');
assert.match(document.getElementById('extPanel').textContent,/Video generator · 10\.20\.0Make video in Chrome/);
assert.equal(document.querySelectorAll('#extPanel button').length,3);
assert.doesNotMatch(document.getElementById('main').textContent,/Efficient Orchestration/,'a plugin is not drawn as an app or an extension');
assert.equal(document.querySelectorAll('#main .card').length,0,'extensions and plugins never become app cards');
posts.length=0;
document.querySelectorAll('#extPanel button')[1].fire('click');
assert.equal(posts.length,1);
assert.equal(posts[0].action,'downloadExtension');
assert.equal(posts[0].app,'test-extension-1');
assert.equal(posts[0].url,undefined,'browser opening uses only the verified native catalog');
// The page's own policy must let a picture from the two hosts the catalogue may name reach the
// tile, and nothing else: measured in a real browser on 2026-11-24, `img-src data:` alone meant
// every tile kept its placeholder and said the picture could not be loaded.
assert(source.includes("img-src data: https://github.com https://raw.githubusercontent.com;"),'EXT0 the policy admits the catalogue\'s two picture hosts');
const pictureHosts=(source.match(/img-src[^;]*/)||[''])[0].split(/\s+/).filter(x=>x.startsWith('https:'));
assert.deepEqual(pictureHosts,['https://github.com','https://raw.githubusercontent.com'],'EXT0 and no other host');
// A published picture is drawn on the tile; a row without one keeps the placeholder; and nothing
// waits for a picture — all three tiles are in the page before a single image arrives.
const pictured=extRows.map((x,i)=>({...x,
  icon:'https://raw.githubusercontent.com/theng12/kh-extensions/main/'+x.id+'/icon.png',
  screenshot:'https://github.com/theng12/kh-extensions/releases/download/'+x.id+'/shot.png'}));
run("tab='extension';render()");
render(state(appRows,{extensions:{status:'available',entries:pictured}}));
const tiles=document.getElementById('extPanel').querySelectorAll('.extRow');
assert.equal(tiles.length,3,'EXT1 all three tiles are drawn at once, before any picture arrives');
const icon=tiles[0].querySelector('.extIcon img'), shot=tiles[0].querySelector('.extShot img');
assert(icon&&shot,'EXT1 each tile carries an icon and a screenshot node');
assert.equal(icon.getAttribute('data-src'),'https://raw.githubusercontent.com/theng12/kh-extensions/main/test-extension-0/icon.png');
assert.equal(shot.getAttribute('data-src'),'https://github.com/theng12/kh-extensions/releases/download/test-extension-0/shot.png');
assert(icon.hidden===true&&shot.hidden===true,'EXT1 the placeholder shows until a picture has really arrived');
icon.naturalWidth=512;icon.naturalHeight=512;icon.onload();
assert.equal(icon.hidden,false,'EXT2 a loaded icon replaces the placeholder');
shot.naturalWidth=1024;shot.naturalHeight=640;shot.onload();
assert.equal(shot.hidden,false,'EXT2 a loaded screenshot replaces the placeholder');
icon.naturalWidth=3000;icon.naturalHeight=900;
tiles[1].querySelector('.extIcon img').naturalWidth=3000;
tiles[1].querySelector('.extIcon img').naturalHeight=900;
tiles[1].querySelector('.extIcon img').onload();
assert(!tiles[1].querySelector('.extIcon img'),'EXT3 an oversized picture is dropped');
assert.match(tiles[1].querySelector('.extIcon').textContent,/I/,'EXT3 the placeholder stays');
assert.match(tiles[1].querySelector('.extNote').textContent,/3000×900, over the 2048-pixel limit/, 'EXT3 and the page says why, in its own words');
render(state(appRows,{extensions:{status:'available',entries:extRows}}));
const bare=document.getElementById('extPanel').querySelectorAll('.extRow');
assert(!bare[0].querySelector('.extIcon img')&&!bare[0].querySelector('.extShot img'),'EXT4 a row without pictures has no image to break');
assert.match(bare[0].querySelector('.extIcon').textContent,/V/,'EXT4 it keeps the placeholder, the app\'s own initial');
assert.equal(bare[0].querySelector('.extNote').textContent,'','EXT4 and invents no complaint');
// The tab row is keyboard-navigable: Right/Left move and activate, Home and End jump.
run("tab='all';render()");
const allTab=document.getElementById('tab-all');allTab.focus();
allTab.fire('keydown',{key:'ArrowRight'});
assert.equal(document.querySelectorAll('#tabs [aria-selected=true]')[0].textContent,'Business');
document.getElementById('tab-business').fire('keydown',{key:'End'});
assert.equal(document.querySelectorAll('#tabs [aria-selected=true]')[0].textContent,'Extension');
document.getElementById('tab-extension').fire('keydown',{key:'ArrowRight'});
assert.equal(document.querySelectorAll('#tabs [aria-selected=true]')[0].textContent,'All','Right from the last tab wraps to All');
run("tab='all';render()");

// F1 the Show filter: this Mac's apps, the feed's apps it does not have, or everything — with an
// adopted app (installed here, never on the feed) counted as installed, because it is.
const show = label => document.querySelectorAll('#instseg button').find(b => b.textContent == label);
const names = () => document.querySelectorAll('.card .name').map(n => n.textContent);
const three = state([
  row({ id: 'story', name: 'Story KH', type: 'business', installed: '1.0.0', available: '1.1.0' }),
  row({ id: 'hub', name: 'Hub KH', type: 'utility', installed: null, available: '0.6.260' }),
  row({ id: 'mine', name: 'Mine KH', installed: '2.0.0', available: null, managed: false, adopted: true }),
]);
const groupHeads = () => document.querySelectorAll('#main h2').map(h => h.textContent);
run("tab='all';inst='all';render()"); render(three);
assert.deepEqual(groupHeads(), ['Installed · 1', 'Installed on this Mac · 1', 'Not installed · 1'],
  'F1 All still groups the three kinds apart');
assert.deepEqual(names().slice().sort(), ['Hub KH', 'Mine KH', 'Story KH'], 'F1 …and shows every one of them');
show('Installed').fire('click');
assert.deepEqual(names().slice().sort(), ['Mine KH', 'Story KH'],
  'F1 Installed keeps what this Mac has, including an adopted app the feed never carried');
assert.deepEqual(groupHeads(), ['Installed · 1', 'Installed on this Mac · 1'], 'F1 …and drops the group it emptied');
assert.equal(document.querySelector('#instseg button[data-inst=installed]').getAttribute('aria-pressed'), 'true',
  'F1 the chosen filter is the one marked selected');
show('Not installed').fire('click');
assert.deepEqual(names(), ['Hub KH'], 'F1 Not installed shows only what this Mac lacks');
assert.equal(document.querySelectorAll('#main h2').length, 1, 'F1 one group, not three headings around one list');
render(state([row({ id: 'story', installed: '1.0.0', available: '1.1.0' })]));
assert.match(document.querySelector('.empty').textContent, /already installed here\. Choose Installed to see them\./,
  'F1 an empty filter says what it hid and how to see it, rather than a blank panel');
show('Installed').fire('click');
render(state([row({ id: 'hub', installed: null, available: '0.6.260' })]));
assert.match(document.querySelector('.empty').textContent, /Nothing from this feed is installed on this Mac yet\./,
  'F1 the other empty side says its own sentence');
show('All').fire('click');
// F2 it is an app-list control, so the two non-app tabs do not offer it.
run("tab='extension';render()");
assert.equal(document.getElementById('instseg').hidden, true, 'F2 the filter is not offered where it would do nothing');
run("tab='all';render()");

console.log('PASS: Launcher rendering, list columns, update notice, adoption offers, grid and keyboard, source choices and refusal reasons, offline state, delta/fallback bytes, editing focus, Story/Hub routes, Automatic origin, data-flow limits, save feedback, the page’s own What’s New pop-up, the footer group, the fleet control, the click’s immediate feedback, the empty list’s reason, the feed’s missing apps, the Installed / Not installed / All filter and the Scan drives control');
