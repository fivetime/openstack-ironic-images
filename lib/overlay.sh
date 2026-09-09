#!/usr/bin/env bash
# A writable view of a finished disk image that leaves the image untouched:
# a qcow2 overlay on top of the raw, attached through qemu-nbd. Package
# resolution needs to run a package manager inside the installed system,
# and that writes to it; the alternative - copying a 12 GB raw first - is
# what this avoids.
# shellcheck shell=bash

[[ -n "${_LIB_OVERLAY_SH:-}" ]] && return 0
_LIB_OVERLAY_SH=1

# overlay_attach <var> <raw> <overlay-file> [mount-root] — attaches, stores
# the nbd device in the named variable, detaches on exit. The overlay file
# is created fresh (an old one would carry an old session's writes).
#
# mount-root names the directory the caller will mount the device under.
# Disconnecting an nbd device that is still mounted does not fail - it
# turns the mount into I/O errors - and a mount that is still busy (a
# package manager that has not exited, a lazily unmounted bind) makes the
# ordinary unmount handler give up silently. So the detach handler first
# kills what holds the tree, unmounts it recursively, and only then lets go
# of the device.
overlay_attach() {
    local -n _oa_out=$1
    local raw=$2 ovl=$3 mroot=${4:-} dev i
    require_cmd qemu-img qemu-nbd
    modprobe nbd max_part=16 2>/dev/null || true
    rm -f "$ovl"
    qemu-img create -q -f qcow2 -b "$(realpath "$raw")" -F raw "$ovl"
    for i in $(seq 0 15); do
        dev=/dev/nbd$i
        [[ -b "$dev" ]] || continue
        # An nbd device with a size is in use.
        [[ "$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)" == 0 ]] || continue
        if qemu-nbd -c "$dev" "$ovl" 2>/dev/null; then
            on_cleanup "overlay_detach '$dev' '$mroot'"
            partprobe "$dev" 2>/dev/null || true
            udevadm settle 2>/dev/null || sleep 1
            _oa_out=$dev
            return 0
        fi
    done
    die "no free nbd device for $ovl"
}

# chroot_prepare <rootfs> — the API mounts a package manager and an
# installer need; all unmounted on exit, innermost first.
chroot_prepare() {
    local root=$1 d
    for d in proc sys dev dev/pts; do
        mount --bind "/$d" "$root/$d"
        on_cleanup "mountpoint -q '$root/$d' && umount -l '$root/$d' || true"
    done
    # The image's resolv.conf is whatever the installer left; the chroot
    # needs this host's. Restored on exit so the image keeps its own.
    if [[ -e "$root/etc/resolv.conf" || -L "$root/etc/resolv.conf" ]]; then
        cp -a "$root/etc/resolv.conf" "$root/etc/resolv.conf.chroot-saved"
        on_cleanup "mv -f '$root/etc/resolv.conf.chroot-saved' '$root/etc/resolv.conf' 2>/dev/null || true"
    fi
    rm -f "$root/etc/resolv.conf"
    cp /etc/resolv.conf "$root/etc/resolv.conf"
}


# overlay_detach <dev> [mount-root] — see overlay_attach.
overlay_detach() {
    local dev=$1 mroot=${2:-}
    if [[ -n "$mroot" ]] && mountpoint -q "$mroot" 2>/dev/null; then
        fuser -k -m "$mroot" 2>/dev/null || true
        sleep 1
        umount -R "$mroot" 2>/dev/null || umount -R -l "$mroot" 2>/dev/null || true
    fi
    sync
    qemu-nbd -d "$dev" >/dev/null 2>&1 || { sleep 1; qemu-nbd -d "$dev" >/dev/null 2>&1; } || true
}
