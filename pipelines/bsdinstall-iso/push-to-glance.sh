#!/usr/bin/env bash
# Upload FreeBSD bare-metal disks to Glance: the same upload as distro-iso's
# (manifest + the image's own declaration, no hypervisor_type), which does
# not depend on the installer that made the disk.
#
# Usage: push-to-glance.sh <dist-dir> [image ...]    Environment: lib/glance.sh
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/../distro-iso/push-to-glance.sh" "$@"
