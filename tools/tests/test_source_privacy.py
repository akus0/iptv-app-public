import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_repository import scan_text, scan_worktree, scan_history
from local_config import read_local_config, local_setting


class PrivacyTests(unittest.TestCase):
    def test_debug_symbols_require_review_even_without_private_strings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'release.symbols').write_bytes(b'compiled debug information')
            self.assertTrue(scan_worktree(root)['findings'])

    def test_long_binary_strings_do_not_require_repeated_hostname_backtracking(self):
        self.assertFalse(scan_text(b'x' * 200000))
        host = 'private-fixture' + '.chatgpt.site'
        self.assertIn(('private-hosting-reference', 2), scan_text(('header\n' + host).encode()))

    def test_private_address_and_local_secret_are_redacted(self):
        address = '.'.join(('192', '168', '42', '18'))
        secret = 'local-' + 'test-secret-value'
        findings = scan_text(f'example\n{address}\n{secret}'.encode(), (secret,))
        self.assertIn(('private-network-address', 2), findings)
        self.assertIn(('local-configuration-value', 3), findings)
        self.assertNotIn(secret, repr(findings))
        self.assertNotIn(address, repr(findings))

    def test_synthetic_credential_urls_remain_useful_in_security_tests(self):
        for url in ('https://example.invalid/live/demo/demo/1.ts',
                    'https://demo:demo@example.invalid/live/demo/1.ts',
                    'https://streams.example/get.php?username=demo&password=demo'):
            self.assertFalse(scan_text(url.encode()))
        self.assertTrue(scan_text(('https://unrecognised-host' + '/live/account/credential/1.ts').encode()))

    def test_embedded_url_credentials_are_reported_without_values(self):
        address = 'https://' + 'someone:example-password@service.invalid-host/'
        self.assertTrue(scan_text(address.encode()))
        address = 'https://service.invalid-host/data?' + 'access_token=example-token'
        self.assertTrue(scan_text(address.encode()))
        self.assertFalse(scan_text(b'https://example.invalid/?token=synthetic'))

    def test_non_http_stream_credentials_are_also_scanned(self):
        for scheme in ('rtsp', 'RTSPS', 'rtmp', 'RTMPS'):
            url = scheme + '://' + 'account:secret-value@unrecognised-host/feed'
            findings = scan_text(url.encode())
            self.assertIn(('credential-bearing-url', 1), findings)
            self.assertNotIn('secret-value', repr(findings))
            self.assertFalse(scan_text((scheme + '://demo:demo@example.invalid/feed').encode()))

    def test_binary_boundaries_do_not_join_unrelated_strings_into_urls(self):
        host = b'https://unrecognised-host'
        for boundary in (b'\0', b'\x01', b'\x7f', b'\xff'):
            self.assertFalse(scan_text(host + boundary + b'account:secret@another-host'))
            credential = b'https://' + b'account:secret@unrecognised-host'
            self.assertIn(('credential-bearing-url', 1), scan_text(credential + boundary))
        self.assertIn(('credential-bearing-url', 1),
                      scan_text(('https://' + 'usér:secret@unrecognised-host').encode()))

    def test_dynamic_stream_id_does_not_hide_literal_credentials(self):
        host = 'https://unrecognised-host'
        for tail in ('/live/account/secret-value/$id',
                     '/live/$username/secret-value/${id}',
                     '/data?username=$username&password=secret-value',
                     '/data?%70assword=secret-value',
                     '/data?username=$username&amp;password=secret-value'):
            with self.subTest(tail=tail):
                findings = scan_text((host + tail).encode())
                self.assertIn(('credential-bearing-url', 1), findings)
                self.assertNotIn('secret-value', repr(findings))

    def test_entirely_dynamic_credentials_do_not_require_redaction(self):
        host = 'https://unrecognised-host'
        for tail in ('/live/$username/$password/$id',
                     '/data?username=${username}&password=${password}',
                     '/live/{username}/{password}/1.ts'):
            self.assertFalse(scan_text((host + tail).encode()))

    def test_template_prefix_cannot_hide_a_literal_credential_suffix(self):
        host = 'https://unrecognised-host'
        for tail in ('/live/${account}-literal/${password}/1.ts',
                     '/data?password=${password}-literal'):
            self.assertIn(('credential-bearing-url', 1), scan_text((host + tail).encode()))
        self.assertFalse(scan_text((host + '/live/${profile.username}/${profile.password}/1.ts').encode()))

    def test_short_stream_addresses_are_checked(self):
        host = 'https://unrecognised-host'
        for tail in ('/account/secret-value/123.ts', '/account/secret-value/123.m3u8'):
            self.assertIn(('credential-bearing-url', 1), scan_text((host + tail).encode()))
        self.assertFalse(scan_text((host + '/$username/$password/123.ts').encode()))

    def test_unicode_text_exports_are_scanned(self):
        address = '.'.join(('192', '168', '42', '18'))
        for encoding in ('utf-8', 'utf-16', 'utf-32'):
            with self.subTest(encoding=encoding):
                findings = scan_text(('header\n' + address).encode(encoding))
                self.assertIn(('private-network-address', 2), findings)
                self.assertNotIn(address, repr(findings))

    def test_real_host_cannot_hide_behind_example_userinfo(self):
        for userinfo in ('example.invalid', 'example.invalid:secret-value',
                         'example.com:secret-value', 'localhost:secret-value'):
            url = 'https://' + userinfo + '@unrecognised-host/live/account/secret-value/1.ts'
            self.assertIn(('credential-bearing-url', 1), scan_text(url.encode()))

    def test_public_and_ipv6_address_urls_are_redacted(self):
        public = '.'.join(('8', '8', '8', '8'))
        for address in (public, '[fd42:abcd::1]', '[fe80::1%25eth0]'):
            findings = scan_text(f'http://{address}/guide'.encode())
            self.assertIn(('network-address-url', 1), findings)
            self.assertNotIn(address, repr(findings))

    def test_localhost_and_documentation_address_urls_are_examples(self):
        for address in ('127.0.0.1', '[::1]', '0.0.0.0', '[::]',
                        '192.0.2.10', '198.51.100.2', '203.0.113.5', '[2001:db8::1]'):
            self.assertFalse(scan_text(f'http://{address}/guide'.encode()))

    def test_credential_shaped_examples_and_request_notes_are_flagged(self):
        value = 'ab12' * 3
        for text in ('Password:' + value, value + 'Password:demo', value + 'SmartTV'):
            self.assertIn(('credential-shaped-example', 1), scan_text(text.encode()))
        note = '// requested' + ' directly: personal setup details'
        self.assertIn(('personal-request-narrative', 1), scan_text(note.encode()))
        self.assertFalse(scan_text(b'// Focus is requested by the handler.'))

    def test_symlinked_parent_cannot_export_external_files(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'folder').mkdir()
            (root / 'folder/file.txt').write_text('original')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            (root / 'folder/file.txt').unlink()
            (root / 'folder').rmdir()
            (Path(outside) / 'file.txt').write_text('external data')
            (root / 'folder').symlink_to(outside, target_is_directory=True)
            self.assertTrue(scan_worktree(root)['findings'])

    def test_api_user_routes_are_not_local_home_directories(self):
        self.assertFalse(scan_text(b'/Users/AuthenticateByName /Users/u1/Items'))
        home = '/Users/' + 'developer/private.txt'
        self.assertTrue(scan_text(home.encode()))

    def test_local_config_is_not_evaluated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.env').write_text('VALUE=$(do-not-execute)\nPATH_VALUE=C:\\\\keys\\\\release.jks\n')
            values = read_local_config(root)
            self.assertEqual(values['VALUE'], '$(do-not-execute)')
            self.assertEqual(values['PATH_VALUE'], 'C:\\keys\\release.jks')
            with patch.dict(os.environ, {'VALUE': 'environment'}):
                self.assertEqual(local_setting(root, 'VALUE'), 'environment')

    def test_environment_override_does_not_parse_unused_local_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.env').write_text('not a supported entry\n')
            for value in ('environment', ''):
                with patch.dict(os.environ, {'OVERRIDE_VALUE': value}):
                    self.assertEqual(local_setting(root, 'OVERRIDE_VALUE'), value)
            with patch.dict(os.environ, {}, clear=True):
                with self.assertRaises(ValueError):
                    local_setting(root, 'OVERRIDE_VALUE')

    def test_ignored_env_is_excluded_but_force_tracked_env_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('.env\n')
            (root / '.env').write_text('LOCAL_VALUE=synthetic-local-value\n')
            (root / 'safe.txt').write_text('source\n')
            self.assertFalse(scan_worktree(root)['findings'])
            subprocess.run(['git', '-C', str(root), 'add', '-f', '.env'], check=True)
            self.assertTrue(scan_worktree(root)['findings'])

    def test_history_detects_private_data_removed_from_current_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            note = root / 'note.txt'
            note.write_text('.'.join(('10', '42', '1', '9')))
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Audit Test',
                            '-c', 'user.email=audit@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            note.write_text('sanitised')
            self.assertFalse(scan_worktree(root)['findings'])
            self.assertTrue(scan_history(root)['findings'])

    def test_history_reports_do_not_echo_private_filenames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            address = '.'.join(('10', '42', '1', '9'))
            (root / f'capture-{address}.txt').write_text('safe body')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Audit Test',
                            '-c', 'user.email=audit@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            result = scan_history(root)
            self.assertTrue(result['findings'])
            self.assertNotIn(address, repr(result))

    def test_symlink_to_private_file_cannot_be_exported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'linked-secret').symlink_to('/outside/private')
            # A broken symlink is still a source entry requiring review.
            self.assertTrue(scan_worktree(root)['findings'])


if __name__ == '__main__':
    unittest.main()
