#!/usr/bin/env python3
"""Print the ci-freeipa preset that installs a FreeIPA server on an image.

    render-preset.py --name fedora-44 --image /path/to/image.qcow2 \\
        --packages '["ipa-distro"]' > preset.yaml

One VM, `master1`, started from the image with the distro FreeIPA packages
installed by dnf; the test is ipatests' single-master install. Run it with
`freeipa-env up PRESET`, `run PRESET` and `down PRESET` from a ci-freeipa
checkout.
"""
import argparse
import json
import sys

import yaml

# the ipatests install test that needs one server and nothing else
TEST = ('test_integration/test_installation.py'
        '::TestInstallMaster::test_install_master')


def preset(name, image, packages):
    return {
        'name': f'vm-image-{name}',
        'domain': 'ipa.test',
        'provider': 'nested',
        'inner': 'external',
        'hosts': [{'role': 'master', 'name': 'master1'}],
        'resources': {'master': {'memory': '3300m',
                                 'memory-swap': '6600m'}},
        'run': {'mode': 'integration', 'tests': [TEST]},
        'vm': {'backend': 'qemu', 'image': image, 'cpus': 4, 'disk': '40G',
               'guest_packages': packages},
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument('--name', required=True)
    ap.add_argument('--image', required=True, help='qcow2 file or containerdisk:REF')
    ap.add_argument('--packages', default='["ipa-distro"]',
                    help='JSON list for vm.guest_packages')
    args = ap.parse_args(argv)
    packages = json.loads(args.packages)
    if not isinstance(packages, list) or not all(isinstance(p, str) for p in packages):
        ap.error('--packages must be a JSON list of strings')
    yaml.safe_dump(preset(args.name, args.image, packages), sys.stdout,
                   sort_keys=False)
    return 0


if __name__ == '__main__':
    sys.exit(main())
