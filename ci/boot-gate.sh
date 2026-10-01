#!/usr/bin/env bash
# Boot a built Kubernetes-layer image and make it a node, before it is pushed.
#
#   ci/boot-gate.sh <image.raw> <kubernetes-version>
#
# The layer's verify.sh reads the image: versions, registered handlers, files
# in place. It cannot tell whether a handler starts a sandbox, and the runtimes
# come from upstream's newest release whenever a lock is resolved - a release
# whose runsc wants sidecars the image lacks, or whose kata cannot boot a
# guest here, registers fine and fails every pod. This boots the image under
# QEMU/OVMF, the way the installer step already runs it, and runs the test in
# ci/boot-gate.user-data: kubeadm init with imagePullPolicy Never, a pod under
# the default handler (which must be crun), then one pod per handler.
#
# The raw is not modified: the VM writes to a qcow2 overlay backed by it. The
# user-data arrives on a NoCloud seed (label cidata) - both images list
# NoCloud after ConfigDrive. The network is QEMU's user network with
# restrict=on: a default route for kubeadm, nothing reachable behind it.
#
# Exit status: 0 the image became a node and every handler ran a pod; 1 it did
# not. Both serial ports are captured (serial.log = ttyS0, serial1.log =
# ttyS1): an image's kernel console is its image.yaml serial_console, and the
# user-data writes to ttyS0 itself. They are left in $GATE_DIR for the
# workflow to upload.
#
# Environment: GATE_TIMEOUT (seconds, default 1800), GATE_MEM (MiB, default
# 8192), GATE_CPUS (default 4), GATE_DIR (default dist/gate-<image>),
# GATE_TOLERATE (space-separated handlers whose failure is reported but not
# fatal - see below; default none).

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RAW=${1:?usage: boot-gate.sh <image.raw> <kubernetes-version>}
K8S=${2:?usage: boot-gate.sh <image.raw> <kubernetes-version>}
[[ -f "$RAW" ]] || { echo "boot-gate: no such image: $RAW" >&2; exit 1; }
[[ "$K8S" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "boot-gate: not a Kubernetes version: $K8S" >&2; exit 1; }

GATE_TIMEOUT=${GATE_TIMEOUT:-1800}
GATE_MEM=${GATE_MEM:-8192}
GATE_CPUS=${GATE_CPUS:-4}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
name=$(basename "$RAW" .raw)
GATE_DIR=${GATE_DIR:-$(dirname "$RAW")/gate-$name}

log() { printf '[boot-gate] %s\n' "$*" >&2; }
for c in qemu-system-x86_64 qemu-img xorrisofs; do
    command -v "$c" >/dev/null || { log "missing $c"; exit 1; }
done
[[ -e /dev/kvm ]] || { log "/dev/kvm is missing"; exit 1; }

rm -rf "$GATE_DIR"; mkdir -p "$GATE_DIR/seed"
qemu_pid() { cat "$GATE_DIR/qemu.pid" 2>/dev/null; }
cleanup() {
    local pid; pid=$(qemu_pid || true)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$GATE_DIR/overlay.qcow2" "$GATE_DIR/OVMF_VARS.fd" "$GATE_DIR/seed.iso"
    rm -rf "$GATE_DIR/seed"
}
trap cleanup EXIT

qemu-img create -q -f qcow2 -F raw -b "$(realpath "$RAW")" "$GATE_DIR/overlay.qcow2"
cp "$OVMF_VARS" "$GATE_DIR/OVMF_VARS.fd"
sed "s/@K8S@/${K8S}/g" "$SCRIPT_DIR/boot-gate.user-data" > "$GATE_DIR/seed/user-data"
printf 'instance-id: boot-gate-%s\nlocal-hostname: boot-gate\n' "$(date +%s)" > "$GATE_DIR/seed/meta-data"
xorrisofs -quiet -o "$GATE_DIR/seed.iso" -V cidata -J -r "$GATE_DIR/seed"

log "booting $name (k8s $K8S, ${GATE_MEM} MiB, ${GATE_CPUS} vCPU), up to ${GATE_TIMEOUT}s"
qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m "$GATE_MEM" -smp "$GATE_CPUS" \
    -display none -vga std \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$GATE_DIR/OVMF_VARS.fd" \
    -drive if=none,id=d0,format=qcow2,file="$GATE_DIR/overlay.qcow2" -device virtio-blk-pci,drive=d0 \
    -drive if=none,id=seed,format=raw,readonly=on,file="$GATE_DIR/seed.iso" \
    -device ide-cd,drive=seed,bus=ide.0 \
    -netdev user,id=n0,restrict=on,ipv6=off -device virtio-net-pci,netdev=n0 \
    -serial "file:$GATE_DIR/serial.log" -serial "file:$GATE_DIR/serial1.log" \
    -pidfile "$GATE_DIR/qemu.pid" -daemonize

deadline=$((SECONDS + GATE_TIMEOUT)); result=
while ((SECONDS < deadline)); do
    # The user-data echoes the command itself under `set -x`; the verdict is
    # the line that does not start with the echo's quote.
    result=$(cat "$GATE_DIR/serial.log" "$GATE_DIR/serial1.log" 2>/dev/null | tr -d '\r' |
             grep -aoE 'GATE_RESULT status=(PASS|FAIL)[^'"'"']*$' | tail -1 || true)
    [[ -n "$result" ]] && break
    kill -0 "$(qemu_pid)" 2>/dev/null || { log "QEMU exited before a verdict"; break; }
    sleep 15
done

if [[ -z "$result" ]]; then
    log "no verdict within ${GATE_TIMEOUT}s; last serial lines:"
    for f in serial.log serial1.log; do echo "--- $f" >&2; tail -c 6000 "$GATE_DIR/$f" | tr -d '\r' | tail -40 >&2 || true; done
    exit 1
fi
log "$result"
if [[ "$result" != *status=PASS* ]]; then
    cat "$GATE_DIR/serial.log" "$GATE_DIR/serial1.log" 2>/dev/null | tr -d '\r' |
        sed -n '/=== GATE DIAGNOSTICS/,/=== END DIAGNOSTICS/p' | tail -120 >&2 || true
    exit 1
fi
reported=$(grep -o 'kubelet=[^ ]*' <<<"$result" | cut -d= -f2)
[[ "$reported" == "v${K8S}" ]] || { log "kubelet reports ${reported}, the image claims v${K8S}"; exit 1; }

# Every handler that did not start a pod fails the image, except those named
# in GATE_TOLERATE: handlers this runner cannot exercise at all. The runner is
# itself a VM, so a kata guest here sits three levels of virtualisation deep
# (host, runner, gate VM, guest), where a real node has it one level deep; a
# VMM that cannot start a guest at that depth says nothing about the image.
# Each tolerated failure is still named in the log and in result.txt.
failed=$(grep -o 'failed=[^ ]*' <<<"$result" | cut -d= -f2)
[[ "$failed" == none ]] && failed=
fatal=; tolerated=
for h in ${failed//,/ }; do
    if [[ " ${GATE_TOLERATE:-} " == *" $h "* ]]; then tolerated+=" $h"; else fatal+=" $h"; fi
done
printf '%s\n' "$result" "tolerated:${tolerated:- none}" "fatal:${fatal:- none}" > "$GATE_DIR/result.txt"
if [[ -n "$tolerated" ]]; then
    log "NOT EXERCISED here (GATE_TOLERATE):${tolerated} - a pod under these did not start on this runner"
fi
if [[ -n "$fatal" ]]; then
    cat "$GATE_DIR/serial.log" "$GATE_DIR/serial1.log" 2>/dev/null | tr -d '\r' |
        grep -a -A16 '=== HANDLER .* DID NOT START A POD ===' | tail -120 >&2 || true
    log "FAILED: no pod under${fatal}"
    exit 1
fi
log "passed"
