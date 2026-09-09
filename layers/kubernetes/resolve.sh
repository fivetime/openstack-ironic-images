#!/usr/bin/env bash
# Resolve the Kubernetes layer for one Kubernetes version into a lock file.
#
#   layers/kubernetes/resolve.sh <kubernetes-version>     e.g. 1.37.0
#
# Writes lock/<version>/artifacts.yaml and lock/<version>/images.yaml, and
# leaves every artifact in the cache (upstream/cache/layers/kubernetes/<ver>/)
# on the way - resolving means fetching once and writing down what came back.
#
# Component versions are the pinned installer script's own defaults, so the
# bare-metal image matches what a first-boot node installs; set
# CONTAINERD_VERSION, RUNC_VERSION, CRUN_VERSION, CNI_PLUGINS_VERSION,
# CRI_TOOLS_VERSION, GVISOR_RELEASE or KATA_VERSION to diverge on purpose.
#
# Checksums: where upstream publishes one (dl.k8s.io, containerd, runc,
# cni-plugins, cri-tools, gvisor) the download is verified against it and
# the lock records it; where upstream publishes none (crun, kata) the lock
# records the checksum of what was fetched today, which is the best that
# exists and still turns "the URL changed its bytes" into a build failure.
#
# Images: the control-plane images kubeadm would pull for this version, plus
# containerd's default sandbox image, pinned by manifest digest from the
# registry. The archives themselves are fetched by ci/fetch-layer.sh.
#
# Needs network. Runs on any Linux host with curl; the kubeadm and containerd
# binaries it downloads are run once to ask them for the image list.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source=../../lib/retry.sh
source "$LIB_DIR/retry.sh"

K8S=${1:?usage: resolve.sh <kubernetes-version>}
[[ "$K8S" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a Kubernetes version: $K8S"
require_cmd curl sha256sum sha512sum python3 jq

LAYER_DIR=$SCRIPT_DIR
LOCK_DIR="$LAYER_DIR/lock/$K8S"
CACHE_DIR=${CACHE_DIR:-$REPO_DIR/upstream/cache}
LAYER_CACHE="$CACHE_DIR/layers/kubernetes/$K8S"
MIRROR="$LAYER_CACHE/mirror"
ARCH=amd64
mkdir -p "$LOCK_DIR" "$MIRROR"

yq() { python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(eval("d"+sys.argv[2]))' "$@"; }

# ---------------------------------------------------------------- the script
SCRIPT_REPO=$(yq "$LAYER_DIR/layer.yaml" '["script"]["repo"]')
SCRIPT_PATH=$(yq "$LAYER_DIR/layer.yaml" '["script"]["path"]')
SCRIPT_TAG=$(yq "$LAYER_DIR/layer.yaml" '["script"]["tag"]')
SCRIPT_SHA=$(yq "$LAYER_DIR/layer.yaml" '["script"]["sha256"]')
SCRIPT_URL="https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_TAG}/${SCRIPT_PATH}"
SCRIPT="$LAYER_CACHE/install.sh"
log "== script: ${SCRIPT_REPO}@${SCRIPT_TAG} ${SCRIPT_PATH}"
retry curl -fsSL -o "$SCRIPT" "$SCRIPT_URL"
echo "$SCRIPT_SHA  $SCRIPT" | sha256sum -c --quiet - || die "install.sh at $SCRIPT_TAG does not match layer.yaml's sha256"

# default_of VAR -> the script's own default for VAR (the ${VAR:-x} form)
default_of() {
    sed -n "s/^${1}=\${${1}:-\([^}]*\)}.*/\1/p" "$SCRIPT" | head -1
}
CONTAINERD_VERSION=${CONTAINERD_VERSION:-$(default_of CONTAINERD_VERSION)}
RUNC_VERSION=${RUNC_VERSION:-$(default_of RUNC_VERSION)}
CRUN_VERSION=${CRUN_VERSION:-$(default_of CRUN_VERSION)}
CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION:-$(default_of CNI_PLUGINS_VERSION)}
CRI_TOOLS_VERSION=${CRI_TOOLS_VERSION:-${K8S%.*}.0}
GVISOR_RELEASE=${GVISOR_RELEASE:-$(default_of GVISOR_RELEASE)}
KATA_VERSION=${KATA_VERSION:-$(default_of KATA_VERSION)}
for v in CONTAINERD_VERSION RUNC_VERSION CRUN_VERSION CNI_PLUGINS_VERSION GVISOR_RELEASE KATA_VERSION; do
    [[ -n "${!v}" ]] || die "could not read the script's default for $v"
done
log "   containerd $CONTAINERD_VERSION runc $RUNC_VERSION crun $CRUN_VERSION cni $CNI_PLUGINS_VERSION cri-tools $CRI_TOOLS_VERSION gvisor $GVISOR_RELEASE kata $KATA_VERSION"

# -------------------------------------------------------------- the artifacts
#
# Every path is the upstream URL without its scheme, and the cache mirrors
# that layout, so the installer's own URL arithmetic finds the files when
# NODE_BOOTSTRAP_MIRROR points at the cache. The checksum files the installer
# reads are artifacts too.
ART=()   # "path|sha256|size|verified_by"
fetch_into_mirror() {
    local path=$1 dest="$MIRROR/$1"
    mkdir -p "$(dirname "$dest")"
    [[ -s "$dest" ]] || retry curl -fsSL --retry 5 -o "$dest.part" "https://$path" && { [[ -s "$dest" ]] || mv "$dest.part" "$dest"; }
}
record() {   # record <path> <verified_by>
    local path=$1 how=$2 f="$MIRROR/$1"
    ART+=("$path|$(sha256sum "$f" | cut -d' ' -f1)|$(stat -c %s "$f")|$how")
}
# add <path> [checksum-file-path] [sha256|sha512|sha256sum-list <name>]
# Fetches the artifact (and its upstream checksum file, when it has one),
# verifies, records both.
add() {
    local path=$1 sumpath=${2:-} kind=${3:-} name=${4:-}
    log "   $path"
    fetch_into_mirror "$path"
    if [[ -n "$sumpath" ]]; then
        fetch_into_mirror "$sumpath"
        local f="$MIRROR/$path" s="$MIRROR/$sumpath"
        case "$kind" in
            sha256)     echo "$(cut -d' ' -f1 "$s")  $f" | sha256sum -c --quiet - ;;
            sha512)     echo "$(cut -d' ' -f1 "$s")  $f" | sha512sum -c --quiet - ;;
            sha256sum-list) (cd "$(dirname "$f")" && grep " ${name}\$" "$s" | sha256sum -c --quiet -) ;;
            *) die "add: unknown checksum kind $kind" ;;
        esac || die "upstream checksum mismatch for $path"
        record "$path" "upstream:$sumpath"
        record "$sumpath" "checksum-file"
    else
        record "$path" "recorded-at-resolve"
    fi
}

log "== artifacts -> $MIRROR"
for b in kubeadm kubelet kubectl; do
    p="dl.k8s.io/release/v${K8S}/bin/linux/${ARCH}/${b}"
    add "$p" "$p.sha256" sha256
done
c="github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
add "$c" "$c.sha256sum" sha256sum-list "containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
r="github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc"
add "$r.${ARCH}" "$r.sha256sum" sha256sum-list "runc.${ARCH}"
add "github.com/containers/crun/releases/download/${CRUN_VERSION}/crun-${CRUN_VERSION}-linux-${ARCH}"
case "$ARCH" in amd64) GA=x86_64 ;; arm64) GA=aarch64 ;; esac
for f in runsc containerd-shim-runsc-v1; do
    p="storage.googleapis.com/gvisor/releases/release/${GVISOR_RELEASE}/${GA}/${f}"
    add "$p" "$p.sha512" sha512
done
for t in "kata-static-${KATA_VERSION}-${ARCH}.tar.zst" "kata-go-static-${KATA_VERSION}-${ARCH}.tar.zst"; do
    add "github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${t}"
done
n="github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-v${CNI_PLUGINS_VERSION}.tgz"
add "$n" "$n.sha256" sha256
k="github.com/kubernetes-sigs/cri-tools/releases/download/v${CRI_TOOLS_VERSION}/crictl-v${CRI_TOOLS_VERSION}-linux-${ARCH}.tar.gz"
add "$k" "$k.sha256" sha256

# ------------------------------------------------------------------ the images
#
# Ask the binaries themselves, not a table: kubeadm knows which images this
# version wants, containerd knows its sandbox image. Both were just fetched
# and verified. Digests come from the registry's manifest endpoint.
log "== images"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
install -m 755 "$MIRROR/dl.k8s.io/release/v${K8S}/bin/linux/${ARCH}/kubeadm" "$tmp/kubeadm"
tar -C "$tmp" --strip-components=1 -xzf "$MIRROR/$c" bin/containerd
# containerd 2.x writes `sandbox = 'ref'` (config version 3); 1.x wrote
# `sandbox_image = "ref"`. Accept either quote and either key.
pause=$("$tmp/containerd" config default | sed -nE "s/^\s*sandbox(_image)? = ['\"]([^'\"]+)['\"].*/\2/p" | head -1)
[[ -n "$pause" ]] || die "could not read the sandbox image from containerd's default config"
mapfile -t refs < <( { "$tmp/kubeadm" config images list --kubernetes-version "v${K8S}"; echo "$pause"; } | sort -u)
((${#refs[@]} >= 2)) || die "kubeadm listed no images for v${K8S}"
IMG=()   # "ref|digest"
for ref in "${refs[@]}"; do
    reg=${ref%%/*}; rest=${ref#*/}; repo=${rest%:*}; tag=${rest##*:}
    # registry.k8s.io answers every manifest request with a 307 to the
    # regional backend; the digest header is on the final answer.
    digest=$(curl -fsSIL -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://${reg}/v2/${repo}/manifests/${tag}" | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no digest for $ref"
    # The tag's digest is an index's on every image here. What actually gets
    # exported, imported and later looked for in the image's content store
    # is the one linux/amd64 manifest under it (never the provenance
    # attestation, which also claims that platform in its annotations).
    mdigest=$(curl -fsSL -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://${reg}/v2/${repo}/manifests/${tag}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
ms = d.get("manifests")
if ms is None:
    print(sys.argv[1]); sys.exit()
for m in ms:
    p = m.get("platform") or {}
    if p.get("os") == "linux" and p.get("architecture") == "amd64" and not (m.get("annotations") or {}).get("vnd.docker.reference.type"):
        print(m["digest"]); break' "$digest")
    [[ "$mdigest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no linux/amd64 manifest for $ref"
    log "   $ref@$digest (linux/amd64 manifest $mdigest)"
    IMG+=("$ref|$digest|$mdigest")
done

# ---------------------------------------------------------------------- write
python3 - "$LOCK_DIR" "$K8S" "$SCRIPT_URL" "$SCRIPT_TAG" "$SCRIPT_SHA" \
    "$CONTAINERD_VERSION" "$RUNC_VERSION" "$CRUN_VERSION" "$CNI_PLUGINS_VERSION" "$CRI_TOOLS_VERSION" "$GVISOR_RELEASE" "$KATA_VERSION" \
    "${#ART[@]}" "${ART[@]}" "${IMG[@]}" <<'PY'
import sys, yaml, datetime
a = sys.argv[1:]
lock_dir, k8s, url, tag, sha = a[:5]
cd, runc, crun, cni, cri, gv, kata = a[5:12]
n = int(a[12]); arts = a[13:13+n]; imgs = a[13+n:]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
hdr = ("# Generated by layers/kubernetes/resolve.sh - do not edit by hand.\n"
       "# The build reads this file only; regenerate to move a version.\n")
artifacts = {
    "layer": "kubernetes", "kubernetes": k8s, "arch": "amd64", "resolved_at": now,
    "script": {"url": url, "tag": tag, "sha256": sha},
    "components": {"CONTAINERD_VERSION": cd, "RUNC_VERSION": runc, "CRUN_VERSION": crun,
                   "CNI_PLUGINS_VERSION": cni, "CRI_TOOLS_VERSION": cri,
                   "GVISOR_RELEASE": gv, "KATA_VERSION": kata},
    "artifacts": [dict(zip(("path", "sha256", "size", "verified_by"), x.split("|")))
                  for x in arts],
}
for e in artifacts["artifacts"]:
    e["size"] = int(e["size"])
with open(f"{lock_dir}/artifacts.yaml", "w") as fh:
    fh.write(hdr); yaml.safe_dump(artifacts, fh, sort_keys=False, width=120)
images = {"layer": "kubernetes", "kubernetes": k8s, "resolved_at": now,
          "images": [{"ref": r, "digest": d, "manifest_digest": m,
                      "file": r.split("/")[-1].replace(":", "-") + ".tar"}
                     for r, d, m in (x.split("|") for x in imgs)]}
with open(f"{lock_dir}/images.yaml", "w") as fh:
    fh.write(hdr); yaml.safe_dump(images, fh, sort_keys=False, width=120)
print(f"wrote {lock_dir}/artifacts.yaml ({n} artifacts) and images.yaml ({len(imgs)} images)")
PY
