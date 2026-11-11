# ci-freeipa-vm-images

Regularly built VM images for FreeIPA testing, published to this repository's
container registry.

A scheduled GitHub Actions workflow takes the upstream cloud image of each
release listed in [`images.yaml`](images.yaml), brings it up to date (Fedora:
with `updates-testing`), installs a FreeIPA server on it with
[ci-freeipa](https://github.com/abbra/ci-freeipa), and only if that passes
pushes the image to `ghcr.io/<owner>/<repo>/<image>`. A broken update never
reaches the registry.

The images are *containerdisks*: a `FROM scratch` image that holds one file,
`/disk/disk.qcow2`. ci-freeipa pulls one with podman, copies the disk out, and
boots VMs from it:

```yaml
# a ci-freeipa preset
vm:
  backend: qemu
  image: containerdisk:ghcr.io/freeipa/ci-freeipa-vm-images/fedora-45:latest
```

## What a job does

| Step | Script | |
|---|---|---|
| Fetch | `scripts/fetch-image.sh` | newest upstream image of the release; SHA-256 checked against the upstream checksum file |
| Update | `scripts/update-image.sh` | boots it under qemu/KVM, runs the update command, records the packages it changed, cleans the guest (cloud-init state, ssh keys and host keys, machine id, caches), flattens and compresses it |
| Test | ci-freeipa | `scripts/render-preset.py` writes a one-server preset; `freeipa-env up` installs the distro FreeIPA packages in a VM started from the image; `run` executes ipatests' `TestInstallMaster::test_install_master` |
| Publish | `scripts/publish.sh` | builds the containerdisk, labels it, pushes `:latest` and `:YYYYMMDD` |

Each image in `images.yaml` is one matrix job, so a failing release does not
stop the others. An image marked `experimental` may fail without failing the
workflow.

The upstream sources are `download.fedoraproject.org` (Fedora Cloud Base
*Generic*) and `cloud.centos.org` (CentOS Stream *GenericCloud*).

## Setting it up

1. Push this repository to GitHub and enable Actions.
2. Nothing to configure for publishing: the workflow uses the repository's
   `GITHUB_TOKEN` with `packages: write`. The first publish creates the
   package as **private** and links it to the repository (the image carries
   `org.opencontainers.image.source`). Make the package public in its
   settings if others should pull it without a login.
3. The test checks out `abbra/ci-freeipa` at `main`. To use another, set the
   repository variables `CI_FREEIPA_REPO` and `CI_FREEIPA_REF`.
4. The schedule is in `.github/workflows/build.yml` (`cron`, Mondays 03:17
   UTC). Every run pushes about one image per release, so a daily schedule
   uses registry storage quickly.

Run it by hand from the Actions tab: *Build and publish VM images* >
*Run workflow*. `only` names images (`fedora-45`), and `publish` can be
switched off for a dry run. A pull request builds and tests `fedora-45` only,
and publishes nothing.

## Images

Edit [`images.yaml`](images.yaml); one entry is one image.

| Field | |
|---|---|
| `name` | the image name in the registry |
| `distro`, `release` | `fedora` and a release number, or `centos` and a Stream major version |
| `update` | the command that updates the VM |
| `guest_packages` | what the test installs (a ci-freeipa `vm.guest_packages`) |
| `experimental` | a failure does not fail the workflow |

Tags: `latest` moves with every successful build; `YYYYMMDD` stays. The image
labels record the upstream file and its SHA-256 and the update command, and
the SHA-256 of the disk.

## Running the steps yourself

On a machine with KVM, qemu, xorriso and podman:

```sh
scripts/fetch-image.sh fedora 45 work
. work/base.env
scripts/update-image.sh "$BASE_FILE" work/image.qcow2 \
    'dnf -y --refresh --enablerepo=updates-testing upgrade' work/report
scripts/render-preset.py --name fedora-45 --image "$PWD/work/image.qcow2" > work/preset.yaml
~/src/ci-freeipa/env/freeipa-env up   work/preset.yaml
~/src/ci-freeipa/env/freeipa-env run  work/preset.yaml
~/src/ci-freeipa/env/freeipa-env down work/preset.yaml
scripts/publish.sh work/image.qcow2 localhost/fedora-45:test      # add --push to push
```

`scripts/matrix.py` prints the job matrix; `python3 -m pytest tests` runs the
checks (they need podman and qemu-img for the publish tests and skip without).

## Limits

- **The test installs FreeIPA from the stable repositories.** The image has
  `updates-testing` applied, so the packages it already holds are the newer
  ones, but FreeIPA itself comes from `fedora` and `updates`. Testing a
  `freeipa` build from `updates-testing` needs that repository enabled in the
  test VM; the workflow does not do it.
- **CentOS Stream has no `updates-testing`.** Its update is the latest Stream
  content. The CentOS entries are `experimental`, their package list is a
  guess for EL, and they have not been run.
- **A GitHub-hosted runner needs `/dev/kvm`.** The workflow enables it with a
  udev rule and fails with a clear message when the runner has none.
- The image keeps the upstream partition layout, grown to 20 GB so that the
  update has room; ci-freeipa grows it again to its own `vm.disk`.
