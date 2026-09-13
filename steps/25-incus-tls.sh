#!/bin/bash
# Compute-only: expose the Incus API over TLS and trust the controller's GARM
# client certificate so the remote garm-provider-incus can drive this host.

[[ $HOST_ROLE == compute ]] || return 0

if [[ $(incus config get core.https_address) != *[0-9]* ]]; then
    log "exposing Incus API on $INCUS_HTTPS_ADDRESS"
    incus config set core.https_address "$INCUS_HTTPS_ADDRESS"
fi

[[ -r $CONTROLLER_CLIENT_CERT ]] ||
    die "controller client cert not found at $CONTROLLER_CLIENT_CERT — copy the controller's GARM_CLIENT_CERT here first"

# incus config trust list shows the leading 12 hex of each cert's SHA256
fp=$(openssl x509 -in "$CONTROLLER_CLIENT_CERT" -noout -fingerprint -sha256 |
        sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
if incus config trust list --format csv | grep -qi "${fp:0:12}"; then
    log "controller client cert already trusted"
else
    log "trusting controller client cert (${fp:0:12})"
    incus config trust add-certificate "$CONTROLLER_CLIENT_CERT"
fi

log "compute host ready; copy /var/lib/incus/server.crt to the controller"
