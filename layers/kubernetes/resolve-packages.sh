#!/usr/bin/env bash
# Resolve the layer's distribution packages for one base image into a lock.
#
#   layers/kubernetes/resolve-packages.sh <kubernetes-version> <image>
#
# The package names are in layer.yaml per family; which archive serves them,
# at which version, with which dependencies, is a property of the base image
# - so this asks the base image itself. It attaches a throwaway overlay of
# dist/<image>.raw, enters it, and:
#
#   debian family  apt-get --print-uris: the archive's URL, size and sha256
#                  for every package that would be installed, dependencies
#                  included, without installing anything
#   redhat family  dnf download --resolve against the installer DVD only
#                  (bind-mounted as the sole repository): every RPM comes
#                  from the ISO already in the cache, so the lock records
#                  the path inside the ISO, never a URL
#
# Writes lock/<k8s>/packages-<image>.yaml. Needs root, the base image built,
# and - for the debian family - network from this host.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source=../../lib/disk.sh
source "$LIB_DIR/disk.sh"
# shellcheck source=../../lib/overlay.sh
source "$LIB_DIR/overlay.sh"

K8S=${1:?usage: resolve-packages.sh <kubernetes-version> <image>}
IMAGE=${2:?usage: resolve-packages.sh <kubernetes-version> <image>}
require_root
require_cmd python3 sha256sum blkid

LAYER_DIR=$SCRIPT_DIR
LOCK_DIR="$LAYER_DIR/lock/$K8S"
OUTPUT_DIR=${OUTPUT_DIR:-$REPO_DIR/dist}
CACHE_DIR=${CACHE_DIR:-$REPO_DIR/upstream/cache}
RAW="$OUTPUT_DIR/$IMAGE.raw"
DECL="$REPO_DIR/images/$IMAGE/image.yaml"
[[ -f "$RAW" ]] || die "base image not built: $RAW"
[[ -f "$DECL" ]] || die "no such image declaration: $DECL"
[[ -d "$LOCK_DIR" ]] || die "no lock for Kubernetes $K8S; run resolve.sh first"
OUT="$LOCK_DIR/packages-$IMAGE.yaml"

yq() { python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(eval("d"+sys.argv[2]))' "$@"; }
SOURCE_ISO=$(yq "$DECL" '["source"]["iso"]')

install_cleanup_traps
make_work_dir work
# shellcheck disable=SC2154  # work and nbd are set through namerefs
overlay_attach nbd "$RAW" "$work/overlay.qcow2" "$work/root"
root=$(disk_find_root_partition "$nbd" "$work/root") || die "no root filesystem in $RAW"
log "== $IMAGE: root $root on an overlay of $RAW"
chroot_prepare "$work/root"

family=
if [[ -x "$work/root/usr/bin/apt-get" ]]; then family=debian
elif [[ -x "$work/root/usr/bin/dnf" ]]; then family=redhat
else die "$IMAGE: neither apt-get nor dnf in the image"; fi
pkgs=$(yq "$LAYER_DIR/layer.yaml" "[\"packages\"][\"$family\"]")
log "   family $family: $pkgs"

rows=()   # "file|sha256|size|source"
case "$family" in
debian)
    # --print-uris lists what apt would download, one line per file:
    #   'URL' filename size ALGO:hex
    # A package already installed in the image is not listed, which is
    # exactly right: it needs no file. The hash apt prints is whichever
    # one the archive index led with (SHA512 on current Ubuntu), so the
    # file is fetched here, checked against that, and the lock records
    # its sha256 - resolving means fetching once and writing down what
    # came back, same as the artifacts.
    chroot "$work/root" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    pdir="$CACHE_DIR/layers/kubernetes/$K8S/packages/$IMAGE"; mkdir -p "$pdir"
    # shellcheck disable=SC2086
    while read -r url file size sum; do
        [[ "$url" == \'*\' ]] || continue
        url=${url#\'}; url=${url%\'}
        algo=${sum%%:*}; hex=${sum#*:}
        case "$algo" in
            SHA256) tool=sha256sum ;; SHA512) tool=sha512sum ;; MD5Sum) tool=md5sum ;;
            *) die "apt reported an unknown hash for $file: $sum" ;;
        esac
        log "   $file"
        curl -fsSL --retry 5 -o "$pdir/$file.part" "$url"
        echo "$hex  $pdir/$file.part" | $tool -c --quiet - || die "$file: does not match the hash apt reported"
        mv "$pdir/$file.part" "$pdir/$file"
        rows+=("$file|$(sha256sum "$pdir/$file" | cut -d' ' -f1)|$size|$url")
    done < <(chroot "$work/root" env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends --print-uris $pkgs | grep "^'")
    ;;
redhat)
    ISO="$CACHE_DIR/$SOURCE_ISO.iso"
    [[ -f "$ISO" ]] || die "installer ISO not in the cache: $ISO (ci/fetch-upstream.sh $SOURCE_ISO)"
    mkdir -p "$work/iso" "$work/root/run/dvd"
    mount -o loop,ro "$ISO" "$work/iso"; on_cleanup "umount '$work/iso' 2>/dev/null || true"
    mount --bind "$work/iso" "$work/root/run/dvd"; on_cleanup "umount -l '$work/root/run/dvd' 2>/dev/null || true"
    mkdir -p "$work/root/tmp/pkgs"
    # shellcheck disable=SC2086
    chroot "$work/root" dnf -q --disablerepo='*' \
        --repofrompath=dvd-baseos,/run/dvd/BaseOS --repofrompath=dvd-appstream,/run/dvd/AppStream \
        --setopt=dvd-baseos.gpgcheck=0 --setopt=dvd-appstream.gpgcheck=0 \
        download --resolve --destdir /tmp/pkgs $pkgs
    for f in "$work/root"/tmp/pkgs/*.rpm; do
        [[ -e "$f" ]] || break
        name=$(basename "$f")
        inside=$(cd "$work/iso" && find BaseOS AppStream -name "$name" -print -quit)
        [[ -n "$inside" ]] || die "$name came from dnf but is not on the ISO"
        rows+=("$name|$(sha256sum "$f" | cut -d' ' -f1)|$(stat -c %s "$f")|iso:$SOURCE_ISO:$inside")
    done
    rm -rf "$work/root/tmp/pkgs"
    ;;
esac
((${#rows[@]})) || log "   nothing to fetch: the image already carries every package"

python3 - "$OUT" "$K8S" "$IMAGE" "$family" "$pkgs" "${rows[@]}" <<'PY'
import sys, yaml, datetime
out, k8s, image, family, pkgs, *rows = sys.argv[1:]
doc = {"layer": "kubernetes", "kubernetes": k8s, "image": image, "family": family,
       "requested": pkgs.split(),
       "resolved_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "packages": []}
for r in rows:
    f, s, n, src = r.split("|", 3)
    e = {"file": f, "sha256": s, "size": int(n)}
    if src.startswith("iso:"):
        _, iso, path = src.split(":", 2); e["iso"] = iso; e["path"] = path
    else:
        e["url"] = src
    doc["packages"].append(e)
with open(out, "w") as fh:
    fh.write("# Generated by layers/kubernetes/resolve-packages.sh - do not edit by hand.\n")
    yaml.safe_dump(doc, fh, sort_keys=False, width=120)
print(f"wrote {out}: {len(doc['packages'])} package file(s)")
PY
