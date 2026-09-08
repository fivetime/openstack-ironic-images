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
#   verify    mount the result and check the console contract, the
#             initramfs and the firmware - the three things that are
#             invisible on a VM and fatal on hardware
#   manifest
#
# INSTALL_ONLY=1 stops after the install (no verify), VERIFY_ONLY=1 runs
# verify + manifest against the disk already in OUTPUT_DIR.
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
    c=$(grub_cfg_path "$r") && cat "$c"
}

grub_console_ok() {
    local r=$1 text
    text=$(boot_options_text "$r") || return 1
    [[ -n "$text" ]] || return 1
    grep -q "console=$SERIAL_CONSOLE," <<<"$text" || return 1
    grep -q "console=tty0" <<<"$text" || return 1
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
    log "== verify: console contract, initramfs, firmware"
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

    # Let go of the image before anything else can fail: the cleanup stack
    # unwinds in the right order, but a mount that is still there when the
    # loop device goes is how a built image gets destroyed.
    sync
    if [[ -n "$boot_mnt" ]]; then
        umount "$boot_mnt" || warn "could not unmount $boot_mnt"
    fi
    umount "$mnt" || warn "could not unmount $mnt - the work directory will not clean up"

    ((_checks_failed == 0)) || \
        die "verify failed ($_checks_failed of 9); the image is not usable on hardware"
    log "   9/9 passed"
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
        '{disk: $disk, disk_format: $fmt, target: "baremetal",
          source_iso: $iso, installer: $installer,
          serial_console: $serial, admin_user: $user,
          qemu_guest_agent: false, baremetal_firmware: true}')" >/dev/null
    log "== done: $out"
}

if [[ -z "$VERIFY_ONLY" ]]; then
    seed_iso
    install_run
fi
if [[ -n "$INSTALL_ONLY" ]]; then
    exit 0
fi
verify_image
write_manifest
