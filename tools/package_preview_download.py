"""Package a signed APK for the private preview site's browser downloader.

Usage: python3 tools/package_preview_download.py APK_PATH --output-dir DIRECTORY
Parts stay below static hosting asset limits. Their hashes are checked before
saving the original, byte-identical APK. Never copy signing files to the site.
"""
import hashlib
import io
import json
import argparse
import zipfile
from audit_apk import inspect_apk_stream
from audit_repository import private_values
from local_config import local_setting
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('apk', type=Path)
parser.add_argument('--output-dir', type=Path)
args = parser.parse_args()
output = args.output_dir or local_setting(repo, 'PREVIEW_DOWNLOAD_DIR')
if not output:
    parser.error('Set --output-dir or PREVIEW_DOWNLOAD_DIR in .env.')
root = Path(output).expanduser().resolve()
if root == repo or repo in root.parents:
    parser.error('Choose an output directory outside the source checkout.')
apk = args.apk
try:
    data = apk.read_bytes()
    audit = inspect_apk_stream(io.BytesIO(data), private_values(repo))
except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
    parser.error('Cannot inspect this APK. Check the input file before packaging.')
if audit['findings']:
    parser.error('APK audit failed. Run tools/audit_apk.py and resolve its findings before packaging.')
digest = hashlib.sha256(data).hexdigest()
version_line = next(line for line in (repo / 'pubspec.yaml').read_text().splitlines()
                    if line.startswith('version:'))
version, build_number = version_line.split(':', 1)[1].strip().split('+')
build = root / digest[:16]
build.mkdir(parents=True, exist_ok=True)
parts = []
for index, start in enumerate(range(0, len(data), 8 * 1024 * 1024)):
    chunk = data[start:start + 8 * 1024 * 1024]
    path = build / f'part-{index:03}.bin'
    path.write_bytes(chunk)
    parts.append({'url': f'./{build.name}/{path.name}', 'size': len(chunk),
                  'sha256': hashlib.sha256(chunk).hexdigest()})
manifest = {'version': version, 'build': int(build_number),
            'filename': f'iptv-app-{version}.apk',
            'minAndroid': '7.0', 'size': len(data), 'sha256': digest, 'parts': parts}
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({k: v for k, v in manifest.items() if k != 'parts'}))
