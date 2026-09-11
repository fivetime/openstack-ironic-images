#!/usr/bin/env bash
# Fetch what a layer's lock files name into the cache, verifying every file.
#
#   ci/fetch-layer.sh <layer> <kubernetes-version> [image ...]
#
# Three kinds of things, three places in the cache
# (upstream/cache/layers/<layer>/<version>/):
#
#   mirror/<path>   the artifacts, laid out exactly as upstream serves them
#                   so the installer finds them with NODE_BOOTSTRAP_MIRROR
#                   pointing at file://<this directory>
#   images/*.tar    the control-plane images as OCI archives, pulled by the
#                   locked digest and exported with ctr (containerd's own
#                   tool, which is also what imports them into the image)
#   packages/<image>/*.deb|rpm   distribution packages per base image,
#                   downloaded by URL (debian family) or copied out of the
#                   installer ISO already in the cache (redhat family)
#
# A cached file whose checksum matches is left alone. A mismatch is a
# failure, not a re-download: the lock is the contract.
#
# Environment: CACHE_DIR (default upstream/cache)

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/retry.sh
source "$LIB_DIR/retry.sh"

LAYER=${1:?usage: fetch-layer.sh <layer> <version> [image ...]}
VER=${2:?usage: fetch-layer.sh <layer> <version> [image ...]}
shift 2
IMAGES=("$@")
require_cmd curl sha256sum python3 tar

LAYER_DIR="$REPO_DIR/layers/$LAYER"
LOCK_DIR="$LAYER_DIR/lock/$VER"
[[ -d "$LOCK_DIR" ]] || die "no lock for $LAYER $VER: $LOCK_DIR (run layers/$LAYER/resolve.sh)"
CACHE_DIR=${CACHE_DIR:-$REPO_DIR/upstream/cache}
LC="$CACHE_DIR/layers/$LAYER/$VER"
mkdir -p "$LC/mirror" "$LC/images"

# rows <yaml> <python-expr yielding rows of "a|b|c"> - flatten a lock file
rows() {
    python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print("\n".join(eval(sys.argv[2])))' "$1" "$2"
}
checksum_ok() { [[ -f "$1" ]] && echo "$2  $1" | sha256sum -c --quiet - >/dev/null 2>&1; }
verify_or_die() {   # verify_or_die <file> <sha256> <what>
    if ! checksum_ok "$1" "$2"; then
        got=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
        rm -f "$1"
        die "$3: checksum mismatch (lock says $2, got ${got:-nothing}); upstream changed or download corrupt"
    fi
}

# ------------------------------------------------------------- the script
read -r surl ssha < <(rows "$LOCK_DIR/artifacts.yaml" '[d["script"]["url"]+" "+d["script"]["sha256"]]')
if checksum_ok "$LC/install.sh" "$ssha"; then
    log "== install.sh: cached and verified"
else
    log "== install.sh: fetching $surl"
    retry curl -fsSL -o "$LC/install.sh.part" "$surl"
    mv "$LC/install.sh.part" "$LC/install.sh"
    verify_or_die "$LC/install.sh" "$ssha" "install.sh"
fi

# ---------------------------------------------------------- the artifacts
n=0; fetched=0
while IFS='|' read -r path sha; do
    [[ -n "$path" ]] || continue
    n=$((n + 1))
    dest="$LC/mirror/$path"
    if checksum_ok "$dest" "$sha"; then continue; fi
    mkdir -p "$(dirname "$dest")"
    log "== fetching https://$path"
    retry curl -fL --retry 5 --retry-all-errors -sS -C - -o "$dest.part" "https://$path"
    mv "$dest.part" "$dest"
    verify_or_die "$dest" "$sha" "$path"
    fetched=$((fetched + 1))
done < <(rows "$LOCK_DIR/artifacts.yaml" '[a["path"]+"|"+a["sha256"] for a in d["artifacts"]]')
log "== artifacts: $n in the lock, $fetched fetched, the rest cached and verified"

# ------------------------------------------------------------- the images
#
# Pulled and exported by containerd's own tool, which is also what imports
# them into the image later. Not the host's containerd: the locked tarball
# is unpacked into a temporary directory and started as a plain process
# with its own root, so this works on a host that runs cri-o, docker, or
# nothing at all. ctr pulls by tag and reports the digest it resolved; the
# export is refused unless that digest is the locked one. The archive keeps
# the tag name, which is what the kubelet asks for - an archive of
# "name@sha256:..." alone would import as a nameless image and be pulled
# again. The digest the lock records is the index's, which is what the
# registry advertises for the tag and what the check above compares.
if [[ -f "$LOCK_DIR/images.yaml" ]]; then
    ni=0; pulled=0; ctrd=; ctrd_pid=
    stop_ctrd() { [[ -n "$ctrd_pid" ]] && { kill "$ctrd_pid" 2>/dev/null; wait "$ctrd_pid" 2>/dev/null; ctrd_pid=; }; [[ -n "$ctrd" ]] && rm -rf "$ctrd"; ctrd=; }
    trap stop_ctrd EXIT
    start_ctrd() {
        ctrd=$(mktemp -d)
        local tgz
        tgz=$(rows "$LOCK_DIR/artifacts.yaml" '[a["path"] for a in d["artifacts"] if "/containerd/containerd/" in a["path"] and a["path"].endswith(".tar.gz")]')
        tar -C "$ctrd" --strip-components=1 -xzf "$LC/mirror/$tgz" bin/containerd bin/ctr
        mkdir -p "$ctrd/root" "$ctrd/state"
        "$ctrd/containerd" --root "$ctrd/root" --state "$ctrd/state" --address "$ctrd/sock" \
            >"$ctrd/containerd.log" 2>&1 &
        ctrd_pid=$!
        for _ in $(seq 30); do [[ -S "$ctrd/sock" ]] && break; sleep 1; done
        [[ -S "$ctrd/sock" ]] || die "temporary containerd did not start; see $ctrd/containerd.log"
    }
    while IFS='|' read -r ref digest file lockm; do
        [[ -n "$ref" ]] || continue
        ni=$((ni + 1))
        marker="$LC/images/$file.digest"
        # Cached only if whole: an archive a previous run cut short (a
        # failed export, a killed run) is not "cached", it is the next
        # build's "unexpected EOF" at import time.
        if [[ -s "$LC/images/$file" && -f "$marker" && "$(cat "$marker")" == "$digest" ]] && tar -tf "$LC/images/$file" >/dev/null 2>&1; then continue; fi
        rm -f "$LC/images/$file" "$marker"
        [[ -n "$ctrd_pid" ]] || start_ctrd
        c="$ctrd/ctr --address $ctrd/sock -n k8s.io"
        log "== pulling $ref ($digest)"
        $c images pull --platform linux/amd64 "$ref" >/dev/null
        got=$($c images ls "name==$ref" | awk 'NR==2{print $3}')
        [[ "$got" == "$digest" ]] || die "$ref resolved to $got, the tag moved; the lock says $digest"
        # The tag points at a multi-platform index whose other entries -
        # the other architectures and, on kube-* images, the provenance
        # attestations - were never pulled; exporting the index walks into
        # those and fails on the first missing blob. So the tag is moved onto
        # the one manifest that was pulled, and that is what is exported: a
        # single-platform archive carrying the tag name.
        mdigest=$($c content get "$digest" | python3 -c '
import sys, json
for m in json.load(sys.stdin).get("manifests", []):
    p = m.get("platform") or {}
    if p.get("os") == "linux" and p.get("architecture") == "amd64" and not (m.get("annotations") or {}).get("vnd.docker.reference.type"):
        print(m["digest"]); break')
        [[ "$mdigest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$ref: no linux/amd64 manifest in the index"
        [[ -z "$lockm" || "$lockm" == "$mdigest" ]] || die "$ref: linux/amd64 manifest is $mdigest, the lock says $lockm"
        $c images pull --platform linux/amd64 "${ref%%:*}@${mdigest}" >/dev/null
        $c images tag --force "${ref%%:*}@${mdigest}" "$ref" >/dev/null
        # ctr export has produced a truncated archive more than once here
        # (a tar that ends mid-entry, sizes a few hundred KB short); nothing
        # in its exit status says so. Check the tar and try again, up to
        # three times, before giving up.
        exported=
        for attempt in 1 2 3; do
            rm -f "$LC/images/$file.part"
            $c images export "$LC/images/$file.part" "$ref" >/dev/null
            if tar -tf "$LC/images/$file.part" >/dev/null 2>&1; then exported=1; break; fi
            log "   attempt $attempt: exported archive for $ref is truncated ($(stat -c %s "$LC/images/$file.part") bytes); retrying"
            sleep 2
        done
        [[ -n "$exported" ]] || die "$ref: the exported archive is not a complete tar after 3 attempts"
        mv "$LC/images/$file.part" "$LC/images/$file"
        echo "$digest" > "$marker"
        pulled=$((pulled + 1))
    done < <(rows "$LOCK_DIR/images.yaml" '[i["ref"]+"|"+i["digest"]+"|"+i["file"]+"|"+i.get("manifest_digest","") for i in d["images"]]')
    stop_ctrd
    log "== images: $ni in the lock, $pulled pulled, the rest cached"
fi

# ----------------------------------------------------------- the packages
for image in "${IMAGES[@]}"; do
    lock="$LOCK_DIR/packages-$image.yaml"
    [[ -f "$lock" ]] || die "no package lock for $image: $lock (run layers/$LAYER/resolve-packages.sh)"
    dir="$LC/packages/$image"; mkdir -p "$dir"
    np=0; got=0; iso_mnt=
    while IFS='|' read -r file sha url iso path; do
        [[ -n "$file" ]] || continue
        np=$((np + 1))
        dest="$dir/$file"
        if checksum_ok "$dest" "$sha"; then continue; fi
        if [[ -n "$url" ]]; then
            log "== $image: fetching $url"
            retry curl -fL --retry 5 --retry-all-errors -sS -o "$dest.part" "$url"
        else
            if [[ -z "$iso_mnt" ]]; then
                [[ -f "$CACHE_DIR/$iso.iso" ]] || die "$image: packages come from $iso, which is not in the cache"
                iso_mnt=$(mktemp -d); mount -o loop,ro "$CACHE_DIR/$iso.iso" "$iso_mnt"
            fi
            cp "$iso_mnt/$path" "$dest.part"
        fi
        mv "$dest.part" "$dest"
        verify_or_die "$dest" "$sha" "$image/$file"
        got=$((got + 1))
    done < <(rows "$lock" '[p["file"]+"|"+p["sha256"]+"|"+p.get("url","")+"|"+p.get("iso","")+"|"+p.get("path","") for p in d["packages"]]')
    [[ -n "$iso_mnt" ]] && { umount "$iso_mnt"; rmdir "$iso_mnt"; }
    log "== packages for $image: $np in the lock, $got fetched, the rest cached and verified"
done
log "layer $LAYER $VER is in $LC"
