import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') or 'C:/Program Files/Git/bin/bash.exe'

class WorkflowTests(unittest.TestCase):
    def shell(self, script, *args):
        result = subprocess.run([BASH, '-c', 'source "$1/prstaproxy.sh"; ' + script,
                                 '_', ROOT.as_posix(), *args], capture_output=True,
                                encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result.stdout

    def test_stage_preserves_registration_secret_and_tag(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = self.shell('''
BASE=$2; LOG="$BASE/install.log"; DOMAIN=proxy.example.com; MODE=https-lanes
INSTALL_SECRET=0123456789abcdef0123456789abcdef
INSTALL_TAG=abcdef0123456789abcdef0123456789
stage 4 configuration bash -c 'printf "%s|%s|%s|%s" "$DOMAIN" "$MODE" "$INSTALL_SECRET" "$INSTALL_TAG"'
''', Path(temporary).as_posix())
            self.assertIn('proxy.example.com|https-lanes|0123456789abcdef0123456789abcdef|abcdef0123456789abcdef0123456789', output)

    def test_live_log_propagates_failure_and_keeps_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.shell('''
LOG="$2/install.log"
if run_live_log bash -c 'echo failed-build; exit 17'; then exit 99; else rc=$?; fi
[[ $rc == 17 ]]
grep -q failed-build "$LOG"
''', Path(temporary).as_posix())

    def test_backup_creates_snapshot_in_new_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'config').mkdir()
            (base / 'config' / 'profiles.json').write_text('{"secret":"test"}')
            (base / 'compose.yaml').write_text('name: prostoweb')
            (base / 'site').mkdir()
            (base / 'site' / 'index.html').write_text('site')
            self.shell('''
BASE=$2; SELFSTEAL_DIR="$BASE/site"
require_root(){ :; }
backup_project
''', base.as_posix())
            snapshots = list((base / 'backups').iterdir())
            self.assertEqual(len(snapshots), 1)
            self.assertTrue((snapshots[0] / 'config' / 'profiles.json').is_file())
            self.assertEqual((snapshots[0] / 'selfsteal' / 'index.html').read_text(), 'site')

    def test_cli_keeps_web_links(self):
        self.assertIn('https://t.me/webproxy?', self.shell('''
require_root(){ :; }; require_installation(){ :; }
webmtproxy(){ printf 'https://t.me/webproxy?server=proxy.example.com'; }
dispatch_command links
'''))

    def test_uninstall_cancel_does_not_stop_stack(self):
        self.shell('''
require_root(){ :; }; require_installation(){ :; }; backend_type(){ echo containers; }
ask(){ printf -v "$1" '%s' no; }
compose(){ echo unexpected-stop; exit 99; }
uninstall_project
''')

    def test_screen_clears_and_accumulates_answers_and_statuses(self):
        output = self.shell('''
summary_add 'Домен' proxy.example.com
screen_begin 2 'Настройка'
screen_finish success
summary_add 'Режим' https-lanes
screen_begin 3 'Следующий экран'
screen_finish error
screen_begin 4 'Итог'
''')
        screens = output.split('\x1b[2J\x1b[H')[1:]
        self.assertEqual(len(screens), 3)
        self.assertIn('Домен: proxy.example.com', screens[1])
        self.assertIn('Режим: https-lanes', screens[1])
        self.assertIn('\x1b[32m✓\x1b[0m 2', screens[1])
        self.assertIn('\x1b[31m✗\x1b[0m 3', screens[2])
        self.assertIn('\x1b[34m', screens[2])
        self.assertIn('\x1b[34mЭТАП 4', screens[2])

    def test_dependencies_skip_apt_when_everything_present(self):
        output = self.shell('''
dpkg-query(){ printf 'install ok installed'; }
docker(){ return 0; }
systemctl(){ return 0; }
apt-get(){ echo unexpected-apt; return 99; }
dependencies
''')
        self.assertNotIn('unexpected-apt', output)
        self.assertIn('Установка системных пакетов не требуется', output)

    def test_dependencies_install_only_missing_package(self):
        output = self.shell('''
dpkg-query(){ [[ "${@: -1}" != jq ]] || return 1; printf 'install ok installed'; }
docker(){ return 0; }
systemctl(){ return 0; }
apt-get(){ printf 'APT:%s\\n' "$*"; }
dependencies
''')
        calls = [line for line in output.splitlines() if line.startswith('APT:')]
        self.assertEqual(calls, ['APT:update', 'APT:install -y --no-install-recommends jq'])

    def test_stage_failure_is_recorded_for_next_screen(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = self.shell('''
LOG="$2/install.log"
if stage 7 build bash -c 'exit 17'; then exit 99; else rc=$?; fi
[[ $rc == 17 ]]
screen_begin 8 retry
''', Path(temporary).as_posix())
            self.assertIn('\x1b[31m✗\x1b[0m 7', output.split('\x1b[2J\x1b[H')[-1])

    def test_install_checks_dependencies_before_network_and_prompts(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = self.shell('''
BASE=$2; LOG="$BASE/install.log"
require_root(){ :; }
source(){ if [[ "$1" == /etc/os-release ]]; then ID=ubuntu; else builtin source "$@"; fi; }
uname(){ echo x86_64; }
backend_type(){ echo none; }
stage(){ printf 'STAGE:%s\\n' "$3"; }
check_connectivity(){ echo NETWORK; return 19; }
ask(){ echo unexpected-prompt; return 99; }
if install_new; then exit 99; else rc=$?; fi
[[ $rc == 19 || $rc == 1 ]]
''', Path(temporary).as_posix())
            self.assertIn('STAGE:dependencies', output)
            self.assertLess(output.index('STAGE:dependencies'), output.index('NETWORK'))
            self.assertNotIn('unexpected-prompt', output)

    def test_loader_does_not_repeat_wrapped_log_lines(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = self.shell('''
LOG="$2/live.log"
terminal_animated(){ return 0; }
run_live_log bash -c 'printf "%200s\\n" "UNIQUE-LONG-LINE"; sleep 1'
''', Path(temporary).as_posix())
            self.assertEqual(output.count('UNIQUE-LONG-LINE'), 1)
            self.assertNotIn('\x1b[11A', output)
            self.assertNotIn('\x1b[10A', output)
            self.assertIn('Выполняется', output)

    def test_log_is_available_before_worker_finishes(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.shell('''
LOG="$2/live.log"
run_live_log bash -c 'echo INITIAL-LIVE-ENTRY; sleep 1; grep -q INITIAL-LIVE-ENTRY "$1"' _ "$LOG"
''', Path(temporary).as_posix())

    def test_compact_header_excludes_detailed_answers(self):
        output = self.shell('''
summary_add 'Домен' proxy.example.com
summary_add 'AD_TAG' private-ad-tag
summary_add 'Telegram-бот' configured
summary_add 'Chat ID' private-chat-id
screen_begin 2 settings
screen_finish success
screen_begin 3 configuration
''')
        self.assertNotIn('private-ad-tag', output)
        self.assertNotIn('private-chat-id', output)
        self.assertNotIn('Telegram-бот', output)
        self.assertIn('Домен: proxy.example.com', output)

    def test_grouped_substeps_share_screen_and_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = self.shell('''
LOG="$2/group.log"
stage 3 'DNS' bash -c 'echo dns-checked'
stage 3 'SelfSteal' bash -c 'echo selfsteal-ready'
[[ ${#UI_HISTORY[@]} == 1 ]]
''', Path(temporary).as_posix())
            self.assertEqual(output.count('\x1b[2J\x1b[H'), 1)
            self.assertIn('dns-checked', output)
            self.assertIn('selfsteal-ready', output)

if __name__ == '__main__':
    unittest.main()
