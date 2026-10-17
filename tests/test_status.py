import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') or 'C:/Program Files/Git/bin/bash.exe'
MOCK = r'''
source "$1/prstaproxy.sh"
backend_type(){ printf '%s' "${TEST_BACKEND:-containers}"; }
active_domain(){ printf '%s' proxy.example.com; }
active_mode(){ printf '%s' https; }
webmtproxy(){ printf '%s' 'https://t.me/webproxy?server=proxy.example.com&secret=test'; }
systemctl(){
 if [[ "${@: -1}" == "${TEST_FAILED_SERVICE:-}" ]]; then printf '%s' failed
 else printf '%s' active; fi
}
test_metrics(){ printf 'tproxy_sessions_live 2\ntproxy_bytes_up_total 1024\ntproxy_bytes_down_total 2048\n'; }
curl(){ test_metrics; }
timeout(){ shift; "$@"; }
docker(){
 if [[ "$1" == exec ]]; then
  [[ "${TEST_METRICS:-available}" != missing ]] || return 1
  test_metrics
 elif [[ "${@: -1}" == prostoweb-relay-1 ]]; then printf '%s' "${TEST_RELAY:-running / healthy}"
 else printf '%s' running; fi
}
dashboard
'''


class StatusTests(unittest.TestCase):
    def render(self, **values):
        result = subprocess.run([BASH, '-c', MOCK, '_', ROOT.as_posix()],
                                env={**os.environ, **values}, capture_output=True,
                                encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stderr)
        return re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)

    def test_healthy_stack_shows_only_overall_status(self):
        output = self.render()
        self.assertIn('Статус ОК', output)
        self.assertNotIn('НЕ ОК', output)
        self.assertNotIn('running', output)
        self.assertNotIn('Прокси containers', output)

    def test_unhealthy_relay_is_reported_under_status(self):
        output = self.render(TEST_RELAY='running / unhealthy')
        self.assertIn('Статус НЕ ОК ✗\n    relay — running / unhealthy', output)
        self.assertNotIn('caddy —', output)
        self.assertNotIn('mtproxy —', output)

    def test_missing_metrics_cannot_be_reported_as_healthy(self):
        output = self.render(TEST_METRICS='missing')
        self.assertIn('Статус НЕ ОК', output)
        self.assertIn('WEB-релей — метрики недоступны', output)

    def test_legacy_stack_checks_required_services_only(self):
        output = self.render(TEST_BACKEND='webmtproxy', TEST_FAILED_SERVICE='mtproxy')
        self.assertIn('Статус НЕ ОК ✗\n    mtproxy — failed', output)
        output = self.render(TEST_BACKEND='webmtproxy', TEST_FAILED_SERVICE='telemt')
        self.assertIn('Статус ОК', output)


if __name__ == '__main__':
    unittest.main()
