from pathlib import Path
import shutil
import subprocess
import unittest


class PairFormTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node is required to execute the bundled form')
    def test_form_modes_and_encrypted_transfer(self):
        subprocess.run(
            ['node', str(Path(__file__).with_name('pair_form_test.js'))],
            check=True, timeout=20,
        )
