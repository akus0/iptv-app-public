import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_repository import read_source_entry, scan_worktree, source_files
from export_source import export_source


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        base = Path(self.directory.name)
        self.root = base / 'checkout'
        self.root.mkdir()
        self.target = base / 'snapshot'
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'safe.txt').write_text('reviewed source\n')

    def assert_no_partial_export(self):
        self.assertFalse(self.target.exists())
        self.assertFalse(list(self.target.parent.glob('.source-export-*')))

    def test_snapshot_excludes_history_ignored_config_and_deleted_files(self):
        (self.root / '.gitignore').write_text('.env\n')
        (self.root / '.env').write_text('VALUE=synthetic-private-configuration\n')
        (self.root / 'gone.txt').write_text('removed')
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        (self.root / 'gone.txt').unlink()
        script = self.root / 'run.sh'
        script.write_text('#!/bin/sh\nexit 0\n')
        script.chmod(0o755)
        # Untracked source belongs in the snapshot too.
        self.assertEqual(export_source(self.root, self.target), 3)
        self.assertEqual({p.name for p in self.target.iterdir()}, {'.gitignore', 'safe.txt', 'run.sh'})
        self.assertEqual((self.target / 'safe.txt').read_bytes(), (self.root / 'safe.txt').read_bytes())
        self.assertTrue(os.access(self.target / 'run.sh', os.X_OK))

    def test_tracked_file_later_ignored_requires_review(self):
        note = self.root / 'local-notes.txt'
        note.write_text('local development notes')
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        (self.root / '.gitignore').write_text('local-notes.txt\n')
        result = scan_worktree(self.root)
        self.assertIn('tracked-ignored-file', {f['rule'] for f in result['findings']})
        with self.assertRaises(ValueError):
            export_source(self.root, self.target)
        self.assert_no_partial_export()

    def test_ignore_rules_changing_mid_export_abort_the_snapshot(self):
        (self.root / '.gitignore').write_text('')
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        def read_then_ignore(root, name, values):
            result = read_source_entry(root, name, values)
            if name == 'safe.txt':
                (root / '.gitignore').write_text('safe.txt\n')
            return result
        with patch('export_source.read_source_entry', side_effect=read_then_ignore):
            with self.assertRaisesRegex(ValueError, 'Ignore rules changed'):
                export_source(self.root, self.target)
        self.assert_no_partial_export()

    def test_exports_audited_bytes_even_if_original_changes_after_read(self):
        def read_then_change(root, name, values):
            result = read_source_entry(root, name, values)
            (root / name).write_text('.'.join(('192', '168', '42', '18')))
            return result
        with patch('export_source.read_source_entry', side_effect=read_then_change):
            export_source(self.root, self.target)
        self.assertEqual((self.target / 'safe.txt').read_text(), 'reviewed source\n')

    def test_changes_before_read_are_audited_and_fail_without_partial_output(self):
        def change_then_read(root, name, values):
            (root / name).write_text('.'.join(('192', '168', '42', '18')))
            return read_source_entry(root, name, values)
        with patch('export_source.read_source_entry', side_effect=change_then_read):
            with self.assertRaisesRegex(ValueError, 'audit failed'):
                export_source(self.root, self.target)
        self.assert_no_partial_export()

    def test_new_file_during_export_aborts_the_snapshot(self):
        def add_then_read(root, name, values):
            (root / 'new.txt').write_text('new source')
            return read_source_entry(root, name, values)
        with patch('export_source.read_source_entry', side_effect=add_then_read):
            with self.assertRaisesRegex(ValueError, 'file list changed'):
                export_source(self.root, self.target)
        self.assert_no_partial_export()

    def test_write_failure_leaves_no_partial_snapshot(self):
        with patch.object(Path, 'write_bytes', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                export_source(self.root, self.target)
        self.assert_no_partial_export()

    def test_existing_or_in_checkout_destination_is_not_touched(self):
        for target in (self.root, self.root / 'snapshot', self.root / 'safe.txt'):
            with self.assertRaises(ValueError):
                export_source(self.root, target)
        self.target.mkdir()
        (self.target / 'keep').write_text('existing')
        with self.assertRaises(ValueError):
            export_source(self.root, self.target)
        self.assertEqual((self.target / 'keep').read_text(), 'existing')

    def test_source_symlink_is_not_followed_after_file_listing(self):
        original = source_files(self.root)
        outside = self.target.parent / 'outside.txt'
        outside.write_text('private')
        (self.root / 'safe.txt').unlink()
        (self.root / 'safe.txt').symlink_to(outside)
        with patch('export_source.source_files', return_value=original):
            with self.assertRaises(ValueError):
                export_source(self.root, self.target)
        self.assert_no_partial_export()

    def test_archive_requires_review_even_with_unrecognised_extension(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('private.txt', 'not plain text in source')
        (self.root / 'backup.data').write_bytes(data.getvalue())
        self.assertIn('archive-content-review', {f['rule'] for f in scan_worktree(self.root)['findings']})
        with self.assertRaises(ValueError):
            export_source(self.root, self.target)
        self.assert_no_partial_export()

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'requires POSIX special files')
    def test_special_files_are_rejected_without_blocking(self):
        os.mkfifo(self.root / 'pipe')
        data, _, findings = read_source_entry(self.root, 'pipe')
        self.assertIsNone(data)
        self.assertEqual(findings[0]['rule'], 'source-special-file-review')

    def test_nested_git_repository_needs_review_instead_of_silent_omission(self):
        nested = self.root / 'nested'
        subprocess.run(['git', 'init', '-q', str(nested)], check=True)
        findings = scan_worktree(self.root)['findings']
        self.assertTrue(findings)
        with self.assertRaises(ValueError):
            export_source(self.root, self.target)
        self.assert_no_partial_export()

    def test_snapshot_does_not_copy_extended_attributes(self):
        mac_xattr = sys.platform == 'darwin' and shutil.which('xattr')
        if not hasattr(os, 'setxattr') and not mac_xattr:
            self.skipTest('extended attributes unavailable')
        source = self.root / 'safe.txt'
        name = 'com.apple.metadata:source-audit-test' if sys.platform == 'darwin' else 'user.source-audit-test'
        try:
            if mac_xattr:
                subprocess.run([mac_xattr, '-w', name, 'local provenance', str(source)], check=True, capture_output=True)
            else:
                os.setxattr(source, name, b'local provenance')
        except (OSError, subprocess.CalledProcessError):
            self.skipTest('filesystem does not support test extended attribute')
        export_source(self.root, self.target)
        attributes = (subprocess.check_output([mac_xattr, str(self.target / 'safe.txt')]).decode().splitlines()
                      if mac_xattr else os.listxattr(self.target / 'safe.txt'))
        self.assertNotIn(name, attributes)

    def test_private_filenames_are_rejected_without_echoing_the_value(self):
        address = '.'.join(('192', '168', '42', '18'))
        (self.root / f'capture-{address}.txt').write_text('ordinary text')
        result = scan_worktree(self.root)
        self.assertTrue(result['findings'])
        self.assertNotIn(address, repr(result))
        with self.assertRaises(ValueError):
            export_source(self.root, self.target)
        self.assert_no_partial_export()

    def test_destination_created_mid_export_is_preserved(self):
        def create_target_then_read(root, name, values):
            self.target.mkdir()
            (self.target / 'keep.txt').write_text('existing output')
            return read_source_entry(root, name, values)
        with patch('export_source.read_source_entry', side_effect=create_target_then_read):
            with self.assertRaisesRegex(ValueError, 'Destination appeared'):
                export_source(self.root, self.target)
        self.assertEqual((self.target / 'keep.txt').read_text(), 'existing output')
        self.assertFalse(list(self.target.parent.glob('.source-export-*')))


if __name__ == '__main__':
    unittest.main()
