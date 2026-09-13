#!/bin/bash
# Controller-only: the client certificate GARM presents to remote compute
# hosts. Self-signed is fine — Incus trusts it by fingerprint once added to
# each compute host's trust store. The public .crt is copyable; the .key stays.

[[ $HOST_ROLE == controller ]] || return 0

install -d /etc/garm

if [[ ! -f $GARM_CLIENT_CERT || ! -f $GARM_CLIENT_KEY ]]; then
    log "generating GARM incus client certificate"
    umask 077
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 \
        -sha384 -days 3650 -nodes \
        -keyout "$GARM_CLIENT_KEY" -out "$GARM_CLIENT_CERT" \
        -subj "/CN=garm-incus-client"
    chown garm:garm "$GARM_CLIENT_CERT" "$GARM_CLIENT_KEY"
    chmod 0644 "$GARM_CLIENT_CERT"   # public half — copy this to compute hosts
    chmod 0640 "$GARM_CLIENT_KEY"
    log "client cert ready: $GARM_CLIENT_CERT (copy this to each compute host)"
fi
