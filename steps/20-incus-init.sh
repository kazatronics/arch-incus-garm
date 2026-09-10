#!/bin/bash
# Kernel limits, incus daemon, btrfs storage pool, runner bridge, default profile.

log "applying kernel limits for container density"
install -d /etc/sysctl.d
cat > /etc/sysctl.d/90-incus-garm.conf <<'EOF'
fs.inotify.max_queued_events = 1048576
fs.inotify.max_user_instances = 1048576
fs.inotify.max_user_watches = 1048576
kernel.keys.maxkeys = 2000
kernel.keys.maxbytes = 2000000
vm.max_map_count = 262144
EOF
sysctl -p /etc/sysctl.d/90-incus-garm.conf >/dev/null

# Unprivileged containers need subordinate id ranges for root; the Arch
# incus package does not create them (VMs work without, containers fail
# with "System doesn't have a functional idmap setup").
idmap_changed=0
for f in /etc/subuid /etc/subgid; do
    if ! grep -qs '^root:' "$f"; then
        log "allocating root subordinate ids in $f"
        printf 'root:1000000:1000000000\n' >> "$f"
        idmap_changed=1
    fi
done

log "enabling incus"
systemctl enable --now incus.service
if [[ $idmap_changed -eq 1 ]]; then
    log "restarting incus to pick up idmap ranges"
    systemctl restart incus.service
fi
incus admin waitready --timeout 60

if incus_missing storage "$INCUS_STORAGE_POOL"; then
    if [[ -n $INCUS_STORAGE_SOURCE ]]; then
        log "creating btrfs pool $INCUS_STORAGE_POOL on $INCUS_STORAGE_SOURCE"
        incus storage create "$INCUS_STORAGE_POOL" btrfs source="$INCUS_STORAGE_SOURCE"
    else
        log "creating loop-backed btrfs pool $INCUS_STORAGE_POOL ($INCUS_STORAGE_SIZE)"
        incus storage create "$INCUS_STORAGE_POOL" btrfs size="$INCUS_STORAGE_SIZE"
    fi
fi

if incus_missing network "$INCUS_BRIDGE"; then
    log "creating bridge $INCUS_BRIDGE ($INCUS_BRIDGE_ADDR)"
    incus network create "$INCUS_BRIDGE" \
        ipv4.address="$INCUS_BRIDGE_ADDR" ipv4.nat=true ipv6.address=none
fi

if incus profile device get default root type &>/dev/null; then
    existing_pool=$(incus profile device get default root pool)
    [[ $existing_pool == "$INCUS_STORAGE_POOL" ]] || die \
        "default profile root device uses pool '$existing_pool', not '$INCUS_STORAGE_POOL' — remove the device or set INCUS_STORAGE_POOL to match"
else
    log "wiring default profile root to pool $INCUS_STORAGE_POOL"
    incus profile device add default root disk path=/ pool="$INCUS_STORAGE_POOL"
fi

if ! incus profile device get default eth0 type &>/dev/null; then
    log "wiring default profile eth0 to bridge $INCUS_BRIDGE"
    incus profile device add default eth0 nic network="$INCUS_BRIDGE" name=eth0
fi
