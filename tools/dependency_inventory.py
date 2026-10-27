"""Inventory pinned Dart packages and licence text hashes without local paths.

Run after flutter pub get. This records evidence, not legal compatibility advice.
Native libraries require the separate Android inventory and source manifest.
"""
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urljoin, urlparse

ROOT = Path(__file__).resolve().parents[1]


def classify(text):
    if 'Mozilla Public License Version 2.0' in text:
        return 'MPL-2.0'
    if 'GNU LESSER GENERAL PUBLIC LICENSE' in text:
        return 'LGPL (review version and exceptions)'
    if 'GNU GENERAL PUBLIC LICENSE' in text:
        return 'GPL (review version and exceptions)'
    if 'Apache License' in text and 'Version 2.0' in text:
        return 'Apache-2.0'
    if 'Permission is hereby granted, free of charge' in text:
        return 'MIT'
    if 'Redistribution and use in source and binary forms' in text:
        return 'BSD (see full text)'
    return 'Manual review required'


def main():
    config_file = ROOT / '.dart_tool/package_config.json'
    config = json.loads(config_file.read_text())
    graph = json.loads((ROOT / '.dart_tool/package_graph.json').read_text())
    packages = {p['name']: p for p in graph['packages']}
    root_names = set(graph['roots'])
    runtime = set()

    def visit(name):
        if name in runtime:
            return
        runtime.add(name)
        for dependency in packages.get(name, {}).get('dependencies', []):
            visit(dependency)

    for name in root_names:
        visit(name)
    lock = (ROOT / 'pubspec.lock').read_text()
    locked = {m[1]: m[2] for m in re.finditer(
        r'^  (\w+):\n(.*?)(?=^  \w+:|^sdks:|\Z)', lock, re.M | re.S)}
    rows = []
    for package in sorted(config['packages'], key=lambda p: p['name']):
        name = package['name']
        if name in root_names:
            continue
        directory = Path(unquote(urlparse(urljoin(config_file.as_uri(), package['rootUri'])).path))
        licenses = sorted({*directory.glob('LICENSE*'), *directory.glob('COPYING*')})
        origin = 'package'
        if not licenses and name.startswith('flutter'):
            licenses = [directory.parents[1] / 'LICENSE']
            origin = 'Flutter SDK'
        contents = [p.read_bytes() for p in licenses if p.is_file()]
        block = locked.get(name, '')
        sha = re.search(r'sha256: "?([a-f0-9]{64})', block)
        hosted = 'source: hosted' in block
        version = packages.get(name, {}).get('version', 'sdk')
        rows.append({
            'name': name, 'version': version,
            'scope': 'runtime dependency closure' if name in runtime else 'development',
            'source': (f'https://pub.dev/api/archives/{name}-{version}.tar.gz' if hosted else
                       'third_party/video_player_android' if name == 'video_player_android' else
                       'Flutter SDK; see native-sources.json for pinned revision'),
            'archiveSha256': sha[1] if sha else None,
            'licenceOrigin': origin,
            'licenceFiles': [{'file': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                             for p in licenses if p.is_file()],
            'licencePattern': classify(b'\n'.join(contents).decode(errors='replace')) if contents else 'Missing licence',
        })
    output = ROOT / 'docs/dependencies/dart-packages.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({'schema': 1, 'packages': rows}, indent=2) + '\n')
    missing = [r['name'] for r in rows if not r['licenceFiles']]
    print(f'Inventoried {len(rows)} Dart packages; {len(missing)} missing licence files.')
    if missing:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
