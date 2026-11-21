#!/usr/bin/env python3
"""Compile the versioned KH shared UI release inputs into the helper."""
import datetime
import json
from pathlib import Path
import runpy

# The What's New dialog, one source for the publisher page and the Update Studio KH window's own
# pages. It uses the page's colour variables (--panel, --line, --text, --sub, --ok, --ok-bg).
WHATS_NEW_CSS = (
    '#whats-new{width:min(760px,calc(100vw - 32px));max-height:min(820px,calc(100dvh - 40px));overflow:auto}'
    '#whats-new .body{padding:20px 28px 28px}'
    '#whats-new .newshead{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px;margin:0}'
    '#whats-new .newshead strong{font-size:22px}'
    '#whats-new .when{color:var(--sub);font-weight:400;font-size:13px}'
    '#whats-new .newssum{margin:6px 0 18px;color:var(--sub);font-size:15px}'
    '#whats-new .rel{border-top:1px solid var(--line);padding-top:16px;margin-top:20px}'
    '#whats-new .rel h3{margin:0 0 10px;font-size:16px;display:flex;gap:10px;align-items:baseline}'
    '#whats-new .newslist{margin:0;padding-left:20px;line-height:1.55;font-size:15px}'
    '#whats-new .newslist li{margin-bottom:10px}'
    '#whats-new .tag{font-size:12px;padding:2px 8px;border-radius:999px;background:var(--ok-bg);color:var(--ok)}'
)


def generate(root):
    shared = root / 'packaging/shared-ui'
    parse = runpy.run_path(str(shared / 'whats-new.py'))['parse']
    tokens = json.loads((shared / 'design-tokens.json').read_text())
    out = root / 'build'
    out.mkdir(exist_ok=True)
    roster = json.loads((root / 'packaging/fleet-roster.json').read_text())
    if not isinstance(roster, dict) or not roster or not all(isinstance(name, str) and name.strip() for name in roster.values()):
        raise ValueError('The fleet roster must map app IDs to nonempty display names')
    values = {'buildDate': datetime.date.today().isoformat(), 'fleetRosterJSON': json.dumps(roster, ensure_ascii=False)}
    for field, filename, output in [('text', 'CHANGELOG.md', 'whats-new.json'),
                                     ('launcher', 'CHANGELOG-launcher.md', 'whats-new-launcher.json')]:
        values[field] = (root / filename).read_text()
        data = json.dumps(parse(values[field]), ensure_ascii=False)
        (out / output).write_text(data + '\n')
        values[field + 'JSON'] = data
    variables = {f'--kh-space-{k}': v for k, v in tokens['space'].items()}
    variables.update({f'--kh-radius-{k}': v for k, v in tokens['radius'].items()})
    variables.update({f'--kh-type-{k}': v['size'] for k, v in tokens['type'].items()})
    css = ':root{' + ''.join(f'{k}:{v}px;' for k, v in variables.items()) + '}'
    css += 'html{font-size:var(--kh-type-body)}button,input,select,.btn{border-radius:var(--kh-radius-control)}'
    css += '.card,.panel,.maclist,.tablewrap,.settingslist,.stats,table{border-radius:var(--kh-radius-card)}'
    css += '.sheet,.newsbody{border-radius:var(--kh-radius-sheet)}'
    css += '.pagehead h2{font-size:var(--kh-type-pageTitle)}h4{font-size:var(--kh-type-section)}'
    css += '.sub,.when,.note{font-size:var(--kh-type-secondary)}'
    css += '.grid,.head{gap:var(--kh-space-m)}.meta,.foot{gap:var(--kh-space-s)}'
    values['layoutCSS'] = css
    values['whatsNewCSS'] = WHATS_NEW_CSS
    (out / 'whats-new-dialog.css').write_text(WHATS_NEW_CSS + '\n')
    # A raw literal preserves JSON escapes; reject its delimiters rather than emitting Swift code.
    for value in values.values():
        if '"""#' in value or '\\#(' in value:
            raise ValueError('Shared UI input contains a Swift raw-literal delimiter')
    swift = 'public enum Changelog {\n' + ''.join(
        f'    public static let {name} = #"""\n{value}\n"""#\n' for name, value in values.items()) + '}\n'
    (out / 'Changelog.swift').write_text(swift)


if __name__ == '__main__':
    generate(Path(__file__).resolve().parent.parent)
