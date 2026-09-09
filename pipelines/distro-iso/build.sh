#!/usr/bin/env bash
# Install a distro from its official installer ISO, unattended, and turn
# the result into a bare-metal image.
#
# Why an installer and not a cloud image: the VM pipelines in
# openstack-cloud-images build from images.linuxcontainers.org, and those
# disks are built for machines nobody can walk up to. Measured on the upstream Ubuntu 26.04 cloud disk:
# no account has a password, there is no serial console, GRUB_TIMEOUT=0
# with a hidden menu, "quiet splash", /usr/lib/firmware holds 16 KB, and
# the initramfs contains no SCSI HBA driver at all (virtio is built into
# the kernel, so a VM never notices). A machine in a rack recovers through
# a monitor, a keyboard and the BMC's serial console; every one of those
# defaults removes one of them.
#
# Stages:
#   seed      render the answer file, build the CIDATA CD the installer reads
#   install   QEMU/OVMF boots the ISO with that CD and a blank disk; the
#             installer powers the machine off when it is done, and the
#             QEMU process exiting is the signal
#   layer     (with LAYER_KUBERNETES) copy the base disk and write the
#             Kubernetes node stack into it from the layer's cache, in a
#             chroot with no network - see layers/kubernetes/
#   verify    mount the result and check the console contract, the
#             initramfs and the firmware - the three things that are
#             invisible on a VM and fatal on hardware; with a layer, its
#             own checks follow
#   manifest
#
# INSTALL_ONLY=1 stops after the install (no verify), VERIFY_ONLY=1 runs
# verify + manifest against the disk already in OUTPUT_DIR. With a layer,
# a base disk already in OUTPUT_DIR is reused rather than reinstalled.
#
# Must run as root (loop mounts) on a host with /dev/kvm.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source=../../lib/disk.sh
source "$LIB_DIR/disk.sh"
# shellcheck source=../../lib/manifest.sh
source "$LIB_DIR/manifest.sh"

IMAGE_NAME=${IMAGE_NAME:?Set IMAGE_NAME}
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-$IMAGE_NAME}
LAYER_KUBERNETES=${LAYER_KUBERNETES:-}
IMAGE_DIR=${IMAGE_DIR:?Set IMAGE_DIR (the images/<name> directory)}
OUTPUT_DIR=${OUTPUT_DIR:?Set OUTPUT_DIR for the build artifacts}
INSTALLER=${INSTALLER:-subiquity}
SOURCE_ISO=${SOURCE_ISO:?Set SOURCE_ISO (an artifact name from upstream/sources.yaml)}
DISK_SIZE=${DISK_SIZE:-12G}
OUTPUT_FORMAT=${OUTPUT_FORMAT:-raw}
ADMIN_USER=${ADMIN_USER:-sysadmin}
SERIAL_CONSOLE=${SERIAL_CONSOLE:-ttyS1}
CACHE_DIR=${CACHE_DIR:-$REPO_DIR/upstream/cache}
ISO=${ISO:-$CACHE_DIR/$SOURCE_ISO.iso}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-5400}
# The installer writes to the serial log continuously; a log that has not
# grown in this long is a hung install, not a slow one.
INSTALL_STALL=${INSTALL_STALL:-1200}
VM_MEM=${VM_MEM:-4096}
VM_CPUS=${VM_CPUS:-4}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
KEEP_VM_ON_FAILURE=${KEEP_VM_ON_FAILURE:-}
INSTALL_ONLY=${INSTALL_ONLY:-}
VERIFY_ONLY=${VERIFY_ONLY:-}
# The local login. This is the whole point of the image: the account that
# works when cloud-init did not run, typed on a keyboard plugged into the
# machine. It never appears in the log or the manifest and does not live
# in the repository - CI passes it from a secret.
BAREMETAL_ADMIN_PASSWORD=${BAREMETAL_ADMIN_PASSWORD:?Set BAREMETAL_ADMIN_PASSWORD (the local console password; a CI secret)}

case "$INSTALLER" in
    subiquity|kickstart) ;;
    *) die "unknown installer: $INSTALLER" ;;
esac

require_cmd qemu-system-x86_64 qemu-img socat jq python3 openssl
require_root
[[ -e /dev/kvm ]] || die "/dev/kvm is required for the install stage"
[[ -f "$OVMF_CODE" && -f "$OVMF_VARS" ]] || die "OVMF firmware not found ($OVMF_CODE / $OVMF_VARS)"
[[ -f "$ISO" ]] || die "missing upstream artifact: $ISO (ci/fetch-upstream.sh $SOURCE_ISO)"
if command -v xorrisofs >/dev/null; then MKISO=(xorrisofs)
elif command -v genisoimage >/dev/null; then MKISO=(genisoimage)
else die "need xorrisofs or genisoimage to build the answer-file CD"; fi
install_cleanup_traps

mkdir -p "$OUTPUT_DIR"
make_work_dir work_dir
raw="$OUTPUT_DIR/$IMAGE_NAME.raw"
logs="$OUTPUT_DIR/$IMAGE_NAME.install"
mnt="$work_dir/mnt"
# With a layer the installer produces the base image under its own name;
# the layer stage copies it and works on the copy. The base is a product
# in its own right (the plain bare-metal image) and is kept.
base_raw="$OUTPUT_DIR/$BASE_IMAGE_NAME.raw"
base_logs="$OUTPUT_DIR/$BASE_IMAGE_NAME.install"
if [[ -n "$LAYER_KUBERNETES" ]]; then
    LAYER_DIR="$REPO_DIR/layers/kubernetes"
    LAYER_LOCK="$LAYER_DIR/lock/$LAYER_KUBERNETES"
    LAYER_CACHE="$CACHE_DIR/layers/kubernetes/$LAYER_KUBERNETES"
    [[ -d "$LAYER_LOCK" ]] || die "no lock for Kubernetes $LAYER_KUBERNETES"
fi

# The serial unit number grub wants is the digit in the tty name.
serial_unit=${SERIAL_CONSOLE##*S}
[[ "$serial_unit" =~ ^[0-9]+$ ]] || die "SERIAL_CONSOLE must look like ttyS<n>, got $SERIAL_CONSOLE"

# --------------------------------------------------------------- seed
# The answer file reaches the installer on a second CD-ROM, found by
# volume label so nothing depends on device ordering: subiquity reads
# cloud-init's NoCloud seed from CIDATA, anaconda reads /ks.cfg from
# OEMDRV.
seed_label() {
    case "$INSTALLER" in
        subiquity) printf CIDATA ;;
        kickstart) printf OEMDRV ;;
    esac
}

seed_iso() {
    log "== seed: answer file -> $(seed_label) CD"
    local src dst hash dir="$work_dir/seed"
    mkdir -p "$dir"
    case "$INSTALLER" in
        subiquity) src="$IMAGE_DIR/autoinstall/user-data"; dst="$dir/user-data" ;;
        kickstart) src="$IMAGE_DIR/kickstart/ks.cfg";      dst="$dir/ks.cfg" ;;
    esac
    [[ -f "$src" ]] || die "no answer file: $src"

    # SHA-512 crypt: both installers store it verbatim and shadow(5) on
    # either distro checks it. The plaintext is never written to disk -
    # not into the repository's answer file, not into the log.
    hash=$(openssl passwd -6 "$BAREMETAL_ADMIN_PASSWORD")

    ADMIN_USER="$ADMIN_USER" PW_HASH="$hash" \
    SERIAL_CONSOLE="$SERIAL_CONSOLE" SERIAL_UNIT="$serial_unit" \
    python3 - "$src" "$dst" <<'RENDER'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
subs = {
    "@@ADMIN_USER@@": os.environ["ADMIN_USER"],
    "@@ADMIN_PASSWORD_HASH@@": os.environ["PW_HASH"],
    "@@SERIAL_CONSOLE@@": os.environ["SERIAL_CONSOLE"],
    "@@SERIAL_UNIT@@": os.environ["SERIAL_UNIT"],
}
for k, v in subs.items():
    text = text.replace(k, v)
left = [l for l in text.splitlines() if "@@" in l]
if left:
    sys.exit("unrendered placeholder in the answer file: " + left[0].strip())
open(dst, "w").write(text)
RENDER
    if [[ "$INSTALLER" == subiquity ]]; then
        printf 'instance-id: %s\nlocal-hostname: baremetal\n' \
            "$IMAGE_NAME-$(date +%s)" > "$dir/meta-data"
    fi

    "${MKISO[@]}" -quiet -output "$work_dir/seed.iso" -volid "$(seed_label)" \
        -joliet -rational-rock "$dir"/*
    log "   $(wc -c <"$work_dir/seed.iso") bytes"
}

# installer_boot sets $kernel, $initrd and $append for the ISO in $ISO.
# Both installers are booted through -kernel/-initrd rather than through
# the ISO's own boot menu: the options that make the install unattended
# have to be on the kernel command line, and there is nobody to type them.
installer_boot() {
    local iso_mnt="$work_dir/iso" opts dvd
    disk_mount "$ISO" "$iso_mnt" "ro,loop"
    kernel="$work_dir/vmlinuz"; initrd="$work_dir/initrd"
    case "$INSTALLER" in
        subiquity)
            cp "$iso_mnt/casper/vmlinuz" "$kernel"
            cp "$iso_mnt/casper/initrd" "$initrd"
            # The rest of the command line is copied from the ISO's own
            # grub.cfg, so a changed upstream layout cannot be dropped
            # silently.
            opts=$(python3 - "$iso_mnt/boot/grub/grub.cfg" <<'CMDLINE'
import re, sys
for line in open(sys.argv[1], errors="replace"):
    line = line.strip()
    if line.startswith("linux") and "/casper/vmlinuz" in line:
        opts = line.split("/casper/vmlinuz", 1)[1].strip()
        # Everything after "---" is handed to the installed system, not to
        # the installer's kernel; the pipeline appends its own separator.
        opts = opts.split("---", 1)[0]
        # Drop the installer's own quiet/splash: this build reads the log.
        print(re.sub(r"\b(quiet|splash)\b", "", opts).strip())
        break
else:
    sys.exit("no /casper/vmlinuz entry in the ISO's grub.cfg")
CMDLINE
)
            append="autoinstall $opts console=ttyS0,115200n8 ---"
            ;;
        kickstart)
            cp "$iso_mnt/images/pxeboot/vmlinuz" "$kernel"
            cp "$iso_mnt/images/pxeboot/initrd.img" "$initrd"
            # anaconda finds the rest of itself on the DVD by volume
            # label; read the label instead of hardcoding a release.
            dvd=$(blkid -o value -s LABEL "$ISO") || dvd=""
            [[ -n "$dvd" ]] || die "cannot read the DVD's volume label from $ISO"
            append="inst.stage2=hd:LABEL=$dvd inst.ks=hd:LABEL=OEMDRV:/ks.cfg inst.text console=ttyS0,115200n8"
            ;;
    esac
    umount "$iso_mnt"
    log "   append: $append"
}

# ------------------------------------------------------------ install
# The installer is booted through -kernel/-initrd taken from the ISO
# rather than through its own boot menu: "autoinstall" has to be on the
# kernel command line for subiquity to skip the "continue?" prompt, and
# there is nobody to press a key. The rest of the command line is copied
# from the ISO's own grub.cfg so a changed upstream layout cannot be
# silently dropped.
install_run() {
    log "== install: QEMU/OVMF, unattended (timeout ${INSTALL_TIMEOUT}s)"
    local vars mon qemu_pid t0 elapsed kernel initrd append
    rm -rf "$logs"; mkdir -p "$logs"

    installer_boot

    rm -f "$raw"
    qemu-img create -f raw "$raw" "$DISK_SIZE" >/dev/null
    vars="$work_dir/OVMF_VARS.fd"; cp "$OVMF_VARS" "$vars"
    mon="$work_dir/monitor.sock"

    # restrict=on: the installer must not reach the archive. Everything it
    # installs is on the ISO, and a build that can download is a build
    # that depends on the day it ran.
    qemu-system-x86_64 \
        -machine q35,accel=kvm -cpu host -m "$VM_MEM" -smp "$VM_CPUS" \
        -display none -vga std -monitor "unix:$mon,server,nowait" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$vars" \
        -drive if=none,id=d0,format=raw,file="$raw" -device virtio-blk-pci,drive=d0 \
        -drive if=none,id=iso,format=raw,readonly=on,file="$ISO" \
        -device ide-cd,drive=iso,bus=ide.0 \
        -drive if=none,id=seed,format=raw,readonly=on,file="$work_dir/seed.iso" \
        -device ide-cd,drive=seed,bus=ide.1 \
        -netdev user,id=n0,restrict=on -device virtio-net-pci,netdev=n0 \
        -kernel "$kernel" -initrd "$initrd" \
        -append "$append" \
        -serial "file:$logs/serial.log" \
        >"$logs/qemu.log" 2>&1 &
    qemu_pid=$!
    [[ -n "$KEEP_VM_ON_FAILURE" ]] || on_cleanup "kill '$qemu_pid' 2>/dev/null || true"

    local last_size=0 last_change=0 size shot=0
    t0=$(date +%s)
    until ! kill -0 "$qemu_pid" 2>/dev/null; do
        elapsed=$(( $(date +%s) - t0 ))
        if (( elapsed > INSTALL_TIMEOUT )); then
            printf 'screendump %s/timeout.ppm\n' "$logs" | timeout 5 socat - "UNIX-CONNECT:$mon" >/dev/null 2>&1 || true
            die "install did not finish within ${INSTALL_TIMEOUT}s; log in $logs/serial.log"
        fi
        if (( elapsed / 120 > shot )); then
            shot=$(( elapsed / 120 ))
            printf 'screendump %s/t%04d.ppm\n' "$logs" "$elapsed" | timeout 5 socat - "UNIX-CONNECT:$mon" >/dev/null 2>&1 || true
            size=$(stat -c %s "$logs/serial.log" 2>/dev/null || echo 0)
            if (( size != last_size )); then
                last_size=$size; last_change=$elapsed
            elif (( elapsed - last_change >= INSTALL_STALL )); then
                die "install hung: the serial log has not grown for $(( elapsed - last_change ))s; see $logs/serial.log"
            fi
        fi
        sleep 10
    done
    wait "$qemu_pid" || true
    log "   installer powered off after $(( $(date +%s) - t0 ))s"
}

# -------------------------------------------------------------- layer
#
# The installer that the Magnum driver runs at first boot on a plain image
# (magnum-cluster-api, data/node-bootstrap/install.sh) has an image mode
# that writes the same files into a chroot. That script - pinned by tag and
# checksum in layers/kubernetes/layer.yaml - is what runs here, so a
# bare-metal image with the layer and a first-boot node end up alike.
#
# The chroot has no network (unshare -n): the mirror is the layer cache on
# file://, the distribution packages and the control-plane images come from
# the same cache, and every one of those was fetched against the lock's
# checksums by ci/fetch-layer.sh. An artifact the lock does not name cannot
# get in, because there is nowhere to get it from.
layer_apply() {
    local k8s=$LAYER_KUBERNETES
    log "== layer: kubernetes $k8s onto $BASE_IMAGE_NAME -> $IMAGE_NAME"
    [[ -f "$base_raw" ]] || die "no base image to layer onto: $base_raw"
    [[ -f "$LAYER_CACHE/install.sh" && -d "$LAYER_CACHE/mirror" && -d "$LAYER_CACHE/images" ]] || \
        die "layer cache incomplete; run ci/fetch-layer.sh kubernetes $k8s $BASE_IMAGE_NAME"
    [[ -d "$LAYER_CACHE/packages/$BASE_IMAGE_NAME" ]] || \
        die "no packages fetched for $BASE_IMAGE_NAME; run ci/fetch-layer.sh kubernetes $k8s $BASE_IMAGE_NAME"
    local sha
    sha=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["script"]["sha256"])' "$LAYER_LOCK/artifacts.yaml")
    echo "$sha  $LAYER_CACHE/install.sh" | sha256sum -c --quiet - || die "the cached install.sh does not match the lock"

    log "   copying $base_raw"
    cp --sparse=always --reflink=auto "$base_raw" "$raw.part"
    mv "$raw.part" "$raw"

    local loop root layer_log="$OUTPUT_DIR/$IMAGE_NAME.layer.log"
    disk_attach loop "$raw" -P
    root=$(disk_find_root_partition "$loop" "$mnt") || die "no root filesystem in $raw"
    log "   root partition: $root"
    # Should the install die, a process it started may still hold the root
    # (a containerd it spawned for the image import, say); the plain unmount
    # the helper registered would then find the tree busy and give up, and
    # the loop device would be detached from under a live mount. Kill what
    # holds it and unmount first (LIFO: this runs before that handler).
    on_cleanup "mountpoint -q '$mnt' && { fuser -k -m '$mnt' >/dev/null 2>&1; sleep 1; umount -R -l '$mnt'; } || true"

    # The component versions the script installs, as the lock recorded them.
    local -a env_kv
    mapfile -t env_kv < <(python3 -c 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
for k,v in d["components"].items(): print(f"{k}={v}")' "$LAYER_LOCK/artifacts.yaml")
    local platform runtimes
    platform=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["gvisor_platform"])' "$LAYER_DIR/layer.yaml")
    runtimes=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["runtimes"])' "$LAYER_DIR/layer.yaml")

    # The API binds and the cache live in a private mount namespace that
    # ends with the install: nothing to unmount afterwards, nothing left
    # behind on failure, and two builds sharing one cache directory cannot
    # touch each other's view of it. Only the root mount and the loop
    # device are the parent's, and the cleanup stack already owns those.
    # No network namespace either (-n): the mirror is file://, and an
    # artifact the lock does not name has nowhere to come from.
    log "   installing in the chroot (private mount namespace, no network); log: $layer_log"
    if ! unshare -m -n --propagation private bash -c '
            set -Eeuo pipefail
            mnt=$1; cache=$2; shift 2
            for d in proc sys dev dev/pts; do mount --bind "/$d" "$mnt/$d"; done
            mkdir -p "$mnt/run/layer"
            mount --bind -o ro "$cache" "$mnt/run/layer"
            exec chroot "$mnt" env -i \
                PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb \
                NODE_BOOTSTRAP_MODE=image NODE_BOOTSTRAP_CONF=/dev/null \
                NODE_BOOTSTRAP_MIRROR=file:///run/layer/mirror \
                NODE_BOOTSTRAP_IMAGES_DIR=/run/layer/images \
                "$@" bash /run/layer/install.sh
        ' _ "$mnt" "$LAYER_CACHE" \
            K8S_VERSION="$k8s" "${env_kv[@]}" \
            GVISOR_PLATFORM="$platform" NODE_BOOTSTRAP_RUNTIMES="$runtimes" \
            NODE_BOOTSTRAP_PKG_DIR="/run/layer/packages/$BASE_IMAGE_NAME" \
            >"$layer_log" 2>&1; then
        tail -20 "$layer_log" >&2
        die "the layer install failed; see $layer_log"
    fi
    grep -E '^\[node-bootstrap\] done' "$layer_log" >&2 || die "the layer install did not report completion"

    # Nothing of the build stays in the image: the cache mount point, the
    # runtime directories the script created for its temporary containerd,
    # the import log. /run and /tmp are tmpfs on the deployed machine, but
    # the verify stage checks the disk, and so should find them clean.
    rmdir "$mnt/run/layer"
    rm -rf "$mnt/run/containerd" "$mnt/tmp/containerd-import.log" "$mnt"/tmp/tmp.*
    sync
    # Let go before verify re-attaches the image.
    umount "$mnt" || die "could not unmount $mnt after the layer; the image may be incomplete"
    losetup -d "$loop" 2>/dev/null || { sleep 1; losetup -d "$loop"; }
    log "   layer applied"
}

# ------------------------------------------------------------- verify
# Every check here is something that looks perfect on a VM and leaves a
# machine in a rack unusable. A failure is a build failure: the image does
# not get written, uploaded or named.
#
# Each check prints its own verdict. A checker that only speaks when it is
# unhappy cannot be told apart from a checker that did not run, and this
# stage has already shipped one criterion that could never fail (the
# firmware one) and one that could never pass (hid_generic vs
# hid-generic.ko).
_checks_failed=0

# chk <name> <reason-if-it-fails> ; the check itself is the exit status of
# the command that precedes it, passed in as $3...
chk() {
    local name=$1 detail=$2; shift 2
    if "$@"; then
        log "   ok   $name"
    else
        log "   FAIL $name - $detail"
        _checks_failed=$((_checks_failed + 1))
    fi
}

# Small predicates, so chk stays readable and every check is one line.
has_password() {
    awk -F: -v u="$1" '$1==u && $2 ~ /^\$/ {found=1} END{exit !found}' "$2"
}
# A separate /boot is a normal layout - the Rocky kickstart uses one, the
# Ubuntu "direct" layout does not - and everything this stage looks at
# (grub.cfg, the BLS entries, the initramfs) lives on it. Without this the
# checks read an empty directory on the root filesystem and report that a
# perfectly good image has no console and no initramfs, which is how the
# first Rocky build "failed" (2026-09-08).
mount_boot_if_separate() {
    local -n _mb_out=$2
    local root_mnt=$1 spec dev
    _mb_out=
    spec=$(awk '$1 !~ /^#/ && $2 == "/boot" {print $1; exit}' "$root_mnt/etc/fstab" 2>/dev/null || true)
    [[ -n "$spec" ]] || return 0
    case "$spec" in
        UUID=*)  dev=$(blkid -U "${spec#UUID=}" 2>/dev/null || true) ;;
        LABEL=*) dev=$(blkid -L "${spec#LABEL=}" 2>/dev/null || true) ;;
        /dev/*)  dev=$spec ;;
    esac
    [[ -n "$dev" && -b "$dev" ]] || die "fstab wants $spec for /boot; no such device in $raw"
    disk_mount "$dev" "$root_mnt/boot" "ro"
    log "   separate /boot: $dev"
    # Returned through a variable, not on stdout: this function logs, and
    # a caller writing boot_mnt=$(...) would capture the log line as part
    # of the path. That is how the umount below silently stopped working.
    _mb_out="$root_mnt/boot"
}

# Where the generated grub configuration lives: Debian keeps it in
# /boot/grub, the RPM distros in /boot/grub2.
grub_cfg_path() {
    local r=$1 c
    for c in "$r/boot/grub/grub.cfg" "$r/boot/grub2/grub.cfg"; do
        [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# And where the kernel command line lives, which is not the same place:
# with BLS (Rocky/RHEL) grub.cfg only says "blscfg" and the options are in
# /boot/loader/entries/*.conf. Checking grub.cfg alone would pass an image
# whose entries say "rhgb quiet" and nothing about a serial port.
boot_options_text() {
    local r=$1 c
    compgen -G "$r/boot/loader/entries/*.conf" >/dev/null &&
        cat "$r"/boot/loader/entries/*.conf
    # On RHEL-family BLS the entries say "$kernelopts" and the real
    # options live in grubenv; on Debian they are inline in grub.cfg.
    # Read all of it: the stray console=ttyS0 that the first Rocky
    # deploy booted with was in grubenv and in /etc/default/grub, and in
    # neither of the two files this function used to read.
    # /etc/default/grub is deliberately not read: it is an *input* to
    # grub-mkconfig, and on Ubuntu the installer's "quiet splash" there
    # is overridden by /etc/default/grub.d/ before anything reaches the
    # bootloader. Only what the bootloader will actually use counts.
    [[ -f "$r/boot/grub2/grubenv" ]] && grep -a "^kernelopts=" "$r/boot/grub2/grubenv"
    c=$(grub_cfg_path "$r") && cat "$c"
}

grub_console_ok() {
    local r=$1 text
    text=$(boot_options_text "$r") || return 1
    [[ -n "$text" ]] || return 1
    grep -q "console=$SERIAL_CONSOLE," <<<"$text" || return 1
    grep -q "console=tty0" <<<"$text" || return 1
    # Only the declared serial port. Anaconda copies the installer's own
    # console=ttyS0 into the installed kernel command line, and the
    # kernel gives /dev/console to the *last* console= it sees - so a
    # stray extra entry silently moves the console off the BMC's port
    # while every "is ttyS1 mentioned" check stays green.
    # Not "grep -o | grep -qv": under pipefail the consumer's early exit
    # kills the producer with SIGPIPE, the pipeline fails, and the
    # negation turns that into a pass. It did, on an image that had the
    # stray console=ttyS0 in every BLS entry.
    local others
    others=$(grep -oE "console=ttyS[0-9]+" <<<"$text" | grep -v "console=$SERIAL_CONSOLE\$" || true)
    # Not the last statement of this function, so its verdict has to be
    # returned explicitly - a bare test here is silently ignored.
    [[ -z "$others" ]] || return 1
    grep -qE '(^|[[:space:]])(quiet|splash|rhgb)([[:space:]]|$)' <<<"$text" && return 1
    local cfg
    cfg=$(grub_cfg_path "$r") || return 1
    grep -q "^serial " "$cfg"
}
grub_menu_waits() {
    local cfg
    cfg=$(grub_cfg_path "$1") || return 1
    grep -qE "set timeout=[1-9]" "$cfg"
}
# A driver is usable before the root filesystem is mounted if the
# initramfs carries it OR the kernel was built with it. Both happen:
# Ubuntu builds hid_generic and usbhid as modules, Rocky builds them in
# (CONFIG_HID_GENERIC=y), so a check that only looks for a .ko can never
# pass on Rocky however good the image is. Ask the image's own kernel
# config instead of assuming a layout. Arguments are module:CONFIG pairs.
early_boot_drivers() {
    local r=$1 list=$2 pair mod sym cfg found
    shift 2
    for pair in "$@"; do
        mod=${pair%%:*}; sym=${pair#*:}
        grep -qE "/${mod//[-_]/[-_]}\.ko" <<<"$list" && continue
        found=
        for cfg in "$r"/boot/config-*; do
            [[ -f "$cfg" ]] || continue
            grep -qx "CONFIG_$sym=y" "$cfg" && { found=1; break; }
        done
        [[ -n "$found" ]] || return 1
    done
}
firmware_landed() {
    compgen -G "$1/usr/lib/firmware/bnx2x/*" >/dev/null ||
    compgen -G "$1/lib/firmware/bnx2x/*" >/dev/null
}
# Hypervisor guest agents have no business on bare metal, and both
# installers put one there on their own: anaconda adds @platform-kvm
# (qemu-guest-agent) because the build runs in KVM, and ubuntu-server
# Recommends open-vm-tools on any hardware. Neither runs on a physical
# machine, but a tenant who finds one on a rented server reads it as the
# operator's foothold. Ask the package database, not the unit files: a
# unit can be masked while the package - and the binary - stays.
# Prints the agents found, one per line; empty means clean.
guest_agents_found() {
    python3 - "$1" <<'AGENTS'
import os, sqlite3, sys
root = sys.argv[1]
agents = {"qemu-guest-agent", "open-vm-tools", "hyperv-daemons", "spice-vdagent"}
found = set()
status = os.path.join(root, "var/lib/dpkg/status")
if os.path.isfile(status):
    name, installed = None, False
    for line in open(status, errors="replace"):
        if line.startswith("Package: "):
            name, installed = line.split(None, 1)[1].strip(), False
        elif line.startswith("Status: ") and "installed" in line and "not-installed" not in line:
            installed = True
        elif line.strip() == "" and name in agents and installed:
            found.add(name)
for db in ("usr/lib/sysimage/rpm/rpmdb.sqlite", "var/lib/rpm/rpmdb.sqlite"):
    path = os.path.join(root, db)
    if not os.path.isfile(path):
        continue
    try:
        con = sqlite3.connect(f"file:{path}?immutable=1", uri=True)
        for (key,) in con.execute("select key from Name"):
            name = key.decode() if isinstance(key, bytes) else str(key)
            if name in agents:
                found.add(name)
    finally:
        try:
            con.close()
        except Exception:
            pass
for rel in ("usr/bin/qemu-ga", "usr/sbin/qemu-ga", "usr/bin/vmtoolsd",
            "usr/sbin/hv_kvp_daemon", "usr/bin/spice-vdagent"):
    if os.path.exists(os.path.join(root, rel)):
        found.add(os.path.basename(rel))
print("\n".join(sorted(found)))
AGENTS
}
no_guest_agents() {
    GUEST_AGENTS=$(guest_agents_found "$1" | tr '\n' ' ')
    GUEST_AGENTS=${GUEST_AGENTS% }
    [[ -z "$GUEST_AGENTS" ]] || { log "        found: $GUEST_AGENTS"; return 1; }
}
is_a_template() {
    local r=$1
    [[ ! -s "$r/etc/machine-id" ]] || return 1
    ! compgen -G "$r/etc/ssh/ssh_host_*" >/dev/null || return 1
    [[ ! -e "$r/var/lib/dbus/machine-id" ]] || return 1
}

# Whether cloud-init will actually run on the deployed machine and read
# the config drive Ironic attaches.
#
# "grep ConfigDrive in cloud.cfg.d" is not that question: it finds the
# file this pipeline wrote and says nothing about what wins. Subiquity
# leaves /etc/cloud/cloud.cfg.d/99-installer.cfg behind, cloud.cfg.d is
# merged in lexicographic order, and 99-installer sorts after
# 99-datasources - so the installed image had datasource_list [None],
# whose datasource writes /etc/cloud/cloud-init.disabled on first boot
# and also turns off growpart and resize_rootfs. Deployed, that machine
# reads no metadata, configures no network, keeps the hostname
# "baremetal" and never grows past 12 GB - and Ironic still reports
# success. So compute the effective configuration the way cloud-init
# would, and check the outcome.
cloudinit_will_work() {
    local r=$1
    python3 - "$r" <<'CLOUDINIT'
import glob, os, sys
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml is required")

root = sys.argv[1]
if os.path.exists(os.path.join(root, "etc/cloud/cloud-init.disabled")):
    sys.exit("cloud-init is disabled in the image (/etc/cloud/cloud-init.disabled)")

files = [os.path.join(root, "etc/cloud/cloud.cfg")]
files += sorted(glob.glob(os.path.join(root, "etc/cloud/cloud.cfg.d/*.cfg")))

datasources, growpart, resize, netcfg, offenders = None, None, None, None, {}
for path in files:
    if not os.path.isfile(path):
        continue
    try:
        with open(path, errors="replace") as fh:
            doc = yaml.safe_load(fh) or {}
    except yaml.YAMLError:
        continue
    if not isinstance(doc, dict):
        continue
    if "datasource_list" in doc:
        datasources = doc["datasource_list"]
        offenders["datasource_list"] = os.path.basename(path)
    if isinstance(doc.get("growpart"), dict) and "mode" in doc["growpart"]:
        growpart = doc["growpart"]["mode"]
        offenders["growpart"] = os.path.basename(path)
    if "resize_rootfs" in doc:
        resize = doc["resize_rootfs"]
        offenders["resize_rootfs"] = os.path.basename(path)
    if isinstance(doc.get("network"), dict) and "config" in doc["network"]:
        netcfg = doc["network"]["config"]
        offenders["network"] = os.path.basename(path)

problems = []
if not datasources or "ConfigDrive" not in datasources:
    problems.append(f"effective datasource_list is {datasources!r} "
                    f"(from {offenders.get('datasource_list', 'nowhere')})")
if str(growpart).lower() in ("off", "false"):
    problems.append(f"growpart is {growpart!r} (from {offenders.get('growpart')})")
if resize is False:
    problems.append(f"resize_rootfs is off (from {offenders.get('resize_rootfs')})")
if netcfg == "disabled":
    problems.append(f"cloud-init networking is disabled (from {offenders.get('network')})")

stale = glob.glob(os.path.join(root, "etc/netplan/*installer*"))
if stale:
    problems.append("the installer's netplan is still there: " +
                    ", ".join(os.path.basename(f) for f in stale))

if problems:
    sys.exit("; ".join(problems))
CLOUDINIT
}

verify_image() {
    log "== verify: console contract, initramfs, firmware, no guest agent"
    local loop root img list boot_mnt=
    _checks_failed=0
    disk_attach loop "$raw" -P
    # Read-only: nothing here writes, and a read-write mount left behind by
    # a failed check is how a finished install got emptied once.
    root=$(disk_find_root_partition "$loop" "$mnt" "ro") || die "no root filesystem in $raw"
    log "   root partition: $root"
    mount_boot_if_separate "$mnt" boot_mnt

    img=$(ls -1t "$mnt"/boot/initrd.img-* "$mnt"/boot/initramfs-*.img 2>/dev/null | head -1) || true
    list=""
    if [[ -n "$img" ]]; then
        list=$(initrd_list "$mnt" "/boot/${img##*/}") || list=""
    fi

    # 1 Somebody can log in at the keyboard. Cloud images fail this one.
    chk "local login: $ADMIN_USER has a password" \
        "nobody can log in at the console" \
        has_password "$ADMIN_USER" "$mnt/etc/shadow"
    # 2 Both consoles, and nothing hiding what they would show.
    chk "grub console: tty0 + $SERIAL_CONSOLE, serial terminal, no quiet/splash" \
        "the BMC serial console or the screen would show nothing" \
        grub_console_ok "$mnt"
    # 3 A menu that can be stopped at, for the recovery entry.
    chk "grub menu waits" \
        "no way to reach the recovery entry" \
        grub_menu_waits "$mnt"
    # 4 Something answering on the serial port once userspace is up.
    chk "serial-getty@$SERIAL_CONSOLE enabled" \
        "the serial console shows boot messages but offers no login" \
        test -e "$mnt/etc/systemd/system/getty.target.wants/serial-getty@$SERIAL_CONSOLE.service"
    # 5 Storage drivers: without these the machine never reaches its root.
    chk "early-boot storage drivers (ahci smartpqi hpsa megaraid_sas mpt3sas nvme)" \
        "the machine drops to the dracut shell instead of booting" \
        early_boot_drivers "$mnt" "$list" ahci:SATA_AHCI smartpqi:SCSI_SMARTPQI \
            hpsa:SCSI_HPSA megaraid_sas:MEGARAID_SAS mpt3sas:SCSI_MPT3SAS \
            nvme:BLK_DEV_NVME
    # 6 And the drivers that make that shell readable and typeable.
    chk "early-boot console drivers (hid_generic usbhid mgag200 ast)" \
        "the emergency shell cannot be read or typed into" \
        early_boot_drivers "$mnt" "$list" hid_generic:HID_GENERIC usbhid:USB_HID \
            mgag200:DRM_MGAG200 ast:DRM_AST
    # 6b A config drive on a CD-ROM is seen at early boot. Ironic writes the
    #    config drive as a partition of the root disk; Nova offers it as a
    #    CD-ROM, and ds-identify runs as a systemd generator, before udev
    #    coldplug would load a driver that is not built in. (The other half
    #    of that story is the machine type: Nova's default i440fx IDE
    #    CD-ROM is invisible to the 7.0 kernel on a QEMU 8.2 host; a test
    #    record needs hw_machine_type=q35. That is a Glance property, not
    #    an image property, so nothing here can check it.)
    chk "early-boot config-drive drivers (sr_mod isofs)" \
        "a CD-ROM config drive is missed and cloud-init runs with no data" \
        early_boot_drivers "$mnt" "$list" sr_mod:BLK_DEV_SR isofs:ISO9660_FS
    # 7 Firmware. "The directory is not empty" does not discriminate: the
    #   cloud images ship regulatory.db there and nothing else.
    chk "linux-firmware landed (bnx2x blobs present)" \
        "cards that load host firmware stay dark" \
        firmware_landed "$mnt"
    # 8 A template, not a machine.
    chk "template identity (empty machine-id, no ssh host keys)" \
        "every deployed machine would share an identity" \
        is_a_template "$mnt"
    # 9 And one that will actually read the config drive it is given.
    chk "cloud-init runs and uses ConfigDrive (growth and networking on)" \
        "the machine boots with no metadata, no network and a 12 GB root" \
        cloudinit_will_work "$mnt"
    # 10 cloud-init only *calls* growpart. On RPM distros the tool is its
    #    own package, and without it the root stays the image's size on
    #    whatever disk it lands on (10 GB of 371 GB, first Rocky deploy).
    chk "growpart tool present (root grows to the disk on first boot)" \
        "the root filesystem stays the image's size" \
        test -x "$mnt/usr/bin/growpart"
    # 11 Nothing that answers to a hypervisor. The manifest records the
    #    outcome instead of asserting it by hand.
    GUEST_AGENTS=
    chk "no hypervisor guest agent (qemu-ga, vmtoolsd, hv_kvp_daemon, spice-vdagent)" \
        "a tenant would find the operator's agent on the machine they rent" \
        no_guest_agents "$mnt"

    # 12+ The layer, if there is one: its own checks, its own verdict lines,
    #     and the manifest fields it read back from the image.
    local layer_failed=0
    LAYER_MANIFEST='{}'
    if [[ -n "$LAYER_KUBERNETES" ]]; then
        log "   -- layer: kubernetes $LAYER_KUBERNETES --"
        local out
        out=$("$LAYER_DIR/verify.sh" "$mnt" "$LAYER_KUBERNETES") || layer_failed=$?
        LAYER_MANIFEST=$(sed -n 's/^manifest: //p' <<<"$out")
        [[ -n "$LAYER_MANIFEST" ]] || { LAYER_MANIFEST='{}'; layer_failed=$((layer_failed + 1)); warn "layer verify emitted no manifest"; }
    fi

    # Let go of the image before anything else can fail: the cleanup stack
    # unwinds in the right order, but a mount that is still there when the
    # loop device goes is how a built image gets destroyed.
    sync
    if [[ -n "$boot_mnt" ]]; then
        umount "$boot_mnt" || warn "could not unmount $boot_mnt"
    fi
    umount "$mnt" || warn "could not unmount $mnt - the work directory will not clean up"

    ((_checks_failed == 0 && layer_failed == 0)) || \
        die "verify failed ($_checks_failed of 12 base checks, $layer_failed layer checks); the image is not usable"
    log "   12/12 passed${LAYER_KUBERNETES:+, layer checks passed}"
}

# initrd_list <rootfs> <path-inside> — the file list of an initramfs.
#
# Host tools first, and the image's own only as a fallback: the image is
# mounted read-only here, and lsinitrd unpacks into a temporary directory,
# so running it inside the chroot needs a writable /tmp laid over the
# mount. Doing that by default would mean writing to an image the stage
# is only supposed to inspect.
initrd_list() {
    local rootfs=$1 path=$2 status
    if command -v lsinitrd >/dev/null; then
        lsinitrd "$rootfs$path"
    elif command -v unmkinitramfs >/dev/null; then
        unmkinitramfs -l "$rootfs$path"
    elif [[ -x "$rootfs/usr/bin/lsinitrd" || -x "$rootfs/usr/sbin/lsinitrd" ]]; then
        mount -t tmpfs -o size=256m tmpfs "$rootfs/tmp" || return 1
        chroot "$rootfs" lsinitrd "$path"; status=$?
        umount "$rootfs/tmp"
        return $status
    else
        return 1
    fi
}

# ----------------------------------------------------------- manifest
# qemu_guest_agent is what verify measured (check 11), never a constant:
# the first Rocky image carried qemu-guest-agent while its manifest
# said false.
write_manifest() {
    local out="$raw" fmt=$OUTPUT_FORMAT
    if [[ "$fmt" != raw ]]; then
        out="$OUTPUT_DIR/$IMAGE_NAME.$fmt"
        qemu-img convert -O "$fmt" "$raw" "$out"
    fi
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$out")" > "$IMAGE_NAME.sha256")
    manifest_write "$OUTPUT_DIR" "$IMAGE_NAME" "$(jq -n \
        --arg disk "$(basename "$out")" \
        --arg fmt "$fmt" \
        --arg iso "$SOURCE_ISO" \
        --arg installer "$INSTALLER" \
        --arg serial "$SERIAL_CONSOLE" \
        --arg user "$ADMIN_USER" \
        --arg base "$BASE_IMAGE_NAME" \
        --argjson qga "$([[ -n "${GUEST_AGENTS:-}" ]] && echo true || echo false)" \
        --argjson layer "${LAYER_MANIFEST:-{\}}" \
        '{disk: $disk, disk_format: $fmt, target: "baremetal",
          source_iso: $iso, installer: $installer,
          serial_console: $serial, admin_user: $user, base_image: $base,
          qemu_guest_agent: $qga, baremetal_firmware: true} + $layer')" >/dev/null
    log "== done: $out"
}

if [[ -z "$VERIFY_ONLY" ]]; then
    if [[ -n "$LAYER_KUBERNETES" ]]; then
        # The installer writes the base image; the layer works on a copy.
        if [[ -f "$base_raw" ]]; then
            log "== install: reusing the base image already in $OUTPUT_DIR ($BASE_IMAGE_NAME)"
        else
            layered_raw=$raw; layered_logs=$logs
            raw=$base_raw; logs=$base_logs
            seed_iso
            install_run
            raw=$layered_raw; logs=$layered_logs
        fi
        [[ -n "$INSTALL_ONLY" ]] && exit 0
        layer_apply
    else
        seed_iso
        install_run
    fi
fi
if [[ -n "$INSTALL_ONLY" ]]; then
    exit 0
fi
verify_image
write_manifest
