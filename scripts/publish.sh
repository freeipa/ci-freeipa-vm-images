#!/bin/bash
# Build a containerdisk image from a qcow2 and, with --push, push it.
#
# A containerdisk is a scratch image that holds one file, /disk/disk.qcow2.
# ci-freeipa uses it as `vm.image: containerdisk:REF`.
#
# Usage: publish.sh [--push] DISK.qcow2 REF [REF...]
#   The image is built as the first REF and tagged with the others.
#
# Labels come from the environment, when set:
#   SOURCE_URL     org.opencontainers.image.source (links a GHCR package to
#                  its repository)
#   IMAGE_VERSION  org.opencontainers.image.version
#   BASE_NAME      the upstream image this one was made from
#   BASE_SHA256    its SHA-256
#   UPDATE         the command that brought it up to date
# The disk's own SHA-256 and the build time are always recorded.
# Log in first (`podman login`); this script does not handle credentials.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
push=
[ "${1:-}" != --push ] || { push=1; shift; }
[ $# -ge 2 ] || die "usage: $0 [--push] DISK.qcow2 REF [REF...]"
disk="$1"; shift
refs=("$@")
[ -f "$disk" ] || die "no such file: $disk"
qemu-img info "$disk" | grep -q 'file format: qcow2' || die "$disk is not a qcow2 file"

ctx="$(mktemp -d)"
trap 'rm -rf "$ctx"' EXIT
ln "$disk" "$ctx/disk.qcow2" 2>/dev/null || cp --reflink=auto "$disk" "$ctx/disk.qcow2"
printf 'FROM scratch\nCOPY disk.qcow2 /disk/disk.qcow2\n' > "$ctx/Containerfile"

sum="$(sha256sum "$disk" | cut -d' ' -f1)"
labels=(--label "org.opencontainers.image.title=$(basename "$disk")"
        --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        --label "io.github.freeipa-vm-images.disk-sha256=$sum")
[ -z "${SOURCE_URL:-}" ] || labels+=(--label "org.opencontainers.image.source=$SOURCE_URL")
[ -z "${IMAGE_VERSION:-}" ] || labels+=(--label "org.opencontainers.image.version=$IMAGE_VERSION")
[ -z "${BASE_NAME:-}" ] || labels+=(--label "io.github.freeipa-vm-images.base=$BASE_NAME")
[ -z "${BASE_SHA256:-}" ] || labels+=(--label "io.github.freeipa-vm-images.base-sha256=$BASE_SHA256")
[ -z "${UPDATE:-}" ] || labels+=(--label "io.github.freeipa-vm-images.update=$UPDATE")

podman build -q "${labels[@]}" -t "${refs[0]}" -f "$ctx/Containerfile" "$ctx" >/dev/null
for ref in "${refs[@]:1}"; do podman tag "${refs[0]}" "$ref"; done
echo "built ${refs[*]} (disk sha256 $sum)"
if [ -n "$push" ]; then
    for ref in "${refs[@]}"; do podman push -q "$ref" >/dev/null; echo "pushed $ref"; done
fi
