#!/usr/bin/env bash
# Verify the Kubernetes layer in a mounted image, offline, by reading it.
#
#   layers/kubernetes/verify.sh <rootfs> <kubernetes-version>
#
# Prints one verdict line per check, "ok" or "FAIL", and exits with the
# number of failures - the distro-iso pipeline adds that to its own count.
# Every value is read back from the image (a binary's own --version, the
# containerd config as containerd itself renders it, the content store's
# blobs) and compared with the lock; nothing is taken from the variables
# the layer was applied with. Emits, on stdout under a "manifest:" line,
# the JSON the pipeline merges into the manifest - so the manifest says
# what is in the image, not what was asked for.
#
# The binaries are run through chroot, which works on a read-only mount.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=${1:?usage: verify.sh <rootfs> <kubernetes-version>}
K8S=${2:?usage: verify.sh <rootfs> <kubernetes-version>}
LOCK_DIR="$SCRIPT_DIR/lock/$K8S"
[[ -d "$LOCK_DIR" ]] || { echo "FAIL no lock for $K8S" >&2; exit 1; }

# yq <file> <python expression over d>
yq() { python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$@"; }
in_img() { chroot "$ROOT" "$@" 2>/dev/null; }

# Some of the binaries asked for their version want /proc (crun re-executes
# itself through a memfd, runsc reads /proc/sys); a bind of the host's is
# enough and works on a read-only root. Gone again when this script exits.
if ! mountpoint -q "$ROOT/proc"; then
    mount --bind /proc "$ROOT/proc"
    trap 'umount -l "$ROOT/proc" 2>/dev/null || true' EXIT
fi

failed=0
chk() {   # chk <title> <consequence> <command...>
    local title=$1 why=$2; shift 2
    if "$@"; then printf '   ok   %s\n' "$title" >&2
    else printf '   FAIL %s -- %s\n' "$title" "$why" >&2; failed=$((failed + 1)); fi
}

want() { yq "$LOCK_DIR/artifacts.yaml" "d['components']['$1']"; }
CONTAINERD=$(want CONTAINERD_VERSION); RUNC=$(want RUNC_VERSION); CRUN=$(want CRUN_VERSION)
GVISOR=$(want GVISOR_RELEASE); KATA=$(want KATA_VERSION); CRI=$(want CRI_TOOLS_VERSION)
PLATFORM=$(yq "$SCRIPT_DIR/layer.yaml" 'd["gvisor_platform"]')
RUNTIMES=$(yq "$SCRIPT_DIR/layer.yaml" 'd["runtimes"]')

# 1 The three Kubernetes binaries, at the locked version, by their own word.
k8s_bins() {
    local v
    v=$(in_img /usr/bin/kubeadm version -o short);                 [[ "$v" == "v${K8S}" ]] || { echo "      kubeadm: $v" >&2; return 1; }
    v=$(in_img /usr/bin/kubelet --version | awk '{print $2}');      [[ "$v" == "v${K8S}" ]] || { echo "      kubelet: $v" >&2; return 1; }
    v=$(in_img /usr/bin/kubectl version --client | awk '/^Client Version:/{print $3}'); [[ "$v" == "v${K8S}" ]] || { echo "      kubectl: $v" >&2; return 1; }
}
chk "kubeadm/kubelet/kubectl are v${K8S}" "kubeadm would install a different version than the image name says" k8s_bins

# 2 containerd, runc, crun at the locked versions.
runtime_bins() {
    local v
    v=$(in_img /usr/bin/containerd --version | awk '{print $3}'); [[ "$v" == "v${CONTAINERD}" ]] || { echo "      containerd: $v" >&2; return 1; }
    v=$(in_img /usr/bin/runc --version | awk 'NR==1{print $3}');  [[ "$v" == "${RUNC}" ]]      || { echo "      runc: $v" >&2; return 1; }
    v=$(in_img /usr/bin/crun --version | awk 'NR==1{print $3}');  [[ "$v" == "${CRUN}" ]]      || { echo "      crun: $v" >&2; return 1; }
    v=$(in_img /usr/bin/crictl --version | awk '{print $3}');     [[ "$v" == "v${CRI}" ]]      || { echo "      crictl: $v" >&2; return 1; }
}
chk "containerd ${CONTAINERD}, runc ${RUNC}, crun ${CRUN}, crictl ${CRI}" "not the runtime stack the lock describes" runtime_bins

# 3 The handlers, as containerd itself assembles them from config.toml and
#   the drop-ins - a drop-in with a typo is silently ignored otherwise.
handlers=$(in_img /usr/bin/containerd --config /etc/containerd/config.toml config dump | sed -n 's|.*containerd\.runtimes\.\([a-z0-9-]*\)\]$|\1|p' | sort -u | tr '\n' ' ')
handlers_ok() {
    local h
    [[ " $handlers " == *" runc "* ]] || return 1
    [[ " $RUNTIMES " == *" gvisor "* ]] && { [[ " $handlers " == *" gvisor "* ]] || return 1; }
    [[ " $RUNTIMES " == *" kata "* ]] && { for h in kata-qemu kata-clh kata-qemu-runtime-rs kata-clh-runtime-rs kata-dragonball; do [[ " $handlers " == *" $h "* ]] || return 1; done; }
    return 0
}
chk "containerd handlers: ${handlers}" "a RuntimeClass the driver creates would admit pods this node cannot run" handlers_ok

# 4 crun is what the default handler executes, not merely present.
chk "default handler executes crun" "runc runs while the manifest says crun" \
    grep -q 'BinaryName = "/usr/bin/crun"' "$ROOT/etc/containerd/conf.d/50-crun.toml"

# 5 gVisor: the binaries and the platform the layer declares.
gvisor_ok() {
    [[ -x "$ROOT/usr/bin/runsc" && -x "$ROOT/usr/bin/containerd-shim-runsc-v1" ]] || return 1
    in_img /usr/bin/runsc --version | grep -q "release-${GVISOR}" || { echo "      runsc: $(in_img /usr/bin/runsc --version | head -1)" >&2; return 1; }
    grep -q "^platform = \"${PLATFORM}\"" "$ROOT/etc/containerd/runsc.toml"
}
[[ " $RUNTIMES " == *" gvisor "* ]] && chk "gvisor ${GVISOR} on the ${PLATFORM} platform" "sandbox pods fail or run on the wrong platform" gvisor_ok

# 6 Kata: both shims, and the tarballs installed are the locked ones.
kata_ok() {
    [[ -x "$ROOT/opt/kata/bin/containerd-shim-kata-v2" && -x "$ROOT/opt/kata/runtime-rs/bin/containerd-shim-kata-v2" ]] || return 1
    local t sha
    for t in "kata-static-${KATA}-amd64.tar.zst" "kata-go-static-${KATA}-amd64.tar.zst"; do
        sha=$(yq "$LOCK_DIR/artifacts.yaml" "[a['sha256'] for a in d['artifacts'] if a['path'].endswith('/$t')][0]")
        grep -q "^${sha}  " "$ROOT/etc/kata-static.sha256" || { echo "      $t: installed tarball is not the locked one" >&2; return 1; }
    done
    grep -qE '^[^#]*[[:space:]]/dev/shm[[:space:]].*size=75%' "$ROOT/etc/fstab" || { echo "      /dev/shm not sized in fstab" >&2; return 1; }
    [[ -L "$ROOT/etc/systemd/system/sysinit.target.wants/kata-shm-private.service" ]]
}
[[ " $RUNTIMES " == *" kata "* ]] && chk "kata ${KATA}: both shims, locked tarballs, /dev/shm sized and private" "every kata-qemu sandbox fails at start" kata_ok

# 7 Control-plane images in the content store, by the locked linux/amd64
#   manifest digests - that is what the archive carried and what containerd
#   stored; the tag's index digest never enters the image.
images_ok() {
    local blobs="$ROOT/var/lib/containerd/io.containerd.content.v1.content/blobs/sha256" d missing=0
    while read -r d; do
        [[ -s "$blobs/${d#sha256:}" ]] || { echo "      missing $d" >&2; missing=$((missing + 1)); }
    done < <(yq "$LOCK_DIR/images.yaml" "chr(10).join(i.get('manifest_digest', i['digest']) for i in d['images'])")
    ((missing == 0))
}
chk "control-plane images preloaded ($(yq "$LOCK_DIR/images.yaml" 'len(d["images"])') by digest)" "kubeadm pulls at first boot, which a node without egress cannot" images_ok
IMAGES_PRELOADED=$([[ $failed == 0 ]] && images_ok >/dev/null 2>&1 && echo true || echo false)

# 8 Units enabled - the symlinks, since nothing is running.
units_ok() {
    [[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/containerd.service" ]] &&
    [[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/kubelet.service" ]] &&
    [[ -f "$ROOT/etc/systemd/system/kubelet.service.d/10-kubeadm.conf" ]]
}
chk "containerd and kubelet enabled" "nothing starts the CRI at boot" units_ok

# 9 Kernel settings persisted for first boot.
sysctl_ok() {
    grep -q '^br_netfilter' "$ROOT/etc/modules-load.d/99-kubernetes.conf" &&
    grep -q '^net.ipv4.ip_forward = 1' "$ROOT/etc/sysctl.d/99-kubelet.conf" &&
    [[ -d "$ROOT/opt/cni/bin" ]] && [[ -x "$ROOT/opt/cni/bin/bridge" ]]
}
chk "modules-load, sysctl and CNI plugins in place" "kubeadm preflight fails on ip_forward or bridge-nf" sysctl_ok

# 10 The distribution packages the preflight insists on.
pkgs_ok() { [[ -x "$ROOT/usr/sbin/conntrack" || -x "$ROOT/usr/bin/conntrack" ]] && [[ -x "$ROOT/usr/bin/socat" ]] && [[ -x "$ROOT/usr/sbin/ethtool" || -x "$ROOT/usr/bin/ethtool" ]]; }
chk "conntrack, socat, ethtool installed" "kubeadm preflight refuses to run" pkgs_ok

# 11 Nothing of the build left behind in the image.
leftovers_ok() { [[ ! -e "$ROOT/run/layer" && ! -e "$ROOT/tmp/containerd-import.log" && ! -e "$ROOT/run/containerd/containerd.sock" ]]; }
chk "no build leftovers (/run/layer, import log, stale socket)" "the image carries the builder's state" leftovers_ok

# ------------------------------------------------------------- manifest
kata_handlers=$(sed -n 's|.*runtimes\.\(kata-[a-z0-9-]*\)\]$|\1|p' "$ROOT/etc/containerd/conf.d/50-kata.toml" 2>/dev/null | paste -sd, -)
runsc_v=$(in_img /usr/bin/runsc --version 2>/dev/null | awk 'NR==1{print $NF}')
echo "manifest: $(python3 -c "import json,sys; print(json.dumps({
  'k8s_version': sys.argv[1], 'containerd_version': sys.argv[2], 'runc_version': sys.argv[3], 'crun_version': sys.argv[4],
  'crictl_version': sys.argv[5], 'runsc_version': sys.argv[6], 'kata_version': sys.argv[7], 'kata_handlers': sys.argv[8],
  'gvisor_platform': sys.argv[9], 'images_preloaded': sys.argv[10] == 'true', 'layer': 'kubernetes',
  'layer_lock_resolved_at': sys.argv[11]}))" \
  "$K8S" "$(in_img /usr/bin/containerd --version | awk '{print $3}' | sed 's/^v//')" "$(in_img /usr/bin/runc --version | awk 'NR==1{print $3}')" \
  "$(in_img /usr/bin/crun --version | awk 'NR==1{print $3}')" "$(in_img /usr/bin/crictl --version | awk '{print $3}' | sed 's/^v//')" \
  "$runsc_v" "$KATA" "$kata_handlers" "$(sed -n 's/^platform = "\(.*\)"/\1/p' "$ROOT/etc/containerd/runsc.toml" 2>/dev/null)" \
  "$IMAGES_PRELOADED" "$(yq "$LOCK_DIR/artifacts.yaml" 'd["resolved_at"]')")"
exit "$failed"
