#!/usr/bin/env python3
"""Read and atomically edit the persistent container configuration."""
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlencode


def save(path, value):
    tmp = path.with_suffix('.new')
    with tmp.open('w', encoding='utf-8') as handle:
        json.dump(value, handle, indent=2)
        handle.write('\n')
    tmp.chmod(0o600)
    os.replace(tmp, path)


def main():
    base = Path(sys.argv[1])
    action = sys.argv[2]
    config = base / 'config'
    if action == 'init':
        domain, mode, public_ip = sys.argv[3:6]
        secret = os.urandom(16).hex()
        config.mkdir(parents=True, exist_ok=True)
        save(config / 'config.json', {
            'public_hostname': domain, 'base_path': '',
            'listen': '127.0.0.1:8080', 'admin_listen': '127.0.0.1:8081',
            'public_dir': '/srv/tproxy-site', 'static_routes': 'exact',
            'token_key_file': '/etc/tproxy-server/token.key',
            'profiles_file': '/etc/tproxy-server/profiles.json',
        })
        save(config / 'profiles.json', {'profiles': [{
            'name': 'default', 'secret': 'dd' + secret,
            'backend': '127.0.0.1:2398', 'carrier_mode': mode,
        }]})
        (config / 'token.key').write_bytes(os.urandom(32))
        (config / 'token.key').chmod(0o600)
        (config / 'backend.env').write_text(
            f'SECRET={secret}\nPUBLIC_IP={public_ip}\nTAG=\n', encoding='utf-8')
        (config / 'backend.env').chmod(0o600)
        return
    cfg = json.loads((config / 'config.json').read_text())
    profiles = json.loads((config / 'profiles.json').read_text())
    profile = profiles['profiles'][0]
    if action == 'domain':
        print(cfg['public_hostname'])
    elif action == 'link':
        print('https://t.me/webproxy?' + urlencode({
            'server': cfg['public_hostname'], 'secret': profile['secret']}))
    elif action in ('secret', 'rotate-secret'):
        if action == 'secret' and len(sys.argv) == 3:
            print(profile['secret'])
        else:
            secret = os.urandom(16).hex() if action == 'rotate-secret' else sys.argv[3].lower()
            if secret.startswith('dd') and len(secret) == 34:
                secret = secret[2:]
            if not re.fullmatch('[0-9a-f]{32}', secret):
                raise ValueError('Секрет должен содержать 32 hex символа или dd + 32 hex символа')
            for item in profiles['profiles']:
                item['secret'] = 'dd' + secret
            path = config / 'backend.env'
            content = path.read_text()
            if not re.search(r'^SECRET=[0-9a-f]{32}$', content, re.M):
                raise ValueError('Не найден секрет MTProxy в backend.env')
            tmp = path.with_suffix('.new')
            tmp.write_text(re.sub(r'^SECRET=.*$', 'SECRET=' + secret, content, flags=re.M))
            tmp.chmod(0o600)
            os.replace(tmp, path)
            save(config / 'profiles.json', profiles)
    elif action == 'mode':
        if len(sys.argv) == 3:
            print(profile.get('carrier_mode', 'https'))
        else:
            mode = sys.argv[3]
            if mode not in ('https', 'https-lanes'):
                raise ValueError('Режим должен быть https или https-lanes')
            for item in profiles['profiles']:
                item['carrier_mode'] = mode
            save(config / 'profiles.json', profiles)
    elif action == 'sponsor':
        path = config / 'backend.env'
        content = path.read_text()
        if len(sys.argv) == 3:
            print(re.search(r'^TAG=(.*)$', content, re.M)[1] or 'выключен')
        else:
            tag = sys.argv[3].lower()
            if tag == 'off':
                tag = ''
            if tag and not re.fullmatch('[0-9a-f]{32}', tag):
                raise ValueError('Тег должен содержать 32 hex символа')
            tmp = path.with_suffix('.new')
            tmp.write_text(re.sub(r'^TAG=.*$', 'TAG=' + tag, content, flags=re.M))
            tmp.chmod(0o600)
            os.replace(tmp, path)
    else:
        raise ValueError('Неизвестная команда')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError) as error:
        print(f'Ошибка конфигурации: {error}', file=sys.stderr)
        sys.exit(1)
