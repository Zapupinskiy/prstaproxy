import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

SCRIPT = Path(__file__).resolve().parents[1] / 'lib' / 'config.py'


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.run_config('init', 'proxy.example.com', 'https', '203.0.113.1')

    def tearDown(self):
        self.temp.cleanup()

    def run_config(self, *args, success=True):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.base), *args],
                                capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result.stdout.strip()

    def test_secret_and_link_survive_mode_change(self):
        link = self.run_config('link')
        secret = parse_qs(urlsplit(link).query)['secret'][0]
        self.assertRegex(secret, r'^dd[0-9a-f]{32}$')
        self.run_config('mode', 'https-lanes')
        self.assertEqual(self.run_config('link'), link)
        self.assertEqual(self.run_config('mode'), 'https-lanes')
        profile = json.loads((self.base / 'config/profiles.json').read_text())['profiles'][0]
        self.assertEqual(profile['backend'], '127.0.0.1:2398')
        self.assertEqual(len((self.base / 'config/token.key').read_bytes()), 32)

    def test_invalid_changes_preserve_configuration(self):
        before = (self.base / 'config/profiles.json').read_bytes()
        self.run_config('mode', 'invalid', success=False)
        self.assertEqual((self.base / 'config/profiles.json').read_bytes(), before)
        before = (self.base / 'config/backend.env').read_bytes()
        self.run_config('sponsor', '$(malicious)', success=False)
        self.assertEqual((self.base / 'config/backend.env').read_bytes(), before)

    def test_custom_and_random_secret_sync_backend(self):
        token = (self.base / 'config/token.key').read_bytes()
        for value in ('AB' * 16, 'dd' + '12' * 16):
            self.run_config('secret', value)
            expected = value.lower()[-32:]
            self.assertEqual(self.run_config('secret'), 'dd' + expected)
            self.assertIn('SECRET=' + expected + '\n', (self.base / 'config/backend.env').read_text())
            self.assertEqual(parse_qs(urlsplit(self.run_config('link')).query)['secret'][0], 'dd' + expected)
        before = self.run_config('secret')
        self.run_config('rotate-secret')
        current = self.run_config('secret')
        self.assertNotEqual(current, before)
        self.assertRegex(current, r'^dd[0-9a-f]{32}$')
        self.assertIn('SECRET=' + current[2:] + '\n', (self.base / 'config/backend.env').read_text())
        self.assertEqual((self.base / 'config/token.key').read_bytes(), token)

    def test_invalid_secret_preserves_both_files(self):
        files = [self.base / 'config/profiles.json', self.base / 'config/backend.env']
        before = [p.read_bytes() for p in files]
        for invalid in ('', 'ab', 'zz' * 16, 'ee' + '12' * 16, '$(command)'):
            self.run_config('secret', invalid, success=False)
            self.assertEqual([p.read_bytes() for p in files], before)

    def test_sponsor_does_not_rotate_secret(self):
        link = self.run_config('link')
        self.run_config('sponsor', 'AB' * 16)
        self.assertEqual(self.run_config('sponsor'), 'ab' * 16)
        self.run_config('sponsor', 'off')
        self.assertEqual(self.run_config('sponsor'), 'выключен')
        self.assertEqual(self.run_config('link'), link)


if __name__ == '__main__':
    unittest.main()
