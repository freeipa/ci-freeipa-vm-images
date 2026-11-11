#!/bin/bash
# Download the newest upstream cloud image of a release and verify its SHA-256.
#
# Usage: fetch-image.sh DISTRO RELEASE OUTDIR
#   DISTRO   fedora | centos
#   RELEASE  Fedora release number, or CentOS Stream major version
#
# Writes OUTDIR/<upstream file name> and OUTDIR/base.env with
#   BASE_FILE, BASE_NAME, BASE_VERSION, BASE_URL, BASE_SHA256
# (shell-sourceable). An image already in OUTDIR with the right checksum is
# not downloaded again.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[ $# -eq 3 ] || die "usage: $0 DISTRO RELEASE OUTDIR"
distro="$1" rel="$2" out="$3"
[[ "$rel" =~ ^[0-9]+$ ]] || die "release must be a number: $rel"
mkdir -p "$out"

listing() { curl -fsSL --retry 3 --max-time 120 "$1/" 2>/dev/null || true; }

case "$distro" in
fedora)
    # a release is under releases/ once it is out, under development/ before
    for tree in releases development; do
        base="https://download.fedoraproject.org/pub/fedora/linux/$tree/$rel/Cloud/x86_64/images"
        html="$(listing "$base")"
        name="$(grep -oE "Fedora-Cloud-Base-Generic-$rel-[0-9.]+\.x86_64\.qcow2" <<<"$html" | sort -uV | tail -n1 || true)"
        [ -n "$name" ] && break
    done
    [ -n "$name" ] || die "no Fedora $rel Generic cloud image found"
    version="${name#Fedora-Cloud-Base-Generic-"$rel"-}"
    version="${version%.x86_64.qcow2}"
    sums="$base/Fedora-Cloud-$rel-$version-x86_64-CHECKSUM"
    ;;
centos)
    base="https://cloud.centos.org/centos/$rel-stream/x86_64/images"
    html="$(listing "$base")"
    # the dated images, not the moving -latest link, so the version is known
    name="$(grep -oE "CentOS-Stream-GenericCloud-$rel-[0-9]{8}\.[0-9]+\.x86_64\.qcow2" <<<"$html" | sort -uV | tail -n1 || true)"
    [ -n "$name" ] || die "no CentOS Stream $rel GenericCloud image found"
    version="${name#CentOS-Stream-GenericCloud-"$rel"-}"
    version="${version%.x86_64.qcow2}"
    sums="$base/$name.SHA256SUM"
    ;;
*) die "unknown distro: $distro (fedora or centos)" ;;
esac

sum="$(curl -fsSL --retry 3 --max-time 120 "$sums" | sed -n "s/^SHA256 ($name) = //p")"
[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "no SHA-256 for $name in $sums"

file="$out/$name"
if [ -s "$file" ] && echo "$sum  $file" | sha256sum -c - >/dev/null 2>&1; then
    echo "have $name ($version)"
else
    echo "downloading $base/$name"
    curl -fsSL --retry 3 --max-time 3600 -o "$file.partial" "$base/$name"
    echo "$sum  $file.partial" | sha256sum -c - >/dev/null \
        || { rm -f "$file.partial"; die "checksum mismatch for $name"; }
    mv "$file.partial" "$file"
fi

cat > "$out/base.env" <<EOF
BASE_FILE='$file'
BASE_NAME='$name'
BASE_VERSION='$version'
BASE_URL='$base/$name'
BASE_SHA256='$sum'
EOF
echo "verified $name sha256 $sum"
