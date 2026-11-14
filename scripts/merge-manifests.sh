#!/bin/bash
# Merge the per-arch image tags into one multi-arch manifest list per name.
#
# Usage: merge-manifests.sh [REGISTRY]
#   REGISTRY   ghcr.io (default; needs GH_TOKEN, logs in) or a local one
#              for trying the script out (plain HTTP: --tls-verify=false)
#
# Environment:
#   MATRIX   the image matrix as JSON (scripts/matrix.py output)
#   REPO     the repository; the image names live under REGISTRY/REPO
#
# For every image name in the matrix the dated per-arch tags this run
# published (<name>:<date>-<arch>) become the members of <name>:latest and
# <name>:<date>. An arch that was not published this run keeps its previous
# member of <name>:latest, by digest, so a failing arch never drops another
# arch from `latest`.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[ -n "${MATRIX:-}" ] || die "MATRIX (the matrix JSON) is not set"
registry="${1:-ghcr.io}"
repo="$(echo "${REPO:-${GITHUB_REPOSITORY:-}}" | tr '[:upper:]' '[:lower:]')"
[ -n "$repo" ] || die "REPO (the repository) is not set"
today="$(date -u +%Y%m%d)"

tls=()           # podman
tls_skopeo=()    # skopeo
if [ "$registry" = ghcr.io ]; then
    [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN (a token with packages: write) is not set"
    echo "$GH_TOKEN" | podman login ghcr.io -u "${GITHUB_ACTOR:-}" --password-stdin
else
    tls=(--tls-verify=false)
    tls_skopeo=(--tls-verify=false)
fi

# the matrix arch (x86_64/aarch64) vs the manifest member architecture
# (amd64/arm64)
goarch() {
    case "$1" in
        x86_64) echo amd64 ;;
        aarch64) echo arm64 ;;
        *) die "unknown arch: $1" ;;
    esac
}

# the digest of the linux/<arch> member of a manifest list, if it has one
member_digest() {   # LIST ARCH
    podman manifest inspect "${tls[@]}" "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    index = json.load(sys.stdin)
except ValueError:
    sys.exit(0)                 # not a JSON manifest list: no member
for m in index.get("manifests") or []:
    p = m.get("platform") or {}
    if p.get("os") == "linux" and p.get("architecture") == sys.argv[1]:
        print(m["digest"])
        break
' "$(goarch "$2")"
}

names() { python3 -c '
import json, sys
for j in json.loads(sys.argv[1])["include"]:
    print(j["name"])
' "$MATRIX" | sort -u; }

arches_of() { python3 -c '
import json, sys
for j in json.loads(sys.argv[1])["include"]:
    if j["name"] == sys.argv[2]:
        print(j["arch"])
' "$MATRIX" "$1"; }

while IFS= read -r name; do
    list="$registry/$repo/$name"
    echo "==> $name"
    members=()
    for arch in $(arches_of "$name"); do
        tag="$list:$today-$arch"
        # the probe also verifies the tag is pullable (a truncated push is
        # not merged); skopeo, because podman's manifest commands refuse a
        # single-arch manifest under a manifest subcommand
        if skopeo inspect --raw "${tls_skopeo[@]}" "docker://$tag" >/dev/null 2>&1; then
            echo "    $arch: $tag (published this run)"
            members+=("$tag")
            continue
        fi
        prev="$(member_digest "$list:latest" "$arch" || true)"
        if [ -n "$prev" ]; then
            echo "    $arch: kept $prev from the previous latest"
            members+=("$list@$prev")
        else
            echo "    $arch: not published (nothing to keep)"
        fi
    done
    if [ "${#members[@]}" -lt 1 ]; then
        echo "    no members; skipped"
        continue
    fi
    podman manifest rm "$list:latest" >/dev/null 2>&1 || true
    podman manifest create "$list:latest" >/dev/null
    for m in "${members[@]}"; do
        podman manifest add "${tls[@]}" "$list:latest" "$m" >/dev/null
    done
    podman manifest push "${tls[@]}" "$list:latest" >/dev/null
    podman manifest push "${tls[@]}" "$list:latest" "$list:$today" >/dev/null
    echo "    pushed $list:latest and $list:$today (${#members[@]} member(s))"
done < <(names)
