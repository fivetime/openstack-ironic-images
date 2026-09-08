#!/usr/bin/env bash
# Build manifests.
#
# One manifest per image, written next to the artifacts in the dist dir.
# It is the contract between the build stage and the upload stage: the
# uploader never guesses a file name or a capability, it reads them here.
# shellcheck shell=bash

[[ -n "${_LIB_MANIFEST_SH:-}" ]] && return 0
_LIB_MANIFEST_SH=1

manifest_path() {
    printf '%s/%s.manifest.json\n' "$1" "$2"
}

# manifest_write <dist-dir> <name> <json-object>
#
# The object is merged over the provenance fields every pipeline records,
# so a caller only passes what is specific to it.
manifest_write() {
    local dist=$1 name=$2 extra=${3:-'{}'}
    require_cmd jq
    local out
    out=$(manifest_path "$dist" "$name")
    jq -n \
        --arg name "$name" \
        --arg source "${SOURCE:-}" \
        --arg fingerprint "${INCUS_SOURCE_FINGERPRINT:-}" \
        --arg serial "${INCUS_SOURCE_SERIAL:-}" \
        --argjson extra "$extra" \
        '{name: $name, source_alias: $source,
          source_fingerprint: $fingerprint, source_serial: $serial}
         + $extra' >"$out"
    printf '%s\n' "$out"
}

# manifest_merge <dist-dir> <name> <json-object>
# Add fields to an existing manifest; a later stage augments an earlier one.
manifest_merge() {
    local dist=$1 name=$2 extra=$3
    require_cmd jq
    local out
    out=$(manifest_path "$dist" "$name")
    [[ -f "$out" ]] || die "no manifest to merge into: $out"
    jq --argjson extra "$extra" '. + $extra' "$out" >"$out.tmp"
    mv "$out.tmp" "$out"
}
