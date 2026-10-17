import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') or 'C:/Program Files/Git/bin/bash.exe'
spec = importlib.util.spec_from_file_location('selfsteal_config', ROOT / 'lib/selfsteal_config.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class SelfStealIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name) / 'proxy'
        self.directory = Path(self.temp.name) / 'selfsteal'
        self.base.mkdir()
        (self.base / 'public-ip').write_text('203.0.113.1')
        (self.directory / 'html').mkdir(parents=True)
        (self.directory / 'html/index.html').write_text('<h1>Operator site</h1>')
        subprocess.run([sys.executable, str(ROOT / 'lib/config.py'), str(self.base),
                        'init', 'proxy.example.com', 'https', '203.0.113.1'], check=True)
        result = subprocess.run([BASH, str(ROOT / 'lib/selfsteal.sh'), '--zlp-prepare',
                                 'proxy.example.com'], env={**os.environ,
                                 'BASE': self.base.as_posix(),
                                 'SELFSTEAL_DIR': self.directory.as_posix()},
                                capture_output=True, text=True, encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def tearDown(self):
        self.temp.cleanup()

    def test_native_configuration_and_bridge_are_idempotent(self):
        native = (self.directory / 'Caddyfile').read_text()
        self.assertIn('proxy_protocol', native)
        self.assertIn('SELF_STEAL_DOMAIN=proxy.example.com', (self.directory / '.env').read_text())
        secret = (self.base / 'config/profiles.json').read_bytes()
        bridge.integrate(self.base, self.directory)
        configured = (self.directory / 'Caddyfile').read_text()
        bridge.integrate(self.base, self.directory)
        self.assertEqual((self.directory / 'Caddyfile').read_text(), configured)
        self.assertEqual(configured.count(bridge.MARKER), 1)
        self.assertIn('servers 0.0.0.0:443', configured)
        self.assertIn('default_bind 0.0.0.0', configured)
        config = json.loads((self.base / 'config/config.json').read_text())
        self.assertNotIn('public_dir', config)
        self.assertEqual(config['public_upstream'], 'http://127.0.0.1:18083')
        self.assertEqual((self.base / 'config/profiles.json').read_bytes(), secret)
        self.assertEqual((self.directory / 'html/index.html').read_text(), '<h1>Operator site</h1>')

    def test_domain_mismatch_does_not_change_proxy_or_caddy(self):
        env = self.directory / '.env'
        env.write_text(env.read_text().replace('proxy.example.com', 'other.example.com'))
        before = (self.base / 'config/config.json').read_bytes()
        caddy = (self.directory / 'Caddyfile').read_bytes()
        with self.assertRaises(ValueError):
            bridge.integrate(self.base, self.directory)
        self.assertEqual((self.base / 'config/config.json').read_bytes(), before)
        self.assertEqual((self.directory / 'Caddyfile').read_bytes(), caddy)

    def test_both_commands_use_one_compose_project(self):
        bridge.integrate(self.base, self.directory)
        result = subprocess.run([BASH, '-c',
                                 'source "$1/prstaproxy.sh"; compose(){ :; }; write_compose',
                                 '_', ROOT.as_posix()], env={**os.environ,
                                 'BASE': self.base.as_posix(),
                                 'SELFSTEAL_DIR': self.directory.as_posix()},
                                capture_output=True, text=True, encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stderr)
        compose = (self.base / 'compose.yaml').read_text()
        self.assertIn('name: prostoweb', compose)
        self.assertIn('container_name: caddy-selfsteal', compose)
        self.assertIn('127.0.0.1:9443:9443', compose)
        self.assertIn(f'{self.directory.as_posix()}/html:/var/www/html:ro', compose)
        self.assertEqual((self.directory / 'docker-compose.yml').read_text(), compose)

    def test_rollback_restores_original_proxy_and_native_files(self):
        (self.base / 'compose.yaml').write_text('original proxy compose\n')
        (self.directory / 'docker-compose.yml').write_text('original native compose\n')
        before_config = (self.base / 'config/config.json').read_bytes()
        before_caddy = (self.directory / 'Caddyfile').read_bytes()
        backup = Path(self.temp.name) / 'backup'
        # Git Bash cannot apply POSIX directory permissions to Windows ACLs.
        permission_adapter = 'mkdir(){ [[ "$1" != -m ]] || shift 2; command mkdir "$@"; }; ' if os.name == 'nt' else ''
        result = subprocess.run([BASH, '-c',
                                 'source "$1/prstaproxy.sh"; ' + permission_adapter + 'snapshot_deployment "$2"; '
                                 'python3 "$APP/lib/selfsteal_config.py" "$BASE" "$SELFSTEAL_DIR"; '
                                 'compose(){ :; }; write_compose; restore_deployment "$2"',
                                 '_', ROOT.as_posix(), backup.as_posix()], env={**os.environ,
                                 'BASE': self.base.as_posix(),
                                 'SELFSTEAL_DIR': self.directory.as_posix()},
                                capture_output=True, text=True, encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'config/config.json').read_bytes(), before_config)
        self.assertEqual((self.directory / 'Caddyfile').read_bytes(), before_caddy)
        self.assertEqual((self.directory / 'docker-compose.yml').read_text(), 'original native compose\n')
        self.assertFalse((self.base / '.selfsteal').exists())


class NativeInstallationTests(unittest.TestCase):
    def test_original_install_selects_template_without_reading_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'public-ip').write_text('203.0.113.1')
            native = base / 'native'
            native.mkdir()
            adapter = (ROOT / 'lib/selfsteal.sh').read_text()
            prefix = adapter.split('if [[ "$zlp_internal" == true ]]; then')[0]
            prefix = prefix.replace('ZLP_APP=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)',
                                    'ZLP_APP=$TEST_APP')
            code = 'set -- --zlp-prepare proxy.example.com; ' + prefix + r'''
ZLP_NATIVE_INSTALL=1
FORCE_MODE=true; FORCE_DOMAIN=proxy.example.com; FORCE_PORT=9443; FORCE_TEMPLATE=
check_running_as_root(){ :; }
check_system_requirements(){ return 0; }
validate_caddyfile(){ return 0; }
ensure_runtime_image(){ return 0; }
download_template(){ printf '%s' "$1" > "$APP_DIR/chosen-template"; }
read(){ echo UNEXPECTED-PROMPT; return 99; }
native_install_command
'''
            result = subprocess.run([BASH, '-c', code], env={**os.environ,
                'BASE': base.as_posix(), 'SELFSTEAL_DIR': native.as_posix(),
                'TEST_APP': ROOT.as_posix()}, capture_output=True,
                encoding='utf-8', errors='replace')
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertNotIn('UNEXPECTED-PROMPT', result.stdout)
            chosen = int((native / 'chosen-template').read_text())
            self.assertIn(chosen, range(1, 12))
            self.assertIn('SELF_STEAL_DOMAIN=proxy.example.com', (native / '.env').read_text())

if __name__ == '__main__':
    unittest.main()
