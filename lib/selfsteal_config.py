#!/usr/bin/env python3
"""Connect the native SelfSteal Caddy/site to the WEB relay without duplicate TLS."""
import json
import os
from pathlib import Path
import re
import sys

MARKER = '# PROSTOVPN WEB PROXY: managed integration'


def integrate(base, directory):
    cfg_path = base / 'config/config.json'
    cfg = json.loads(cfg_path.read_text(encoding='utf-8'))
    domain = cfg['public_hostname']
    env = (directory / '.env').read_text(encoding='utf-8')
    values = dict(re.findall(r'^([A-Z_]+)=(.*)$', env, re.M))
    if values.get('SELF_STEAL_DOMAIN') != domain:
        raise ValueError('Домен SelfSteal должен совпадать с доменом WEB Proxy')
    port = int(values['SELF_STEAL_PORT'])
    if port != 9443:
        raise ValueError('Общая установка использует SelfSteal на 127.0.0.1:9443')
    caddy_path = directory / 'Caddyfile'
    original = caddy_path.read_text(encoding='utf-8')
    addon = directory / 'zlp.Caddyfile'
    if MARKER not in original:
        # The public TLS listener does not accept Reality PROXY protocol headers.
        if not re.match(r'^\s*\{\s*\n', original):
            raise ValueError('Не распознан глобальный блок Caddyfile SelfSteal')
        original = re.sub(r'^(\s*\{\s*\n)', r'\1\tservers 0.0.0.0:443 {\n\t\tprotocols h1 h2\n\t\ttimeouts {\n\t\t\tread_header 10s\n\t\t\tread_body 60s\n\t\t}\n\t}\n', original, count=1)
        # Publish the private TLS listener only on host loopback through Docker.
        original = original.replace('default_bind 127.0.0.1', 'default_bind 0.0.0.0')
        original += '\n' + MARKER + '\nimport /etc/caddy/zlp.Caddyfile\n'
    addon.write_text('''# Managed by zlp: public WEB transport and private SelfSteal site.
https://{$SELF_STEAL_DOMAIN}:443 {
 bind 0.0.0.0
 reverse_proxy 127.0.0.1:8080 {
  transport http {
   response_header_timeout 40s
  }
 }
}
http://:18083 {
 bind 127.0.0.1
 encode gzip
 header -Server
 root * /var/www/html
 try_files {path} /index.html
 file_server
}
''', encoding='utf-8')
    caddy_path.write_text(original, encoding='utf-8')
    cfg.pop('public_dir', None)
    cfg['public_upstream'] = 'http://127.0.0.1:18083'
    tmp = cfg_path.with_suffix('.new')
    tmp.write_text(json.dumps(cfg, indent=2) + '\n', encoding='utf-8')
    tmp.chmod(0o600)
    os.replace(tmp, cfg_path)
    (base / '.selfsteal').write_text(str(directory.resolve()) + '\n', encoding='utf-8')


if __name__ == '__main__':
    try:
        integrate(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, KeyError, IndexError) as error:
        print(f'Ошибка интеграции SelfSteal: {error}', file=sys.stderr)
        sys.exit(1)
