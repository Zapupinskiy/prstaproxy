import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') or 'C:/Program Files/Git/bin/bash.exe'

class ExistingSelfStealTests(unittest.TestCase):
    def shell(self, code, *args, success=True):
        result = subprocess.run([BASH, '-c', 'source "$1/prstaproxy.sh"; '+code,
                                 '_', ROOT.as_posix(), *args], capture_output=True,
                                encoding='utf-8', errors='replace')
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result.stdout

    def test_existing_selfsteal_ports_do_not_block_dns(self):
        output = self.shell('''
existing_selfsteal(){ return 0; }
validate_existing_selfsteal(){ return 0; }
port_busy(){ return 0; }
selfsteal_owns_port(){ return 0; }
check_dns(){ echo DNS-CHECKED; }
check_install_network
''')
        self.assertIn('DNS-CHECKED', output)
        self.assertIn('Порт 80 занят установленным SelfSteal', output)

    def test_other_listener_is_still_rejected(self):
        output = self.shell('''
existing_selfsteal(){ return 0; }
validate_existing_selfsteal(){ return 0; }
port_busy(){ return 0; }
selfsteal_owns_port(){ return 1; }
check_dns(){ echo UNEXPECTED-DNS; }
check_install_network
''', success=False)
        self.assertIn('Порт 80 занят другой службой', output)
        self.assertNotIn('UNEXPECTED-DNS', output)

    def test_owner_check_rejects_mixed_processes(self):
        self.shell('''
docker(){ echo 123; }
ss(){ printf 'LISTEN users:(("caddy",pid=123,fd=1))\\nLISTEN users:(("nginx",pid=456,fd=2))\\n'; }
selfsteal_owns_port 80
''', success=False)

    def test_owner_check_accepts_caddy_pid(self):
        self.shell('''
docker(){ echo 123; }
ss(){ printf 'LISTEN users:(("caddy",pid=123,fd=1))\\n'; }
selfsteal_owns_port 80
''')

    def test_existing_certificate_volumes_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            backup = base / 'backup'
            backup.mkdir()
            (backup / 'container.json').write_text(json.dumps([{'Config': {'Image': 'caddy:2.10.2'}, 'Mounts': [
                {'Destination':'/data','Type':'volume','Name':'original_caddy_data'},
                {'Destination':'/config','Type':'volume','Name':'original_caddy_config'}]}]))
            helper = ROOT / 'lib/selfsteal_existing.py'
            subprocess.run([sys.executable, str(helper), str(base), str(backup)], check=True)
            (base / 'compose.yaml').write_text('image: caddy:2.11.4\nvolumes:\n  caddy-data:\n  caddy-config:\n')
            subprocess.run([sys.executable, str(helper), str(base), '--compose'], check=True)
            content = (base / 'compose.yaml').read_text()
            self.assertIn('name: original_caddy_data', content)
            self.assertIn('name: original_caddy_config', content)
            self.assertEqual(content.count('external: true'), 2)
            self.assertIn('image: caddy:2.10.2', content)

    def test_selfsteal_requires_matching_domain(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / '.env').write_text('SELF_STEAL_DOMAIN=other.example.com\nSELF_STEAL_PORT=9443\n')
            output = self.shell('''
SELFSTEAL_DIR=$2; DOMAIN=proxy.example.com
validate_existing_selfsteal
''', directory.as_posix(), success=False)
            self.assertIn('Домен существующего SelfSteal отличается', output)

    def test_selfsteal_installation_is_skipped_when_reusing(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'config').mkdir()
            (base / 'selfsteal-existing.json').write_text('{}')
            self.shell('''
BASE=$2
python3(){
 case "$*" in *' domain') echo proxy.example.com;; *selfsteal_config.py*) echo REUSED;; *) return 99;; esac
}
SELFSTEAL_DIR="$BASE/native"
prepare_selfsteal
''', base.as_posix())

    def test_failed_install_restores_original_selfsteal(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            backup = base / 'backup'
            native = base / 'native'
            backup.mkdir(); native.mkdir()
            (backup / 'Caddyfile').write_text('original caddy')
            (backup / 'docker-compose.yml').write_text('original compose')
            (native / 'Caddyfile').write_text('modified caddy')
            (native / 'docker-compose.yml').write_text('shared compose')
            (base / '.selfsteal-handoff').touch()
            (base / '.selfsteal').touch()
            (base / 'compose.yaml').write_text('shared compose')
            (base / 'selfsteal-existing.json').write_text(json.dumps({'backup': backup.as_posix()}))
            self.shell('''
BASE=$2; SELFSTEAL_DIR="$BASE/native"
compose(){ echo "PROXY:$*"; }
docker(){ echo "SELFSTEAL:$*"; }
rollback_existing_selfsteal
''', base.as_posix())
            self.assertEqual((native / 'Caddyfile').read_text(), 'original caddy')
            self.assertEqual((native / 'docker-compose.yml').read_text(), 'original compose')
            self.assertFalse((base / '.selfsteal-handoff').exists())
            self.assertFalse((base / 'selfsteal-existing.json').exists())

if __name__ == '__main__':
    unittest.main()
