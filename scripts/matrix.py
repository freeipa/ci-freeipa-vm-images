#!/usr/bin/env python3
"""Print the GitHub Actions matrix for images.yaml as JSON.

    scripts/matrix.py [--only fedora-44,fedora-45]

Each entry carries `packages` as a JSON string, ready to pass to
render-preset.py through an environment variable. Entries that share
`name` with different `arch` are separate jobs (one runner per arch) and
become members of one multi-arch manifest list in the registry.
"""
import argparse
import json
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
IMAGES = os.path.join(HERE, '..', 'images.yaml')
KEYS = ('name', 'distro', 'release', 'guest_packages')
# the runner label each arch needs: a job only builds and (when it boots
# a VM) tests an image of its own architecture
RUNNER = {'x86_64': 'ubuntu-24.04', 'aarch64': 'ubuntu-24.04-arm'}


def load(path=IMAGES):
    with open(path) as f:
        images = (yaml.safe_load(f) or {}).get('images') or []
    seen = []
    for i in images:
        i.setdefault('arch', 'x86_64')
        key = (i.get('name'), i.get('arch'))
        if key in seen:
            raise SystemExit(f'images.yaml: duplicate name/arch: {key}')
        seen.append(key)
        missing = [k for k in KEYS if k not in i]
        if missing:
            raise SystemExit(f'images.yaml: {i.get("name")}: missing {missing}')
        if i['distro'] not in ('fedora', 'centos'):
            raise SystemExit(f'images.yaml: {i["name"]}: unknown distro '
                             f'{i["distro"]!r}')
        if i['arch'] not in RUNNER:
            raise SystemExit(f'images.yaml: {i["name"]}: unknown arch '
                             f'{i["arch"]!r} (known: {sorted(RUNNER)})')
    return images


def matrix(images, only=None):
    if only:
        unknown = set(only) - {i['name'] for i in images}
        if unknown:
            raise SystemExit(f'unknown image name(s): {sorted(unknown)}')
        images = [i for i in images if i['name'] in only]
    return {'include': [{
        'name': i['name'], 'distro': i['distro'], 'release': str(i['release']),
        'arch': i['arch'], 'runs_on': RUNNER[i['arch']],
        'update': i.get('update', ''),
        'packages': json.dumps(i['guest_packages']),
        'experimental': bool(i.get('experimental')),
    } for i in images]}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--only', default='',
                    help='comma separated image names (default: all)')
    args = ap.parse_args(argv)
    only = [n for n in args.only.split(',') if n.strip()]
    only = [n.strip() for n in only]
    print(json.dumps(matrix(load(), only), separators=(',', ':')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
