#!/usr/bin/env bash
# The console contract of a FreeBSD bare-metal image, checked on the disk
# with nothing running: its UFS root mounted read-only on the build host,
# or its ZFS pool imported read-only (under another name, no cache file,
# only the image's partition searched) and the boot environment mounted.
# What only the running system can say (drivers compiled into the kernel,
# the console actually on the serial port, logins) is boot-test.py's.
#
# Usage: verify.sh <disk.raw>    (SERIAL_IO, SERIAL_TTY, ADMIN_USER set;
#                                 ROOT_FS ufs (default) or zfs)
# Every check prints its verdict; any failure exits 1.

set -Euo pipefail
DISK=${1:?disk}
SERIAL_IO=${SERIAL_IO:?}
SERIAL_TTY=${SERIAL_TTY:?}
ADMIN_USER=${ADMIN_USER:?}
ROOT_FS=${ROOT_FS:-ufs}

fails=0
check() {  # check <name> <0|1 as status of the test> [detail]
    if [[ "$2" == 0 ]]; then
        printf '  ok   %s%s\n' "$1" "${3:+: $3}"
    else
        printf '  FAIL %s%s\n' "$1" "${3:+: $3}"
        fails=$((fails + 1))
    fi
}
t() { "$@" >/dev/null 2>&1; echo $?; }

# Reading UFS needs the host kernel's ufs module (read-only is enough);
# reading ZFS its zfs module and zpool/zfs.
if [[ "$ROOT_FS" == zfs ]]; then
    { modprobe zfs 2>/dev/null || [[ -d /sys/module/zfs ]]; } && command -v zpool >/dev/null ||
        { echo "verify: this host cannot read ZFS (no zfs module or zpool)"; exit 1; }
else
    modprobe ufs 2>/dev/null || grep -qw ufs /proc/filesystems ||
        { echo "verify: this host cannot read UFS (no ufs module)"; exit 1; }
fi
dev=$(losetup -fP --show -r "$DISK")
mnt=$(mktemp -d)
esp=$(mktemp -d)
pool=
cleanup() {
    umount "$esp" 2>/dev/null
    # Exporting the pool unmounts what is mounted from it.
    if [[ -n "$pool" ]]; then zpool export "$pool"; else umount "$mnt" 2>/dev/null; fi
    losetup -d "$dev"; rmdir "$mnt" "$esp"
}
trap cleanup EXIT

# ---- layout: GPT, the EFI system partition with the removable-media
# loader, the root last (growfs grows it; Ironic's config drive goes after
# it): a UFS file system, or the ZFS pool's partition.
last=$(sfdisk --dump "$dev" | grep "^$dev" | tail -1 | cut -d: -f1 | tr -d ' ')
root_type=$(blkid -s TYPE -o value "$last")
if [[ "$ROOT_FS" == zfs ]]; then
    check "root is the last partition and ZFS" "$([[ "$root_type" == zfs_member ]]; echo $?)" "$last $root_type"
    # Imported read-only, under a name of its own (the build host may have
    # pools, zroot among them), with no cache file, searching only this
    # partition - and without -f: a pool the installer did not export
    # cleanly does not import, and that is a failure.
    name=$(blkid -s LABEL -o value "$last")
    if zpool import -d "$last" -N -o readonly=on -o cachefile=none -R "$mnt" "$name" "fbverify$$"; then
        pool="fbverify$$"
        check "the pool ($name) imports read-only without -f (exported by the installer)" 0
    else
        check "the pool ($name) imports read-only without -f (exported by the installer)" 1; exit 1
    fi
    bootfs=$(zpool get -H -o value bootfs "$pool")
    check "bootfs is the boot environment ROOT/default" "$([[ "$bootfs" == "$pool/ROOT/default" ]]; echo $?)" "${bootfs#"$pool"/}"
    zfs mount "$pool/ROOT/default" || { echo "cannot mount the boot environment"; exit 1; }
    comp=$(zfs get -H -o value compression "$pool")
    check "compression on the pool" "$([[ "$comp" != off ]]; echo $?)" "$comp"
    swapparts=$(sfdisk --dump "$dev" | grep -ci 'type=516E7CB5-6ECF-11D6-8FF8-00022D09712B' || true)
    check "no swap partition" "$([[ "$swapparts" == 0 ]]; echo $?)" "$swapparts"
else
    check "root is the last partition and UFS" "$([[ "$root_type" == ufs ]]; echo $?)" "$last $root_type"
    mount -t ufs -o ro,ufstype=ufs2 "$last" "$mnt" || { echo "cannot mount the root"; exit 1; }
fi
espdev=$(for p in "$dev"p*; do [[ "$(blkid -s TYPE -o value "$p")" == vfat ]] && echo "$p"; done | head -1)
if [[ -n "$espdev" ]] && mount -o ro "$espdev" "$esp"; then
    check "EFI loader on the removable-media path" "$(t test -f "$esp/EFI/BOOT/BOOTX64.EFI")" "$espdev"
else
    check "EFI system partition present" 1
fi

# ---- file systems by label: the build VM's disk is vtbd0, the server's is
# whatever its controller makes it (da0 behind Smart Array).
bad=$(awk '$1 ~ "^/dev/(vtbd|ada|da|nvd|nda|mmcsd)[0-9]" {print $1}' "$mnt/etc/fstab" | tr '\n' ' ')
if [[ "$ROOT_FS" == zfs ]]; then
    # The root is the pool's bootfs, not an fstab line.
    check "fstab by GPT label, no device names, no root line (bootfs)" \
        "$([[ -z "$bad" ]] && ! awk '$2 == "/"' "$mnt/etc/fstab" | grep -q . && grep -q '^/dev/gpt/efiboot0[[:space:]]' "$mnt/etc/fstab"; echo $?)" "${bad:-/dev/gpt/*}"
else
    check "fstab by GPT label, no device names" "$([[ -z "$bad" ]] && grep -q '^/dev/gpt/rootfs[[:space:]]' "$mnt/etc/fstab"; echo $?)" "${bad:-/dev/gpt/*}"
fi

# ---- the local login
hash=$(awk -F: -v u="$ADMIN_USER" '$1 == u {print $2}' "$mnt/etc/master.passwd")
check "local login: $ADMIN_USER has a password (SHA-512)" "$([[ "$hash" == '$6$'* ]]; echo $?)"
check "$ADMIN_USER in wheel" "$(t grep -qE "^wheel:[^:]*:[^:]*:.*\b$ADMIN_USER\b" "$mnt/etc/group")"
root_hash=$(awk -F: '$1 == "root" {print $2}' "$mnt/etc/master.passwd")
check "root locked" "$([[ "$root_hash" == '*' ]]; echo $?)" "${root_hash:0:3}"
check "sudo for wheel" "$(t test -x "$mnt/usr/local/bin/sudo" -a -f "$mnt/usr/local/etc/sudoers.d/wheel")"

# ---- the consoles
lc="$mnt/boot/loader.conf"
check "loader: serial console primary, screen second" \
    "$(grep -qx 'boot_serial="YES"' "$lc" && grep -qx 'boot_multicons="YES"' "$lc"; echo $?)"
check "kernel console on the BMC's port ($SERIAL_IO)" \
    "$(grep -qix "hw.uart.console=\"io:$SERIAL_IO,br:115200\"" "$lc"; echo $?)"
check "loader on the UEFI console (the firmware redirects it; no doubled output)" \
    "$(grep -qx 'console="efi"' "$lc"; echo $?)"
delay=$(sed -n 's/^autoboot_delay="\{0,1\}\(-\{0,1\}[0-9]*\)"\{0,1\}$/\1/p' "$lc" | tail -1)
check "loader menu waits" "$([[ -n "$delay" && "$delay" -ge 3 ]]; echo $?)" "autoboot_delay=$delay"
check "no muted boot" "$(! grep -qE '^boot_mute="?YES' "$lc"; echo $?)"
check "getty on $SERIAL_TTY" "$(grep -qE "^$SERIAL_TTY[[:space:]].*[[:space:]]on([[:space:]]|$)" "$mnt/etc/ttys"; echo $?)"

# ---- drivers: present as modules (whether they are compiled into the
# kernel is boot-test.py's: kldstat on the running system)
k="$mnt/boot/kernel"
for m in ahci smartpqi ciss mrsas mpr mps nvme ukbd hkbd if_bxe if_bge if_ixl if_ice mlx5en; do
    [[ -f "$k/$m.ko" ]] || missing="${missing:-} $m"
done
check "storage, keyboard and NIC drivers present" "$([[ -z "${missing:-}" ]]; echo $?)" "${missing:-all}"
check "NIC firmware module (ice DDP)" "$(t test -f "$k/ice_ddp.ko")"

# ---- first boot: nuageinit (with the bare-metal network renderer),
# growfs, the default-password fix, dhcpcd for DHCP (v4 and v6)
rc="$mnt/etc/rc.conf"
# rc.conf values with or without quotes.
rcset() { grep -qE "^$1=\"?$2\"?\$" "$rc"; }
check "nuageinit and growfs enabled, growfs adds no swap" \
    "$(rcset nuageinit_enable YES && rcset growfs_enable YES && rcset growfs_swap_size 0; echo $?)"
check "nuageinit bare-metal start (rc.conf.d/nuageinit + nuageinit-netdata)" \
    "$(t test -f "$mnt/etc/rc.conf.d/nuageinit" -a -x "$mnt/usr/local/libexec/nuageinit-netdata")"
check "nuageinit_default_password installed" "$(t test -x "$mnt/usr/local/etc/rc.d/nuageinit_default_password")"
check "dhcpcd with EUI-64 SLAAC, no IPv4LL" \
    "$(test -x "$mnt/usr/local/sbin/dhcpcd" && grep -q '^slaac hwaddr' "$mnt/usr/local/etc/dhcpcd.conf" \
       && grep -q '^noipv4ll' "$mnt/usr/local/etc/dhcpcd.conf"; echo $?)"
# The package's licence directory carries its version; 10.3.x dies when an
# IPv4 address it manages is deleted from outside.
dhcpcd_v=$(ls -d "$mnt"/usr/local/share/licenses/dhcpcd-* 2>/dev/null | sed 's|.*/dhcpcd-||' | head -1)
check "dhcpcd 10.5.2 or later" \
    "$([[ -n "$dhcpcd_v" && "$(printf '%s\n' 10.5.2 "$dhcpcd_v" | sort -V | head -1)" == 10.5.2 ]]; echo $?)" "${dhcpcd_v:-none}"
check "dhcpcd is the only DHCP client (rc.d/dhclient redirected, dhcpcd-rc, synchronous_dhclient, MTU hook)" \
    "$(test -x "$mnt/usr/local/libexec/dhcpcd-rc" && grep -q 'dhcpcd-rc ipv4-start' "$mnt/usr/local/etc/rc.conf.d/dhclient" \
       && grep -q '^dhcpcd_enable="YES"' "$mnt/usr/local/etc/rc.conf.d/dhcpcd" && rcset synchronous_dhclient YES \
       && grep -q 'ifconfig "$interface" mtu' "$mnt/usr/local/libexec/dhcpcd-hooks/10-mtu"; echo $?)"
check "sshd enabled" "$(rcset sshd_enable YES; echo $?)"
if [[ "$ROOT_FS" == zfs ]]; then
    check "ZFS loaded and enabled" \
        "$(grep -qE '^zfs_load="?YES' "$lc" && rcset zfs_enable YES; echo $?)"
    check "first boot gives the root pool its own GUID (zpool_reguid)" \
        "$(test -x "$mnt/usr/local/etc/rc.d/zpool_reguid" && rcset zpool_reguid_enable YES; echo $?)"
    check "growfs first clears stale labels where the pool will grow to (zfs-growfs-prepare)" \
        "$(test -x "$mnt/usr/local/libexec/zfs-growfs-prepare" && grep -q 'start_precmd="zfs_growfs_prepare"' "$mnt/usr/local/etc/rc.conf.d/growfs"; echo $?)"
fi

# ---- template identity
check "first-boot sentinel present" "$(t test -e "$mnt/firstboot")"
keys=$(ls "$mnt"/etc/ssh/ssh_host_* 2>/dev/null | wc -l)
check "no SSH host keys" "$([[ "$keys" == 0 ]]; echo $?)" "$keys"
check "no hostid" "$(t test ! -e "$mnt/etc/hostid")"
check "no hypervisor guest agent" \
    "$(t test ! -e "$mnt/usr/local/bin/qemu-ga" -a ! -e "$mnt/usr/local/bin/vmtoolsd")"

(( fails == 0 )) && echo "verify: all checks passed" || echo "verify: $fails check(s) failed"
exit $(( fails > 0 ))
