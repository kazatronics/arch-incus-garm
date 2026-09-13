#!/bin/bash
# The provider binary runs as the garm user and talks to the local Incus
# socket; membership in incus-admin grants the full API. A sysusers.d drop-in
# keeps this declarative and reprovision-safe.

[[ $HOST_ROLE == controller ]] || return 0

if ! id -nG garm 2>/dev/null | grep -qw incus-admin; then
    log "adding garm to incus-admin via sysusers.d"
    install -d /etc/sysusers.d
    printf 'm garm incus-admin\n' > /etc/sysusers.d/garm-incus.conf
    systemd-sysusers
fi
id -nG garm | grep -qw incus-admin || die "garm is not in incus-admin"
