#!/usr/bin/env bash
# Glance upload.
#
# One uploader for every pipeline. What differs between them (disk format,
# properties) is passed in; how an image reaches a specific store, and how
# we prove it got there, is the same everywhere and lives here.
#
# Environment:
#   OS_* / OS_CLOUD       standard OpenStack auth (or a sourced openrc)
#   VISIBILITY            public|private|shared|community (default public)
#   IMAGE_STORE           Glance store to place images in. Unset means
#                         whatever default_backend is (rbd here), which is
#                         usually right but unverified; naming the store
#                         makes the upload assert where the image landed.
#   IMAGE_IMPORT_TIMEOUT  seconds to wait for the store copy (default 600)
#   NAME_SUFFIX           optional suffix appended to Glance image names
# shellcheck shell=bash

[[ -n "${_LIB_GLANCE_SH:-}" ]] && return 0
_LIB_GLANCE_SH=1

VISIBILITY=${VISIBILITY:-public}
IMAGE_STORE=${IMAGE_STORE:-}
IMAGE_IMPORT_TIMEOUT=${IMAGE_IMPORT_TIMEOUT:-600}
NAME_SUFFIX=${NAME_SUFFIX:-}

glance_check_env() {
    require_cmd openstack jq
    # An OS_CLOUD set to the empty string is worse than unset: the client
    # looks for a cloud literally named "" instead of falling back to the
    # OS_* variables. CI passes the secret unconditionally, so it can be
    # empty whenever clouds.yaml is not the chosen auth path.
    if [[ -z "${OS_CLOUD:-}" ]]; then
        unset OS_CLOUD
    fi
    [[ -n "${OS_CLOUD:-}" || -n "${OS_AUTH_URL:-}" ]] || \
        die "Set OS_CLOUD or OS_AUTH_URL for OpenStack authentication"
    if [[ -n "$IMAGE_STORE" ]]; then
        [[ "$IMAGE_STORE" =~ ^[A-Za-z0-9._-]+$ ]] || \
            die "IMAGE_STORE contains unsupported characters"
    fi
}

# glance_upload <name> <file> <disk-format> [--property k=v ...]
#
# Uploads one file as one Glance image, optionally routing it into an
# explicit store through the interoperable import API.
glance_upload() {
    local name=$1 file=$2 disk_format=$3
    shift 3
    local props=("$@")

    # Remember the image this one replaces, but do not delete it yet: a
    # failed upload must leave the working image in place rather than the
    # project with nothing at all.
    local old_id
    old_id=$(openstack image show "$name" -f value -c id 2>/dev/null || true)

    local image_id
    if [[ -z "$IMAGE_STORE" ]]; then
        # Not necessarily wrong: the image lands in Glance's default_backend,
        # which is rbd here. But then nothing checks where it went, so a
        # later change to that default would silently move every image.
        warn "IMAGE_STORE is unset: landing in Glance's default backend, unverified"
        image_id=$(openstack image create "$name" \
            --disk-format "$disk_format" --container-format bare \
            "--$VISIBILITY" "${props[@]}" --file "$file" -f value -c id)
        openstack image show "$image_id" -c id -c name -c status -c size
        glance_retire_old "$old_id" "$image_id"
        return
    fi

    # Create private first: an image must not be visible to tenants until
    # it actually sits in the store that makes it cheap to boot.
    image_id=$(openstack image create "$name" \
        --disk-format "$disk_format" --container-format bare \
        --private "${props[@]}" --file "$file" -f value -c id)
    openstack image import --method copy-image --store "$IMAGE_STORE" \
        --wait "$image_id"

    # The --wait above is insufficient for an already-active copy-image
    # source; poll the store list until the requested store appears.
    local deadline=$((SECONDS + IMAGE_IMPORT_TIMEOUT)) stores=
    while ((SECONDS < deadline)); do
        stores=$(openstack image show "$image_id" -f json | \
            jq -r '.properties.stores // ""')
        [[ ",$stores," == *",$IMAGE_STORE,"* ]] && break
        sleep 5
    done
    [[ ",$stores," == *",$IMAGE_STORE,"* ]] || {
        warn "Image $name was not copied to store $IMAGE_STORE"
        openstack image delete "$image_id" >/dev/null 2>&1 || true
        exit 1
    }

    local store
    for store in ${stores//,/ }; do
        if [[ "$store" != "$IMAGE_STORE" ]]; then
            openstack image delete --store "$store" "$image_id"
        fi
    done
    openstack image set "--$VISIBILITY" "$image_id"
    openstack image show "$image_id" -c id -c name -c status -c size -c properties
    glance_retire_old "$old_id" "$image_id"
}

# glance_retire_old <old-id> <new-id>
#
# Only now is the new image safe to keep, so retire the one it replaces.
# An image that is still a CoW parent of live volumes cannot be deleted,
# and that is expected rather than an error.
glance_retire_old() {
    local old_id=$1 new_id=$2
    [[ -n "$old_id" && "$old_id" != "$new_id" ]] || return 0
    if openstack image delete "$old_id" >/dev/null 2>&1; then
        log "  retired previous image $old_id"
    else
        warn "  previous image $old_id kept (in use by clones)"
    fi
}

# glance_manifests <dist-dir> — echo every manifest, fail when there are none.
glance_manifests() {
    local dist=$1
    shopt -s nullglob
    local manifests=("$dist"/*.manifest.json)
    ((${#manifests[@]})) || die "no manifests in $dist"
    printf '%s\n' "${manifests[@]}"
}
