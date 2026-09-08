#!/usr/bin/env bash
# Retry a command with exponential backoff.
#
# Every remote call in this repo is a network call to something we do not
# control: the upstream image server, the GitHub API, a distro mirror. A
# single timeout should cost a few seconds, not a whole build and a manual
# re-run. The pacman branch in chroot-pkg.sh has carried its own retry
# loop since Arch mirrors started timing out; this generalises it.
# shellcheck shell=bash

[[ -n "${_LIB_RETRY_SH:-}" ]] && return 0
_LIB_RETRY_SH=1

RETRY_ATTEMPTS=${RETRY_ATTEMPTS:-3}
RETRY_DELAY=${RETRY_DELAY:-15}

# retry <command> [args...]
retry() {
    local attempt=1 delay=$RETRY_DELAY
    while true; do
        if "$@"; then
            ((attempt > 1)) && log "succeeded on attempt $attempt"
            return 0
        fi
        if ((attempt >= RETRY_ATTEMPTS)); then
            warn "giving up after $attempt attempts: $*"
            return 1
        fi
        warn "attempt $attempt/$RETRY_ATTEMPTS failed, retrying in ${delay}s: $*"
        sleep "$delay"
        ((attempt++))
        delay=$((delay * 2))
    done
}
