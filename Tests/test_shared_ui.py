#!/usr/bin/env python3
"""Exercise generated release data from an isolated checkout, without shared-folder access."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('generate_ui', ROOT / 'packaging/generate-ui.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class SharedUITests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='khu-shared-ui-'))
        shutil.copytree(ROOT / 'packaging/shared-ui', self.root / 'packaging/shared-ui')
        for name in ('CHANGELOG.md', 'CHANGELOG-launcher.md'):
            (self.root / name).write_text('## 1.2.3 — 2026-11-09\n- Says "Ready" in Khmer: រួចរាល់\n')

    def tearDown(self):
        trash = Path(tempfile.gettempdir()) / '_trash'
        trash.mkdir(exist_ok=True)
        self.root.rename(trash / (self.root.name + '-' + uuid.uuid4().hex))

    def test_changed_shared_inputs_reach_both_embedded_consumers(self):
        path = self.root / 'packaging/shared-ui/design-tokens.json'
        tokens = json.loads(path.read_text())
        tokens['type']['body']['size'] = 19
        path.write_text(json.dumps(tokens))
        generator.generate(self.root)
        expected = [{'version': '1.2.3', 'date': '2026-11-09', 'items': ['Says "Ready" in Khmer: រួចរាល់']}]
        for name in ('whats-new.json', 'whats-new-launcher.json'):
            self.assertEqual(json.loads((self.root / 'build' / name).read_text()), expected)
        swift = (self.root / 'build/Changelog.swift').read_text()
        self.assertIn('--kh-type-body:19px;', swift)
        self.assertIn('public static let textJSON', swift)
        self.assertIn('public static let launcherJSON', swift)
        self.assertIn('រួចរាល់', swift)

    def test_launcher_choices_save_and_storage_refusal_stays_usable(self):
        page = (ROOT / 'Sources/khu/LauncherPage.swift').read_text()
        store = 'const store=' + page.split('const store=', 1)[1].split(';\n', 1)[0] + ';'
        script = "const assert=require('node:assert/strict'); const values=new Map(); let refused=false; const localStorage={getItem:k=>{if(refused)throw Error('denied');return values.get(k)||null},setItem:(k,v)=>{if(refused)throw Error('denied');values.set(k,v)}};"
        script += store + "store.set('view','list');assert.equal(store.get('view'),'list');refused=true;assert.equal(store.get('view'),null);store.set('view','grid');"
        subprocess.run(['node', '-e', script], check=True, capture_output=True, text=True)

    def test_shared_shortcuts_and_escape_preserve_underlying_layer(self):
        page = (ROOT / 'Sources/khu/LauncherPage.swift').read_text()
        handler = "document.addEventListener('keydown',e=>{" + page.split("document.addEventListener('keydown',e=>{", 1)[1].split('\nsetInterval', 1)[0]
        script = "const assert=require('node:assert/strict');let keydown,detail={id:'app'},settingsOpen=true,whatsNewOpen=false,closed=0,removed=0,drawn=0,focused=0;const document={addEventListener:(k,f)=>keydown=f,querySelector:()=>null,querySelectorAll:()=>[{remove:()=>removed++}]};const closeLayers=()=>closed++,drawSettings=()=>drawn++,$=()=>({focus:()=>focused++});"
        script += handler + "keydown({key:'Escape'});assert.equal(settingsOpen,false);assert.equal(detail.id,'app');assert.equal(closed,0);assert.equal(removed,1);keydown({key:',',metaKey:true,preventDefault(){}});assert.equal(settingsOpen,true);assert.equal(drawn,1);keydown({key:'k',metaKey:true,preventDefault(){}});assert.equal(focused,1);whatsNewOpen=true;keydown({key:'Escape'});assert.equal(whatsNewOpen,false);assert.equal(settingsOpen,true);"
        subprocess.run(['node', '-e', script], check=True, capture_output=True, text=True)
        server = (ROOT / 'Sources/KHUpdaterCore/Server.swift').read_text()
        body = server.split("document.addEventListener('keydown',function(e){", 1)[1].split("}});", 1)[0]
        script = "const assert=require('node:assert/strict');let focused=0;const location={hash:''},show=()=>{},document={getElementById:()=>({focus:()=>focused++})};const keydown=function(e){" + body + "}};keydown({key:',',metaKey:true,preventDefault(){}});assert.equal(location.hash,'settings');keydown({key:'k',metaKey:true,preventDefault(){}});assert.equal(location.hash,'macs');assert.equal(focused,1);"
        subprocess.run(['node', '-e', script], check=True, capture_output=True, text=True)

    def test_every_page_fetch_keeps_the_app_version_query(self):
        server = (ROOT / 'Sources/KHUpdaterCore/Server.swift').read_text()
        fetches = [line for line in server.splitlines() if 'fetch(location.pathname' in line]
        self.assertTrue(fetches)
        for line in fetches:
            self.assertIn('fetch(location.pathname+location.search', line)

    def test_source_interpolation_delimiter_is_refused(self):
        (self.root / 'CHANGELOG.md').write_text('## 1.2.3 — 2026-11-09\n- \\#(unexpectedCode())\n')
        with self.assertRaisesRegex(ValueError, 'raw-literal delimiter'):
            generator.generate(self.root)
        self.assertFalse((self.root / 'build/Changelog.swift').exists())


if __name__ == '__main__':
    unittest.main()
