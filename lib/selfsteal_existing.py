#!/usr/bin/env python3
"""Preserve exact certificate volumes when adopting native SelfSteal."""
import json
from pathlib import Path
import re
import sys


def main():
    base = Path(sys.argv[1])
    argument = sys.argv[2]
    metadata = base / 'selfsteal-existing.json'
    if argument == '--compose':
        values = json.loads(metadata.read_text())
        path = base / 'compose.yaml'
        content = path.read_text()
        content = content.replace('image: caddy:2.11.4', 'image: ' + values['image'])
        for mount in values.get('extra_mounts', []):
            content = content.replace('      - caddy-data:/data',
                '      - ' + json.dumps(mount + ':ro') + '\n      - caddy-data:/data')
        for key in ('data', 'config'):
            content = content.replace(f'  caddy-{key}:\n',
                f'  caddy-{key}:\n    external: true\n    name: {values[key]}\n')
        path.write_text(content)
    elif argument == '--backup':
        print(json.loads(metadata.read_text())['backup'])
    elif argument == '--image':
        print(json.loads(metadata.read_text())['image'])
    else:
        backup = Path(argument)
        inspection = json.loads((backup / 'container.json').read_text())[0]
        values = {'backup': str(backup.resolve())}
        image = inspection['Config']['Image']
        if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_./:@-]*', image):
            raise ValueError('Некорректное имя образа Caddy')
        values['image'] = image
        values['extra_mounts'] = [m['Source'] + ':' + m['Destination']
            for m in inspection['Mounts'] if m['Type'] == 'bind'
            and m['Destination'] in ('/etc/caddy/ssl', '/etc/letsencrypt')]
        for key in ('data', 'config'):
            mounts = [m for m in inspection['Mounts'] if m['Destination'] == '/' + key]
            if len(mounts) != 1 or mounts[0]['Type'] != 'volume':
                raise ValueError(f'SelfSteal /{key}: требуется именованный Docker volume')
            name = mounts[0]['Name']
            if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*', name):
                raise ValueError('Некорректное имя Docker volume')
            values[key] = name
        metadata.write_text(json.dumps(values) + '\n')
        metadata.chmod(0o600)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError) as error:
        print(f'Ошибка подключения SelfSteal: {error}', file=sys.stderr)
        sys.exit(1)
