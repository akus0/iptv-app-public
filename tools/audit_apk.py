"""Report Flutter APK size and redacted privacy findings without extracting files.

This complements source review, APK signing verification and device testing.
It does not prove that arbitrary binary/encoded content contains no private data.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import zipfile

from audit_repository import FORBIDDEN_NAMES, FORBIDDEN_SUFFIXES, private_values, scan_text

MAX_ENTRY_BYTES = 128 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024


def inspect_apk(path, values=()):
    with Path(path).open('rb') as source:
        return inspect_apk_stream(source, values)


def inspect_apk_stream(source, values=()):
    """Inspect a seekable stream; packagers can pass the exact bytes they publish."""
    source.seek(0, 2)
    apk_size = source.tell()
    source.seek(0)
    groups = defaultdict(int)
    libraries = defaultdict(set)
    findings, entries = [], []
    with zipfile.ZipFile(source) as archive:
        infos = archive.infolist()
        names = {info.filename for info in infos}
        if not {'AndroidManifest.xml', 'classes.dex'} <= names:
            raise ValueError('Missing Android manifest or application bytecode.')
        if len(names) != len(infos):
            raise ValueError('Duplicate APK entries require review.')
        if (sum(info.file_size for info in infos) > MAX_TOTAL_BYTES or
                any(info.file_size > MAX_ENTRY_BYTES for info in infos)):
            raise ValueError('APK exceeds inspection size limits.')
        for info in infos:
            name = info.filename
            name_issues = scan_text(name.encode(), values)
            label = '[redacted entry]' if name_issues else name
            findings.extend({'entry': label, 'rule': rule, 'line': 0}
                            for rule, _ in name_issues)
            parts = Path(name).parts
            leaf = Path(name).name
            if name.startswith('/') or '..' in parts:
                findings.append({'entry': label, 'rule': 'unsafe-entry-path', 'line': 0})
            if (leaf in FORBIDDEN_NAMES or Path(name).suffix.lower() in FORBIDDEN_SUFFIXES
                    or leaf.startswith('.env.') or leaf.endswith('.symbols')):
                findings.append({'entry': label, 'rule': 'private-or-generated-file', 'line': 0})
            # Read one bounded entry at a time, including native code. Never
            # write archive paths or binary contents into the working checkout.
            data = archive.read(info)
            findings.extend({'entry': label, 'rule': rule, 'line': line}
                            for rule, line in scan_text(data, values))
            if len(parts) == 3 and parts[0] == 'lib' and leaf.endswith('.so'):
                libraries[parts[1]].add(leaf)
                group = 'Native libraries'
            elif name.startswith('assets/flutter_assets/'):
                group = 'Flutter assets'
            elif name.endswith('.dex'):
                group = 'Java/Kotlin bytecode'
            else:
                group = 'Android resources and metadata'
            groups[group] += info.compress_size
            entries.append({'entry': label, 'packed_bytes': info.compress_size,
                            'unpacked_bytes': info.file_size})
        complete, incomplete = [], []
        for abi, libs in sorted(libraries.items()):
            if {'libapp.so', 'libflutter.so'} <= libs:
                complete.append(abi)
            else:
                incomplete.append(abi)
                label = '[redacted ABI]' if scan_text(abi.encode(), values) else abi
                findings.append({'entry': f'lib/{label}/', 'rule': 'incomplete-flutter-runtime', 'line': 0})
        if not complete:
            findings.append({'entry': 'lib/', 'rule': 'missing-flutter-runtime', 'line': 0})
    return {
        'apk_bytes': apk_size,
        'entry_count': len(entries),
        'packed_groups': dict(groups),
        'complete_abis': [a if not scan_text(a.encode(), values) else '[redacted ABI]' for a in complete],
        'incomplete_abis': [a if not scan_text(a.encode(), values) else '[redacted ABI]' for a in incomplete],
        'largest_entries': sorted(entries, key=lambda e: e['packed_bytes'], reverse=True)[:15],
        'findings': findings,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--json', action='store_true', help='Redacted structured report')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        result = inspect_apk(args.apk, private_values(root))
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
        parser.error('Cannot inspect APK. Check that it is readable, valid and within the size limits.')
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"APK: {result['apk_bytes'] / 1048576:.2f} MiB; {result['entry_count']} entries.")
        for group, size in result['packed_groups'].items():
            print(f'{group}: {size / 1048576:.2f} MiB')
        print('Complete runtimes: ' + ', '.join(result['complete_abis']))
        print(f"{len(result['findings'])} finding(s) requiring review.")
        for item in result['findings'][:50]:
            print(f"{item['entry']}:{item['line']} [{item['rule']}]")
    return 1 if result['findings'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
