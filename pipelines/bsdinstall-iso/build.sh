#!/usr/bin/env bash
# Install FreeBSD from its official DVD with bsdinstall's scripted install,
# offline, and turn the result into a bare-metal image.
#
# FreeBSD has no initramfs: the GENERIC kernel and its modules are the same
# whether the system came from the installer or from the official cloud
# image. What the installer is for here is the rest of the console
# contract - a local login, the BMC's serial port as the console, a loader
# menu that waits - and a system without the cloud image's defaults (root
# without a password, password SSH, nuageinit's freebsd/freebsd).
#
# Stages:
#   seed      the answer file's CD (FBSDOEM): post-install.sh, the files
#             it installs, oem.env (admin user, password hash, serial
#             port), and the packages the base system lacks - pkg and sudo
#             (+ dependencies) copied off the DVD's own repository, dhcpcd
#             pinned from the release's frozen package set
#   remaster  the DVD with two files added: /etc/installerconfig (the file
#             the installer runs unattended; images/<name>/installerconfig)
#             and /boot/loader.conf.local (the installer's console on the
#             serial port, so the install leaves a transcript); the boot
#             records are replayed unchanged
#   install   QEMU/OVMF boots the DVD, no NIC: everything comes from the
#             DVD and the CD. The installer reboots when it is done, which
#             -no-reboot turns into QEMU exiting
#   verify    mount the result read-only and check the console contract
#             (verify.sh)
#   boottest  boot it with a config drive carrying Ironic-shaped
#             network_data (bond + VLANs), log in on the serial console and
#             over SSH, check the network, the accounts, the growth
#             (boot-test.py)
#   manifest
#
# BAREMETAL_ADMIN_PASSWORD is the local console password (CI: a secret).
# INSTALL_ONLY=1, VERIFY_ONLY=1 as in distro-iso. Needs root and /dev/kvm.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source=../../lib/manifest.sh
source "$LIB_DIR/manifest.sh"

IMAGE_NAME=${IMAGE_NAME:?Set IMAGE_NAME}
IMAGE_DIR=${IMAGE_DIR:?Set IMAGE_DIR}
OUTPUT_DIR=${OUTPUT_DIR:?Set OUTPUT_DIR}
SOURCE_ISO=${SOURCE_ISO:?Set SOURCE_ISO (an artifact in upstream/sources.yaml)}
SOURCE_PACKAGES=${SOURCE_PACKAGES:-}
INSTALLER=${INSTALLER:-bsdinstall}
DISK_SIZE=${DISK_SIZE:-8G}
OUTPUT_FORMAT=${OUTPUT_FORMAT:-raw}
ADMIN_USER=${ADMIN_USER:-sysadmin}
SERIAL_CONSOLE=${SERIAL_CONSOLE:-ttyS1}
CACHE_DIR=${CACHE_DIR:-$REPO_DIR/upstream/cache}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
VM_MEM=${VM_MEM:-4096}
VM_CPUS=${VM_CPUS:-2}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-3600}
INSTALL_STALL=${INSTALL_STALL:-900}
INSTALL_ONLY=${INSTALL_ONLY:-}
VERIFY_ONLY=${VERIFY_ONLY:-}
[[ "$INSTALLER" == bsdinstall ]] || die "pipeline bsdinstall-iso only runs bsdinstall (got $INSTALLER)"
[[ "$ADMIN_USER" =~ ^[a-z][a-z0-9_-]*$ ]] || die "not a login name: $ADMIN_USER"

# The serial port the BMC's serial-over-LAN is, by its Linux name in the
# declaration: ttyS0 is COM1, ttyS1 is COM2.
case "$SERIAL_CONSOLE" in
    ttyS0) SERIAL_IO=0x3F8; SERIAL_TTY=ttyu0 ;;
    ttyS1) SERIAL_IO=0x2F8; SERIAL_TTY=ttyu1 ;;
    *) die "serial_console must be ttyS0 or ttyS1 (got $SERIAL_CONSOLE)" ;;
esac

require_cmd qemu-system-x86_64 qemu-img xorriso python3 sha256sum jq openssl tar zstd sfdisk
require_root
[[ -e /dev/kvm ]] || die "/dev/kvm is required"
install_cleanup_traps

artifact_file() {
    python3 - "$REPO_DIR/upstream/sources.yaml" "$1" <<'PY'
import sys, yaml
a = (yaml.safe_load(open(sys.argv[1])) or {}).get("artifacts", {}).get(sys.argv[2])
if not a or not a.get("filename"):
    sys.exit(f"no artifact {sys.argv[2]!r} with a filename in upstream/sources.yaml")
print(a["filename"])
PY
}
ISO="$CACHE_DIR/$(artifact_file "$SOURCE_ISO")"
[[ -f "$ISO" ]] || die "missing upstream artifact: $ISO (ci/fetch-upstream.sh $SOURCE_ISO)"
[[ -f "$IMAGE_DIR/installerconfig" ]] || die "no answer file: $IMAGE_DIR/installerconfig"

work_dir=; make_work_dir work_dir "${TMPDIR:-/var/tmp}/build.XXXXXXXX"
raw="$OUTPUT_DIR/$IMAGE_NAME.raw"
logs="$OUTPUT_DIR/$IMAGE_NAME.install"
mkdir -p "$OUTPUT_DIR"

# ------------------------------------------------------------------ seed
seed_cd() {
    log "== seed: the FBSDOEM CD"
    [[ -n "${BAREMETAL_ADMIN_PASSWORD:-}" ]] || die "BAREMETAL_ADMIN_PASSWORD is required (the local console password)"
    local seed="$work_dir/seed" iso_mnt="$work_dir/dvd" abi hash
    mkdir -p "$seed/payload" "$seed/pkgs" "$iso_mnt"
    install -m 0755 "$SCRIPT_DIR/payload/post-install.sh" "$seed/post-install.sh"
    install -m 0644 "$SCRIPT_DIR/payload/rc.conf.d-nuageinit" "$SCRIPT_DIR/payload/nuageinit-netdata" \
        "$SCRIPT_DIR/payload/nuageinit_default_password" "$seed/payload/"
    # SHA-512 crypt, as FreeBSD's passwd_format=sha512 writes it; the
    # password itself goes nowhere else.
    hash=$(printf '%s' "$BAREMETAL_ADMIN_PASSWORD" | openssl passwd -6 -stdin)
    {
        printf 'ADMIN_USER=%s\n' "$ADMIN_USER"
        printf "ADMIN_HASH='%s'\n" "$hash"
        printf 'SERIAL_IO=%s\n' "$SERIAL_IO"
        printf 'SERIAL_TTY=%s\n' "$SERIAL_TTY"
    } >"$seed/oem.env"
    chmod 0600 "$seed/oem.env"

    # pkg and sudo with its dependencies, off the DVD's repository.
    mount -o loop,ro "$ISO" "$iso_mnt"
    on_cleanup "mountpoint -q '$iso_mnt' && umount '$iso_mnt' || true"
    abi=$(cd "$iso_mnt/packages" && ls -d FreeBSD:*:amd64 | head -1)
    [[ -n "$abi" ]] || die "no package repository on the DVD"
    # packagesite.pkg is a zstd tar. GNU tar (with zstd installed) reads
    # it; Python's tarfile only learned zstd in 3.14, and the CI runner's
    # 3.12 failed here while every local build passed.
    tar -xOf "$iso_mnt/packages/$abi/packagesite.pkg" packagesite.yaml >"$work_dir/packagesite.yaml" \
        || die "cannot read packagesite.yaml off the DVD"
    python3 - "$iso_mnt/packages/$abi" "$seed/pkgs" "$work_dir/packagesite.yaml" pkg sudo <<'PY' || die "resolving packages on the DVD failed"
import json, os, shutil, sys
repo, dest, sitefile, *wanted = sys.argv[1:]
with open(sitefile) as fh:
    site = fh.read()
pkgs = {}
for line in site.splitlines():
    d = json.loads(line)
    pkgs[d["name"]] = d
todo, done = list(wanted), set()
while todo:
    n = todo.pop()
    if n in done:
        continue
    if n not in pkgs:
        sys.exit(f"{n} is not on the DVD")
    d = pkgs[n]
    done.add(n)
    # pkg add finds a dependency as <name>-<version>.pkg next to the package.
    shutil.copyfile(os.path.join(repo, d["path"]), os.path.join(dest, f"{n}-{d['version']}.pkg"))
    print(f"   {n}-{d['version']} (DVD)")
    todo.extend((d.get("deps") or {}).keys())
PY
    umount "$iso_mnt"
    # The pinned packages, named by their own manifests.
    local id f name version
    for id in $SOURCE_PACKAGES; do
        f="$CACHE_DIR/$(artifact_file "$id")"
        [[ -f "$f" ]] || die "missing upstream artifact: $f (ci/fetch-upstream.sh $id)"
        name=$(tar -xOf "$f" +COMPACT_MANIFEST | jq -r .name)
        version=$(tar -xOf "$f" +COMPACT_MANIFEST | jq -r .version)
        cp "$f" "$seed/pkgs/$name-$version.pkg"
        log "   $name-$version (pinned: $id)"
    done
    xorriso -as mkisofs -quiet -V FBSDOEM -J -R -o "$work_dir/seed.iso" "$seed"
}

# -------------------------------------------------------------- remaster
# FreeBSD's ISO keeps its El Torito images hidden (not files of the ISO
# filesystem): xorriso cannot replay them and would write an ISO that does
# not boot. The boot set-up is rebuilt the way the release's own ISO is
# made: BIOS from /boot/cdboot (a file on the ISO), UEFI from the FAT image
# the original carries - taken byte for byte from where its catalog says
# it is and added as /boot/efiboot.img.
remaster_dvd() {
    log "== remaster: $(basename "$ISO") + /etc/installerconfig + /boot/loader.conf.local"
    # The serial port as the installer's second console: the kernel, rc
    # and the post-install script (it writes to /dev/console) leave a
    # transcript in the build log. Not the primary one: on a serial
    # primary console startbsdinstall asks for the terminal type before it
    # looks at installerconfig, and nobody is there to answer; nor a second
    # installer on it (bsdinstall.multicons_disable).
    printf '%s\n' '# The serial port as the installer'"'"'s second console (bsdinstall-iso).' \
        'boot_multicons="YES"' 'comconsole_speed="115200"' \
        'console="efi,comconsole"' 'bsdinstall.multicons_disable="YES"' >"$work_dir/loader.conf.local"
    local report n lba blocks
    report=$(xorriso -indev "$ISO" -report_el_torito plain 2>/dev/null)
    # "El Torito boot img :   2  UEFI  y ... LBA" and "El Torito img blks :   2  1024"
    n=$(awk '$3 == "boot" && $4 == "img" && $7 == "UEFI" {print $6}' <<<"$report")
    lba=$(awk '$3 == "boot" && $4 == "img" && $7 == "UEFI" {print $NF}' <<<"$report")
    blocks=$(awk -v n="$n" '$3 == "img" && $4 == "blks" && $6 == n {print $7}' <<<"$report")
    [[ "$lba" =~ ^[0-9]+$ && "$blocks" =~ ^[0-9]+$ ]] ||
        { echo "$report" >&2; die "cannot find the UEFI boot image in the DVD's El Torito catalog"; }
    dd if="$ISO" of="$work_dir/efiboot.img" bs=2048 skip="$lba" count="$blocks" status=none
    [[ "$(blkid -s TYPE -o value "$work_dir/efiboot.img")" == vfat ]] ||
        die "the UEFI boot image at LBA $lba is not a FAT image"
    xorriso -indev "$ISO" -outdev "$work_dir/install.iso" \
        -boot_image any discard \
        -map "$IMAGE_DIR/installerconfig" /etc/installerconfig \
        -map "$work_dir/loader.conf.local" /boot/loader.conf.local \
        -map "$work_dir/efiboot.img" /boot/efiboot.img \
        -boot_image any cat_path=/boot/boot.catalog -boot_image any cat_hidden=on \
        -boot_image any bin_path=/boot/cdboot -boot_image any emul_type=no_emulation \
        -boot_image any next \
        -boot_image any efi_path=/boot/efiboot.img \
        >"$work_dir/xorriso.log" 2>&1 ||
        { grep -vE 'UPDATE' "$work_dir/xorriso.log" | tail -20 >&2; die "remastering the DVD failed"; }
    { xorriso -indev "$work_dir/install.iso" -report_el_torito plain 2>/dev/null || true; } | grep -E 'boot img' | sed 's/^/   /'
}

# --------------------------------------------------------------- install
install_run() {
    log "== install: bsdinstall script, offline (timeout ${INSTALL_TIMEOUT}s)"
    rm -f "$raw"; truncate -s "$DISK_SIZE" "$raw"
    rm -rf "$logs"; mkdir -p "$logs"
    cp "$OVMF_VARS" "$work_dir/vars.fd"
    # The DVD on virtio-scsi: OVMF hangs reading it from the q35 SATA CD
    # (QEMU 10.2.1; the original DVD too, 2026-09-24), and QEMU later
    # crashed.
    local mon="$work_dir/mon.sock" t0 last_size=0 last_change qemu_pid
    qemu-system-x86_64 \
        -machine q35,accel=kvm -cpu host -m "$VM_MEM" -smp "$VM_CPUS" \
        -display none -vga std -monitor "unix:$mon,server,nowait" \
        -serial "file:$logs/serial.log" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$work_dir/vars.fd" \
        -drive if=none,id=d0,format=raw,file="$raw",cache=unsafe -device virtio-blk-pci,drive=d0 \
        -device virtio-scsi-pci,id=scsi0 \
        -drive if=none,id=cd0,format=raw,readonly=on,file="$work_dir/install.iso" -device scsi-cd,drive=cd0,bus=scsi0.0,bootindex=0 \
        -drive if=none,id=cd1,format=raw,readonly=on,file="$work_dir/seed.iso" -device scsi-cd,drive=cd1,bus=scsi0.0 \
        -nic none -no-reboot >"$logs/qemu.log" 2>&1 &
    qemu_pid=$!
    on_cleanup "kill '$qemu_pid' 2>/dev/null || true"
    t0=$(date +%s); last_change=$t0
    while kill -0 "$qemu_pid" 2>/dev/null; do
        sleep 10
        local size now
        size=$(stat -c %s "$logs/serial.log" 2>/dev/null || echo 0)
        now=$(date +%s)
        if (( size != last_size )); then last_size=$size; last_change=$now; fi
        if (( now - last_change > INSTALL_STALL )); then
            printf 'screendump %s\n' "$logs/stalled.ppm" | socat - "UNIX-CONNECT:$mon" >/dev/null 2>&1 || true
            tail -30 "$logs/serial.log" | tr -d '\r' >&2
            die "install stalled: the serial log has not grown for ${INSTALL_STALL}s"
        fi
        (( now - t0 > INSTALL_TIMEOUT )) && die "install did not finish within ${INSTALL_TIMEOUT}s"
    done
    wait "$qemu_pid" || die "QEMU exited with an error (see $logs/qemu.log)"
    tr -d '\r' <"$logs/serial.log" >"$logs/serial.txt"
    grep -q '^OEM-POSTINSTALL-DONE' "$logs/serial.txt" ||
        { tail -40 "$logs/serial.txt" >&2; die "the post-install script did not finish (see $logs/serial.txt)"; }
    log "   installed after $(( $(date +%s) - t0 ))s"
}

if [[ -z "$VERIFY_ONLY" ]]; then
    seed_cd
    remaster_dvd
    if [[ -n "${KEEP_INSTALL_MEDIA:-}" ]]; then
        # For debugging the installer by hand: the two CDs, then stop.
        mkdir -p "$logs"
        cp "$work_dir/install.iso" "$work_dir/seed.iso" "$logs/"
        log "   kept $logs/install.iso and $logs/seed.iso (KEEP_INSTALL_MEDIA)"
        exit 0
    fi
    install_run
fi
[[ -n "$INSTALL_ONLY" ]] && exit 0

# ---------------------------------------------------------------- verify
log "== verify: the console contract"
SERIAL_IO=$SERIAL_IO SERIAL_TTY=$SERIAL_TTY ADMIN_USER=$ADMIN_USER \
    bash "$SCRIPT_DIR/verify.sh" "$raw" | tee "$logs/verify.log"
[[ ${PIPESTATUS[0]} -eq 0 ]] || die "verify failed; the image does not keep the console contract"

# -------------------------------------------------------------- boottest
log "== boottest: config drive with bond + VLANs, serial login, SSH"
[[ -n "${BAREMETAL_ADMIN_PASSWORD:-}" ]] || die "BAREMETAL_ADMIN_PASSWORD is required for the boot test"
OVMF_CODE="$OVMF_CODE" OVMF_VARS="$OVMF_VARS" ADMIN_USER="$ADMIN_USER" \
    python3 "$SCRIPT_DIR/boot-test.py" "$raw" "$logs/boottest" "$SERIAL_CONSOLE" ||
    die "boot test failed"

# -------------------------------------------------------------- manifest
out="$raw"
if [[ "$OUTPUT_FORMAT" != raw ]]; then
    out="$OUTPUT_DIR/$IMAGE_NAME.$OUTPUT_FORMAT"
    qemu-img convert -O "$OUTPUT_FORMAT" "$raw" "$out"
fi
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$out")" >"$IMAGE_NAME.sha256")
version=$(sed -n 's/^freebsd-version: //p' "$logs/serial.txt" 2>/dev/null | head -1)
pkgs_json=$(sed -n 's/^oem-version: //p' "$logs/serial.txt" 2>/dev/null | jq -R 'split(" ") | {(.[0]): .[1]}' | jq -s 'add // {}')
manifest_write "$OUTPUT_DIR" "$IMAGE_NAME" "$(jq -n \
    --arg disk "$(basename "$out")" --arg fmt "$OUTPUT_FORMAT" --arg iso "$SOURCE_ISO" \
    --arg installer "$INSTALLER" --arg serial "$SERIAL_CONSOLE" --arg user "$ADMIN_USER" \
    --arg base "$BASE_IMAGE_NAME" --arg version "$version" --argjson pkgs "$pkgs_json" \
    '{disk: $disk, disk_format: $fmt, target: "baremetal", source_iso: $iso,
      installer: $installer, serial_console: $serial, admin_user: $user,
      base_image: $base, freebsd_version: $version, oem_pkgs: $pkgs,
      qemu_guest_agent: false, baremetal_firmware: true}')" >/dev/null
log "== done: $out"
