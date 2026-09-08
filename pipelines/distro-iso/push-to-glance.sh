#!/usr/bin/env bash
# Upload built bare-metal disks to Glance. Run wherever the Glance
# endpoint is reachable.
#
# Usage: push-to-glance.sh <dist-dir> <image-declaration>
#
# The properties come from the declaration, so they live next to the
# image they describe. Note what is deliberately NOT set: hypervisor_type.
# These images are for Ironic, and standalone Ironic does not consult the
# Nova scheduler; a Nova-driven baremetal flavor uses the same record. Put
# hypervisor_type on one of these and ImagePropertiesFilter will keep it
# away from the only nodes that can use it.
#
# Environment: see lib/glance.sh.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source=../../lib/glance.sh
source "$LIB_DIR/glance.sh"

DIST_DIR=${1:?Usage: push-to-glance.sh <dist-dir> <image-declaration>}
DECL=${2:?Usage: push-to-glance.sh <dist-dir> <image-declaration>}

glance_check_env
require_cmd python3 jq
[[ -f "$DECL" ]] || die "no such image declaration: $DECL"

mapfile -t decl_props < <(python3 - "$DECL" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml is required to read image declarations")
with open(sys.argv[1]) as fh:
    decl = yaml.safe_load(fh) or {}
# Either shape: a top-level glance block, or one under defaults.
props = (decl.get("glance") or {}).get("properties") or {}
props = props or ((decl.get("defaults") or {}).get("glance") or {}).get("properties") or {}
for k, v in props.items():
    print(f"{k}={v}")
PY
)
((${#decl_props[@]})) || die "$DECL: no glance.properties"

for kv in "${decl_props[@]}"; do
    [[ "$kv" == hypervisor_type=* ]] && \
        die "$DECL declares $kv; a baremetal image must not (see the header)"
done

while read -r manifest; do
    name=$(jq -r '.name' "$manifest")
    disk=$(jq -r '.disk' "$manifest")
    disk_format=$(jq -r '.disk_format // "raw"' "$manifest")
    target=$(jq -r '.target // "baremetal"' "$manifest")
    serial=$(jq -r '.serial_console // "?"' "$manifest")
    user=$(jq -r '.admin_user // "?"' "$manifest")

    props=()
    for kv in "${decl_props[@]}"; do
        props+=(--property "$kv")
    done

    log "== $name (target=$target console=$serial admin=$user) =="
    glance_upload "$name$NAME_SUFFIX" "$DIST_DIR/$disk" "$disk_format" \
        "${props[@]}"
done < <(glance_manifests "$DIST_DIR")
