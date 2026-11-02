from pathlib import Path
import sys
import subprocess
import json
import hashlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_apk import inspect_apk


class ApkAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.apk = Path(self.temp.name) / 'fixture.apk'

    def create(self, entries=None):
        contents = {'AndroidManifest.xml': b'manifest', 'classes.dex': b'bytecode',
                    'lib/arm64-v8a/libflutter.so': b'engine',
                    'lib/arm64-v8a/libapp.so': b'application'}
        contents.update(entries or {})
        with zipfile.ZipFile(self.apk, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, data in contents.items():
                archive.writestr(name, data)

    def test_size_breakdown_and_complete_runtime(self):
        self.create({'assets/flutter_assets/example.txt': b'asset'})
        result = inspect_apk(self.apk)
        self.assertEqual(result['apk_bytes'], self.apk.stat().st_size)
        self.assertEqual(result['entry_count'], 5)
        self.assertEqual(result['complete_abis'], ['arm64-v8a'])
        self.assertFalse(result['findings'])
        with zipfile.ZipFile(self.apk) as archive:
            self.assertEqual(sum(result['packed_groups'].values()),
                             sum(i.compress_size for i in archive.infolist()))

    def test_private_values_are_checked_inside_decompressed_native_code(self):
        value = 'private-fixture-' + 'account-value'
        self.create({'lib/arm64-v8a/libapp.so': b'\x7fELF\0' + value.encode()})
        result = inspect_apk(self.apk, (value,))
        self.assertIn('local-configuration-value', {f['rule'] for f in result['findings']})
        self.assertNotIn(value, repr(result))

    def test_missing_runtime_in_an_advertised_abi_is_reported(self):
        self.create({'lib/x86_64/libdecoder.so': b'decoder'})
        result = inspect_apk(self.apk)
        self.assertEqual(result['incomplete_abis'], ['x86_64'])
        self.assertIn('incomplete-flutter-runtime', {f['rule'] for f in result['findings']})

    def test_private_entry_names_are_redacted_in_every_report_section(self):
        address = '.'.join(('192', '168', '42', '18'))
        self.create({f'assets/{address}.txt': b'data'})
        result = inspect_apk(self.apk)
        self.assertTrue(result['findings'])
        self.assertNotIn(address, repr(result))

    def test_local_configuration_and_symbols_are_not_release_assets(self):
        self.create({'assets/.env': b'anything', 'assets/app.android-arm64.symbols': b'debug info'})
        result = inspect_apk(self.apk)
        self.assertEqual(sum(f['rule'] == 'private-or-generated-file' for f in result['findings']), 2)

    def test_archive_paths_are_never_extracted(self):
        self.create({'../escaped.txt': b'payload'})
        self.assertIn('unsafe-entry-path', {f['rule'] for f in inspect_apk(self.apk)['findings']})
        self.assertFalse((self.apk.parent.parent / 'escaped.txt').exists())

    def test_non_apk_and_oversized_entries_fail_before_reading(self):
        with zipfile.ZipFile(self.apk, 'w') as archive:
            archive.writestr('ordinary.txt', 'not an APK')
        with self.assertRaises(ValueError):
            inspect_apk(self.apk)
        self.create()
        with patch('audit_apk.MAX_ENTRY_BYTES', 2):
            with self.assertRaises(ValueError):
                inspect_apk(self.apk)

    def package(self):
        script = Path(__file__).resolve().parents[1] / 'package_preview_download.py'
        output = self.apk.parent / 'download'
        result = subprocess.run([sys.executable, str(script), str(self.apk), '--output-dir', str(output)],
                                capture_output=True, text=True)
        return result, output

    def test_packager_checks_privacy_before_creating_download_parts(self):
        address = '.'.join(('192', '168', '42', '18'))
        self.create({'assets/local.txt': address.encode()})
        result, output = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APK audit failed', result.stderr)
        self.assertNotIn(address, result.stderr)
        self.assertFalse(output.exists())

    def test_packager_retains_exact_audited_bytes(self):
        self.create()
        original = self.apk.read_bytes()
        result, output = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((output / 'manifest.json').read_text())
        rebuilt = b''.join((output / part['url']).read_bytes() for part in manifest['parts'])
        self.assertEqual(rebuilt, original)
        self.assertEqual(manifest['sha256'], hashlib.sha256(original).hexdigest())


if __name__ == '__main__':
    unittest.main()
