#!/usr/bin/env bash
# Loop-device and filesystem helpers shared by the disk-writing pipelines.
# shellcheck shell=bash

[[ -n "${_LIB_DISK_SH:-}" ]] && return 0
_LIB_DISK_SH=1

# disk_attach <var> <file> [-P] attaches a loop device, stores its path in
# the named variable and detaches it on exit. Returned through a variable
# rather than stdout so the cleanup handler lands in the caller's shell
# (see make_work_dir in common.sh).
disk_attach() {
    local -n _da_out=$1
    local file=$2 partscan=${3:-}
    local dev
    if [[ "$partscan" == "-P" ]]; then
        dev=$(losetup --find --show -P "$file")
    else
        dev=$(losetup --find --show "$file")
    fi
    # udev can still hold the device for a moment after the last unmount,
    # and a first detach that quietly fails leaves the loop attached to a
    # finished image. Give it one retry before giving up.
    on_cleanup "losetup -d '$dev' 2>/dev/null || { sleep 1; losetup -d '$dev' 2>/dev/null; } || true"
    _da_out=$dev
}

# disk_mount <device> <dir> [opts] — mounted, unmounted on exit.
disk_mount() {
    local dev=$1 dir=$2 opts=${3:-}
    mkdir -p "$dir"
    if [[ -n "$opts" ]]; then
        mount -o "$opts" "$dev" "$dir"
    else
        mount "$dev" "$dir"
    fi
    on_cleanup "mountpoint -q '$dir' && umount '$dir' || true"
}

# disk_find_root_partition <loopdev> <probe-dir> -> echoes the partition
#
# The distrobuilder layout is an ESP (vfat) plus a Linux root filesystem;
# probe the non-vfat partitions for /sbin/init. Leaves the winning
# partition mounted on <probe-dir>.
# An optional third argument gives the mount options; a stage that only
# reads should pass "ro". A left-over read-write mount is not harmless:
# when a stage dies with the image still mounted and the loop device is
# then forced away, the filesystem can come back empty (seen 2026-09-08 -
# a finished 4 GB install left with 11 inodes).
disk_find_root_partition() {
    local loop=$1 dir=$2 opts=${3:-} part fstype
    mkdir -p "$dir"
    for part in "$loop"p*; do
        [[ -b "$part" ]] || continue
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
        case "$fstype" in
            ext4|xfs|btrfs) ;;
            *) continue ;;
        esac
        if [[ -n "$opts" ]]; then
            mount -o "$opts" "$part" "$dir"
        else
            mount "$part" "$dir"
        fi
        if [[ -x "$dir/sbin/init" || -L "$dir/sbin/init" ]]; then
            on_cleanup "mountpoint -q '$dir' && umount '$dir' || true"
            printf '%s\n' "$part"
            return 0
        fi
        umount "$dir"
    done
    return 1
}

# disk_release <dir> — flush and force-unmount a rootfs that package
# managers may still hold open.
disk_release() {
    local dir=$1
    sync
    fuser -k -m "$dir" 2>/dev/null || true
    sleep 1
    if mountpoint -q "$dir"; then
        umount "$dir"
    fi
}
