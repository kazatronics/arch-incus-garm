#!/bin/bash
# incus-garm: turn an Arch host into a GARM-managed runner farm on Incus.
# Usage: sudo ./setup.sh [step-prefix]
#   sudo ./setup.sh        # run all steps in order
#   sudo ./setup.sh 40     # run only steps/40-*.sh

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/common.sh disable=SC1091
source lib/common.sh

require_root
load_config

ran_any=false
for step in steps/[0-9]*.sh; do
    if [[ -n ${1:-} && $(basename "$step") != "$1"* ]]; then
        continue
    fi
    log "─── ${step#steps/} ───"
    # shellcheck source=/dev/null
    source "$step"
    ran_any=true
done
if [[ $ran_any == true ]]; then
    log "done"
else
    warn "no step matches prefix '${1:-}' — nothing ran"
fi
