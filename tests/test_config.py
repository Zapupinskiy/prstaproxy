import importlib.util
import json
import os
import shutil
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
        self.run_config('mode', 'https')
        self.assertEqual(self.run_config('mode'), 'https')
        self.assertEqual(self.run_config('link'), link)
        profile = json.loads((self.base / 'config/profiles.json').read_text())['profiles'][0]
        self.assertEqual(profile['backend'], '127.0.0.1:2398')
        self.assertEqual(len((self.base / 'config/token.key').read_bytes()), 32)

    def test_mode_command_restarts_only_relay_after_valid_change(self):
        root = SCRIPT.parent.parent
        bash = shutil.which('bash') or 'C:/Program Files/Git/bin/bash.exe'
        mock = r'''source "$1/prstaproxy.sh"
backend_type(){ echo containers; }
python3(){ "$TEST_PYTHON" "$@"; }
compose(){ printf '%s\n' "$*" >> "$TEST_CALLS"; }
webmtproxy mode "$TEST_MODE"
'''
        calls = self.base / 'calls'
        environment = {**os.environ, 'BASE': self.base.as_posix(),
                       'TEST_PYTHON': Path(sys.executable).as_posix(),
                       'TEST_CALLS': calls.as_posix(), 'PYTHONUTF8': '1'}
        link = self.run_config('link')
        for mode in ('https-lanes', 'https'):
            result = subprocess.run([bash, '-c', mock, '_', root.as_posix()],
                                    env={**environment, 'TEST_MODE': mode},
                                    capture_output=True, encoding='utf-8')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.run_config('mode'), mode)
            self.assertEqual(self.run_config('link'), link)
        self.assertEqual(calls.read_text().splitlines(), ['restart relay', 'restart relay'])
        before = calls.read_bytes()
        result = subprocess.run([bash, '-c', mock, '_', root.as_posix()],
                                env={**environment, 'TEST_MODE': 'invalid'},
                                capture_output=True, encoding='utf-8')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls.read_bytes(), before)
        self.assertEqual(self.run_config('mode'), 'https')

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
            self.assertEqual(self.run_config('secret-raw'), expected)
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
