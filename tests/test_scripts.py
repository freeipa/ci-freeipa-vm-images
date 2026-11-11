import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import uuid

import pytest
import yaml

ROOT = os.path.join(os.path.dirname(__file__), '..')
SCRIPTS = os.path.join(ROOT, 'scripts')


def load(name):
    spec = importlib.util.spec_from_file_location(
        name.replace('-', '_'), os.path.join(SCRIPTS, f'{name}.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


matrix = load('matrix')
render = load('render-preset')


def test_every_image_in_images_yaml_is_usable():
    m = matrix.matrix(matrix.load())['include']
    assert {i['name'] for i in m} >= {'fedora-44', 'fedora-45'}
    for i in m:
        assert i['distro'] in ('fedora', 'centos') and i['release'].isdigit()
        assert isinstance(json.loads(i['packages']), list)
        assert isinstance(i['experimental'], bool)
        # the registry name must be a valid lowercase repository path
        assert i['name'] == i['name'].lower() and ' ' not in i['name']


def test_only_selects_named_images_and_rejects_unknown_ones():
    images = matrix.load()
    got = matrix.matrix(images, ['fedora-45'])['include']
    assert [i['name'] for i in got] == ['fedora-45']
    with pytest.raises(SystemExit, match='unknown image'):
        matrix.matrix(images, ['fedora-1'])


def test_a_duplicate_or_incomplete_entry_is_refused(tmp_path):
    bad = tmp_path / 'images.yaml'
    bad.write_text('images:\n  - {name: a, distro: fedora, release: "1"}\n')
    with pytest.raises(SystemExit, match='missing'):
        matrix.load(str(bad))
    bad.write_text(yaml.safe_dump({'images': [
        {'name': 'a', 'distro': 'fedora', 'release': '1', 'update': 'u',
         'guest_packages': []}] * 2}))
    with pytest.raises(SystemExit, match='duplicate'):
        matrix.load(str(bad))


def test_the_preset_is_one_server_started_from_the_image():
    doc = render.preset('fedora-44', '/x.qcow2', ['ipa-distro'])
    assert [h['role'] for h in doc['hosts']] == ['master']
    assert doc['provider'] == 'nested' and doc['inner'] == 'external'
    assert doc['vm']['image'] == '/x.qcow2'
    assert doc['vm']['guest_packages'] == ['ipa-distro']
    assert doc['run']['tests'][0].endswith('TestInstallMaster::test_install_master')


needs_podman = pytest.mark.skipif(
    not (shutil.which('podman') and shutil.which('qemu-img')),
    reason='podman and qemu-img needed')


@needs_podman
def test_publish_labels_the_image_so_ghcr_links_it_to_the_repository(tmp_path):
    disk = tmp_path / 'disk.qcow2'
    subprocess.run(['qemu-img', 'create', '-q', '-f', 'qcow2', str(disk), '8M'],
                   check=True)
    tag = uuid.uuid4().hex[:8]
    refs = [f'localhost/vmi-test-{tag}:latest', f'localhost/vmi-test-{tag}:20260101']
    env = dict(os.environ, SOURCE_URL='https://github.com/o/r',
               IMAGE_VERSION='20260101', BASE_NAME='base.qcow2',
               BASE_SHA256='abc', UPDATE='dnf upgrade')
    try:
        subprocess.run([os.path.join(SCRIPTS, 'publish.sh'), str(disk), *refs],
                       check=True, env=env, capture_output=True)
        for ref in refs:   # both tags exist and carry the labels
            out = subprocess.run(
                ['podman', 'image', 'inspect', '--format', '{{json .Labels}}', ref],
                check=True, capture_output=True, text=True).stdout
            labels = json.loads(out)
            assert labels['org.opencontainers.image.source'] == 'https://github.com/o/r'
            assert labels['org.opencontainers.image.version'] == '20260101'
            assert labels['io.github.freeipa-vm-images.base'] == 'base.qcow2'
            assert labels['io.github.freeipa-vm-images.disk-sha256'] == \
                hashlib.sha256(disk.read_bytes()).hexdigest()
    finally:
        for ref in refs:
            subprocess.run(['podman', 'rmi', '-f', ref], capture_output=True)


def test_publish_refuses_a_file_that_is_not_a_qcow2(tmp_path):
    if not shutil.which('qemu-img'):
        pytest.skip('qemu-img needed')
    junk = tmp_path / 'junk'
    junk.write_text('not a disk')
    p = subprocess.run([os.path.join(SCRIPTS, 'publish.sh'), str(junk),
                        'localhost/never:1'], capture_output=True, text=True)
    assert p.returncode != 0 and 'not a qcow2' in p.stderr
