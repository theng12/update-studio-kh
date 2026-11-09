#!/usr/bin/env python3
"""Compile the versioned KH shared UI release inputs into the helper."""
import datetime
import json
from pathlib import Path
import runpy


def generate(root):
    shared = root / 'packaging/shared-ui'
    parse = runpy.run_path(str(shared / 'whats-new.py'))['parse']
    tokens = json.loads((shared / 'design-tokens.json').read_text())
    out = root / 'build'
    out.mkdir(exist_ok=True)
    values = {'buildDate': datetime.date.today().isoformat()}
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
    # A raw literal preserves JSON escapes; reject its delimiters rather than emitting Swift code.
    for value in values.values():
        if '"""#' in value or '\\#(' in value:
            raise ValueError('Shared UI input contains a Swift raw-literal delimiter')
    swift = 'public enum Changelog {\n' + ''.join(
        f'    public static let {name} = #"""\n{value}\n"""#\n' for name, value in values.items()) + '}\n'
    (out / 'Changelog.swift').write_text(swift)


if __name__ == '__main__':
    generate(Path(__file__).resolve().parent.parent)
