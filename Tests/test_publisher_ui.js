// Exercise the actual embedded copy handler, including clicks before its restore timer fires.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sourcePath = process.argv[2] || path.join(__dirname, '../Sources/KHUpdaterCore/Server.swift');
const source = fs.readFileSync(sourcePath, 'utf8');
const start = source.indexOf("document.querySelectorAll('button[data-copy]')");
const end = source.indexOf("document.getElementById('refresh').addEventListener", start);
assert(start >= 0 && end > start, 'copy handler must be found');
const handler = source.slice(start, end);
const fleetSource = fs.readFileSync(path.join(__dirname, '../Sources/KHUpdaterCore/PublisherFleet.swift'), 'utf8');
for (const rect of fleetSource.matchAll(/<rect[^>]+>/g)) {
  const rx = rect[0].match(/rx=(?:'([^']*)'|"([^"]*)"|([^\s>]+))/);
  if (rx) assert(Number.isFinite(Number(rx[1] ?? rx[2] ?? rx[3])), 'SVG rect corner radius must parse as a numeric HTML attribute');
}

// The Launcher's embedded page must recognize vendor rows and never hide a reason it has.
const launcherSource = fs.readFileSync(path.join(__dirname, '../Sources/khu/LauncherPage.swift'), 'utf8');
assert(launcherSource.includes("a.source=='Official vendor'"), 'launcher copy must recognize official vendor rows');
assert(!launcherSource.includes("a.status=='Failed'&&a.reason?el"), 'launcher must show the reason for every status that carries one');
assert(launcherSource.includes("a.setup?'The verified official installer is waiting in its setup folder.'"), 'setup-folder copy must depend on a real setup folder');

async function check(label, clipboardWorks, modal) {
  const timers = [], copied = [], pageStatus = {textContent: ''}, modalStatus = {textContent: ''};
  const button = {textContent: label, getAttribute: () => 'fixture-value',
    addEventListener: (_, callback) => {button.click = callback;}, focus() {}};
  const document = {
    querySelectorAll: () => [button], querySelector: () => modal ? modalStatus : null,
    getElementById: () => pageStatus,
    createElement: () => ({value: '', select() {}, remove() {}}),
    body: {appendChild() {}}, execCommand: () => false,
  };
  const navigator = {clipboard: {writeText(value) {
    copied.push(value);
    return clipboardWorks ? Promise.resolve() : Promise.reject(new Error('denied'));
  }}};
  vm.runInNewContext(handler, {document, navigator, setTimeout: fn => timers.push(fn)});
  const status = modal ? modalStatus : pageStatus;
  button.click();
  await Promise.resolve(); await Promise.resolve();
  if (clipboardWorks) {
    assert.equal(button.textContent, 'Copied');
    button.click();
    await Promise.resolve(); await Promise.resolve();
    timers.forEach(fn => fn());
    assert.equal(button.textContent, label, 'double-click must restore the original action label');
    assert.equal(status.textContent, label + ' copied.');
    assert.deepEqual(copied, ['fixture-value', 'fixture-value']);
  } else {
    assert.equal(button.textContent, label);
    assert.match(status.textContent, /Copy was unavailable/);
    assert.equal(timers.length, 0, 'a refused clipboard must never claim success');
  }
  if (modal) assert.equal(pageStatus.textContent, '', 'modal feedback must be inside the active dialog');
}
(async () => {
  await check('Copy code', true, false);
  await check('Copy address', true, false);
  await check('Copy error report', true, true);
  await check('Copy code', false, false);
  console.log('PUBLISHER-UI: repeated copy, modal feedback and clipboard refusal passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
