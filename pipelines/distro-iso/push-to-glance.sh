#!/usr/bin/env bash
# Upload built bare-metal disks to Glance. Run wherever the Glance
# endpoint is reachable.
#
# Usage: push-to-glance.sh <dist-dir> [image ...]
#
# With no image names every manifest in the dist directory is uploaded.
# Each image's properties come from its own declaration, found by name:
# dist/<name>.manifest.json is uploaded with images/<name>/image.yaml.
# Taking one declaration on the command line and applying it to whatever
# manifests happen to be in the directory is how a Rocky disk ends up in
# Glance labelled os_distro=ubuntu.
#
# Note what these records deliberately do NOT set: hypervisor_type. They
# are for Ironic, and standalone Ironic does not consult the Nova
# scheduler; a Nova-driven baremetal flavor uses the same record. Put
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

DIST_DIR=${1:?Usage: push-to-glance.sh <dist-dir> [image ...]}
shift || true
WANTED=("$@")

glance_check_env
require_cmd python3 jq

# declaration_props <image-declaration> -> KEY=VALUE lines
declaration_props() {
    python3 - "$1" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml is required to read image declarations")
with open(sys.argv[1]) as fh:
    decl = yaml.safe_load(fh) or {}
props = (decl.get("glance") or {}).get("properties") or {}
props = props or ((decl.get("defaults") or {}).get("glance") or {}).get("properties") or {}
if not props:
    sys.exit(f"{sys.argv[1]}: no glance.properties")
for k, v in props.items():
    print(f"{k}={v}")
PY
}

pushed=0
while read -r manifest; do
    name=$(jq -r '.name' "$manifest")
    if ((${#WANTED[@]})); then
        skip=1
        for w in "${WANTED[@]}"; do [[ "$w" == "$name" ]] && skip=; done
        [[ -n "$skip" ]] && continue
    fi

    decl="$REPO_DIR/images/$name/image.yaml"
    [[ -f "$decl" ]] || die "$manifest names $name, but there is no $decl"

    mapfile -t decl_props < <(declaration_props "$decl")
    ((${#decl_props[@]})) || die "$decl: no glance.properties"

    props=()
    for kv in "${decl_props[@]}"; do
        [[ "$kv" == hypervisor_type=* ]] && \
            die "$decl declares $kv; a bare-metal image must not (see the header)"
        props+=(--property "$kv")
    done

    disk=$(jq -r '.disk' "$manifest")
    disk_format=$(jq -r '.disk_format // "raw"' "$manifest")
    serial=$(jq -r '.serial_console // "?"' "$manifest")
    user=$(jq -r '.admin_user // "?"' "$manifest")

    log "== $name (console=$serial admin=$user) =="
    glance_upload "$name$NAME_SUFFIX" "$DIST_DIR/$disk" "$disk_format" \
        "${props[@]}"
    pushed=$((pushed + 1))
done < <(glance_manifests "$DIST_DIR")

((pushed)) || die "nothing matched: ${WANTED[*]:-<all>}"
log "uploaded $pushed image(s)"
