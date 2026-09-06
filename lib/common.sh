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
}

# incus_missing <kind> <name> — true if the object doesn't exist yet
incus_missing() { ! incus "$1" show "$2" &>/dev/null; }

as_user() { sudo -u "$SUDO_USER" -- "$@"; }
