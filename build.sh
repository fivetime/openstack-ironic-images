#!/usr/bin/env bash
# Single entry point: resolve an image declaration, then run its pipeline.
#
#   ./build.sh <image> [variant] [--layer kubernetes=<version>]
#   ./build.sh --list
#
# <image> is a directory under images/. The declaration says which pipeline
# builds it and with what parameters; this script turns that into the
# environment the pipeline expects and execs it. Pipelines stay runnable on
# their own, so nothing here is load-bearing for CI.
#
# --layer adds a layer from layers/ on top of the installed base image; the
# result is a separate image named <image>-v<version>, and the base image is
# kept (built first if it is not in dist/ already). One layer for now.

set -Eeuo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit "${1:-0}"
}

[[ $# -ge 1 ]] || usage 1
if [[ "$1" == --list ]]; then
    for d in "$REPO_DIR"/images/*/image.yaml; do
        [[ -f "$d" ]] || continue
        printf '%s\n' "$(basename "$(dirname "$d")")"
    done
    exit 0
fi
[[ "$1" == -h || "$1" == --help ]] && usage

IMAGE=$1; shift
VARIANT=
LAYER_KUBERNETES=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --layer)
            [[ "${2:-}" == kubernetes=* ]] || die "--layer takes kubernetes=<version>"
            LAYER_KUBERNETES=${2#kubernetes=}
            [[ "$LAYER_KUBERNETES" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a Kubernetes version: $LAYER_KUBERNETES"
            shift 2 ;;
        --layer=kubernetes=*) LAYER_KUBERNETES=${1#--layer=kubernetes=}; shift ;;
        -*) die "unknown option: $1" ;;
        *) [[ -z "$VARIANT" ]] || die "unexpected argument: $1"; VARIANT=$1; shift ;;
    esac
done
DECL="$REPO_DIR/images/$IMAGE/image.yaml"
[[ -f "$DECL" ]] || die "no such image declaration: $DECL"

require_cmd python3

# Flatten the declaration into KEY=VALUE lines: defaults first, then the
# selected variant on top. A declaration with no variants is one image.
if ! resolved=$(python3 - "$DECL" "$VARIANT" <<'PY'
import os, sys, shlex
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml is required to read image declarations")

decl_path, variant = sys.argv[1], sys.argv[2]
with open(decl_path) as fh:
    decl = yaml.safe_load(fh) or {}

pipeline = decl.get("pipeline")
if not pipeline:
    sys.exit(f"{decl_path}: no pipeline declared")

merged = {k: v for k, v in decl.items() if k not in ("variants", "glance")}
merged.update(decl.get("defaults") or {})

# A variant matrix exists for one reason so far: the same distro on
# machines whose BMC puts the serial console on a different port.
entries = decl.get("variants") or {}
if entries:
    if not variant or variant not in entries:
        names = " ".join(sorted(entries))
        sys.exit(f"{decl_path}: pick one of: {names}")
    entry = entries[variant] or {}
    if entry.get("enabled") is False and os.environ.get("ALLOW_DISABLED_VARIANT") != "1":
        sys.exit(f"variant {variant!r} is disabled in {decl_path} "
                 f"(set ALLOW_DISABLED_VARIANT=1 to build it anyway)")
    merged.update({k: v for k, v in entry.items() if k != "glance"})

out = {"PIPELINE": pipeline}
mapping = {
    "target": "TARGET",
    "installer": "INSTALLER",
    "disk_size": "DISK_SIZE",
    "output_format": "OUTPUT_FORMAT",
    "admin_user": "ADMIN_USER",
    "serial_console": "SERIAL_CONSOLE",
}
for key, env in mapping.items():
    if key in merged and not isinstance(merged[key], (dict, list)):
        out[env] = str(merged[key])

src = merged.get("source")
if isinstance(src, dict) and "iso" in src:
    out["SOURCE_ISO"] = str(src["iso"])
else:
    sys.exit(f"{decl_path}: source.iso is required (an artifact in upstream/sources.yaml)")

name = decl_path.split("/")[-2]
if variant:
    name = f"{name}-{variant}"
out["IMAGE_NAME"] = name

for k, v in out.items():
    print(f"export {k}={shlex.quote(v)}")
PY
); then
    exit 1
fi
eval "$resolved"

PIPELINE_DIR="$REPO_DIR/pipelines/$PIPELINE"
[[ -d "$PIPELINE_DIR" ]] || die "no such pipeline: $PIPELINE_DIR"

export OUTPUT_DIR=${OUTPUT_DIR:-$REPO_DIR/dist}
export IMAGE_DIR="$REPO_DIR/images/$IMAGE"
mkdir -p "$OUTPUT_DIR"

# With a layer, the pipeline builds (or reuses) the base image under its
# own name and produces the layered one under the suffixed name.
export BASE_IMAGE_NAME=$IMAGE_NAME
export LAYER_KUBERNETES
if [[ -n "$LAYER_KUBERNETES" ]]; then
    [[ -d "$REPO_DIR/layers/kubernetes/lock/$LAYER_KUBERNETES" ]] || \
        die "no lock for Kubernetes $LAYER_KUBERNETES (layers/kubernetes/resolve.sh, then resolve-packages.sh)"
    export IMAGE_NAME="${IMAGE_NAME}-v${LAYER_KUBERNETES}"
fi

log "image=$IMAGE variant=${VARIANT:-none} pipeline=$PIPELINE layer=${LAYER_KUBERNETES:+kubernetes=$LAYER_KUBERNETES}"
log "name=$IMAGE_NAME output=$OUTPUT_DIR"
exec bash "$PIPELINE_DIR/build.sh"
