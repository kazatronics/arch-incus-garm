#!/bin/bash
# Shared helpers for incus-garm setup steps. Sourced, never executed.

set -euo pipefail

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_root() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo)"
    # makepkg refuses to run as root; we drop to the invoking user for AUR builds
    [[ -n ${SUDO_USER:-} ]] || die "run via sudo from a regular user, not a root login"
}

load_config() {
    local cfg="$REPO_ROOT/config.env"
    [[ -f $cfg ]] || die "config.env not found — cp config.env.example config.env and edit it"
    # shellcheck source=/dev/null
    source "$cfg"
    # Upgrade-safe defaults for the multi-host vars added after a config.env may
    # already exist — an older config.env predating them would otherwise trip
    # `set -u` ("HOST_ROLE: unbound variable"). Only the new vars get defaults.
    HOST_ROLE="${HOST_ROLE:-controller}"
    GARM_CLIENT_CERT="${GARM_CLIENT_CERT:-/etc/garm/incus-client.crt}"
    GARM_CLIENT_KEY="${GARM_CLIENT_KEY:-/etc/garm/incus-client.key}"
    REMOTE_HOSTS="${REMOTE_HOSTS:-}"
    INCUS_HTTPS_ADDRESS="${INCUS_HTTPS_ADDRESS:-[::]:8443}"
    CONTROLLER_CLIENT_CERT="${CONTROLLER_CLIENT_CERT:-/root/incus-client.crt}"
}

# incus_missing <kind> <name> — true if the object doesn't exist yet
incus_missing() { ! incus "$1" show "$2" &>/dev/null; }

as_user() { sudo -u "$SUDO_USER" -- "$@"; }

# provider/pool names must be alphanumeric+underscore; map a host name to one
sanitize() { printf '%s' "${1//[^a-zA-Z0-9]/_}"; }
