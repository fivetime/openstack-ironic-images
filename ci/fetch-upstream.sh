#!/usr/bin/env bash
# Fetch upstream artifacts listed in upstream/sources.yaml into the cache,
# verifying each against its recorded sha256.
#
#   ci/fetch-upstream.sh <artifact> [artifact...]
#
# A cached file whose checksum matches is left alone; anything else is
# downloaded again. The checksum in sources.yaml is the contract: a URL
# that starts serving different bytes fails the build instead of quietly
# changing what goes into an image.
#
# Environment:
#   CACHE_DIR   where the files go (default upstream/cache)

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/retry.sh
source "$LIB_DIR/retry.sh"

CACHE_DIR=${CACHE_DIR:-$REPO_DIR/upstream/cache}
SOURCES="$REPO_DIR/upstream/sources.yaml"

[[ $# -ge 1 ]] || die "usage: fetch-upstream.sh <artifact> [artifact...] (names from $SOURCES)"
require_cmd curl sha256sum python3
mkdir -p "$CACHE_DIR"

# artifact_field <artifact> <field>
artifact_field() {
    python3 - "$SOURCES" "$1" "$2" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml is required to read upstream/sources.yaml")
path, name, field = sys.argv[1:4]
with open(path) as fh:
    doc = yaml.safe_load(fh) or {}
entry = (doc.get("artifacts") or {}).get(name)
if entry is None:
    sys.exit(f"{path}: no artifact named {name!r}")
value = entry.get(field)
if value in (None, ""):
    sys.exit(f"{path}: artifact {name!r} has no {field!r}")
print(value)
PY
}

checksum_ok() {
    local file=$1 want=$2
    [[ -f "$file" ]] || return 1
    echo "$want  $file" | sha256sum -c --quiet - >/dev/null 2>&1
}

for name in "$@"; do
    url=$(artifact_field "$name" url)
    filename=$(artifact_field "$name" filename)
    sha=$(artifact_field "$name" sha256)
    dest="$CACHE_DIR/$filename"

    if checksum_ok "$dest" "$sha"; then
        log "== $name: cached and verified ($filename)"
        continue
    fi

    log "== $name: fetching $url"
    tmp="$dest.part"
    # -C - resumes a partial file across retries; the eval ISO is 6 GB.
    retry curl -fL --retry 5 --retry-all-errors -C - -o "$tmp" "$url"
    if ! checksum_ok "$tmp" "$sha"; then
        got=$(sha256sum "$tmp" | cut -d' ' -f1)
        rm -f "$tmp"
        die "$name: checksum mismatch (expected $sha, got $got); upstream changed or download corrupt"
    fi
    mv "$tmp" "$dest"
    log "   ok: $dest"
done
