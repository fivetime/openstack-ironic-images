#!/usr/bin/env bash
# Shared helpers: logging, requirement checks and a cleanup registry.
#
# Source this first; every other lib/ module assumes it is loaded.
# shellcheck shell=bash

[[ -n "${_LIB_COMMON_SH:-}" ]] && return 0
_LIB_COMMON_SH=1

LIB_DIR=${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
REPO_DIR=${REPO_DIR:-$(cd -- "$LIB_DIR/.." && pwd)}

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf '%s\n' "$*" >&2; exit 1; }

# require_cmd curl jq ...
require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || die "missing required command: $cmd"
    done
}

require_root() {
    [[ $EUID -eq 0 ]] || die "run as root"
}

# Cleanup registry. Handlers run in reverse registration order (LIFO) so
# nested resources unwind correctly: mounts before the loop device that
# carries them. Each handler must be idempotent; a handler that fails
# does not stop the remaining ones, it only propagates a non-zero exit.
_CLEANUP_STACK=()

on_cleanup() {
    _CLEANUP_STACK+=("$1")
}

run_cleanup() {
    local status=$? i
    for ((i = ${#_CLEANUP_STACK[@]} - 1; i >= 0; i--)); do
        eval "${_CLEANUP_STACK[i]}" || status=$?
    done
    _CLEANUP_STACK=()
    return "$status"
}

# install_cleanup_traps installs the EXIT/INT/TERM traps used by every
# build script. Call it once, after sourcing, before allocating anything.
install_cleanup_traps() {
    trap 'run_cleanup; exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# make_work_dir <var> [template] creates a temp dir, stores its path in the
# named variable and removes it on exit.
#
# The result is returned through a variable, not on stdout, on purpose: a
# helper called as $(...) runs in a subshell, and a cleanup handler it
# registers there never reaches the shell whose EXIT trap runs the stack.
# That is how every build used to leak its work directory.
make_work_dir() {
    local -n _mwd_out=$1
    local dir
    dir=$(mktemp -d "${2:-/tmp/build.XXXXXXXX}")
    on_cleanup "rm -rf -- '$dir'"
    _mwd_out=$dir
}
