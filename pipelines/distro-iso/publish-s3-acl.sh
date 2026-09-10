#!/usr/bin/env bash
# Make Glance-owned S3 objects anonymously readable, by image id.
#
#   publish-s3-acl.sh <image-id> [<image-id> ...]
#
# push-to-glance.sh already does this for the images it uploads. This is
# for the ones that were pushed before, or whose ACL needs putting back.
# The mechanism, and why it is per object rather than per bucket, is in
# lib/s3.sh; the environment it needs is documented there too.
set -Eeuo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=../../lib/s3.sh
source "$REPO_DIR/lib/s3.sh"

[[ $# -ge 1 ]] || die "usage: publish-s3-acl.sh <image-id> [...]"
for image_id in "$@"; do
    [[ "$image_id" =~ ^[0-9a-fA-F-]{36}$ ]] || die "not an image id: $image_id"
done
s3_public_read "$@"
