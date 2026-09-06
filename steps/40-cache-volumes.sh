#!/bin/bash
# Two custom btrfs volumes:
#   - $SCRATCH_VOLUME: shared workflow scratch, multi-attached to every runner
#     (security.shifted lets many containers idmap it simultaneously)
#   - $REGISTRY_VOLUME: backing store for a Docker Hub pull-through registry
#     running in an Alpine container, reachable as $REGISTRY_INSTANCE.incus:5000

if ! incus storage volume show "$INCUS_STORAGE_POOL" "$SCRATCH_VOLUME" &>/dev/null; then
    log "creating scratch volume $SCRATCH_VOLUME ($SCRATCH_SIZE)"
    incus storage volume create "$INCUS_STORAGE_POOL" "$SCRATCH_VOLUME" size="$SCRATCH_SIZE"
    incus storage volume set "$INCUS_STORAGE_POOL" "$SCRATCH_VOLUME" security.shifted=true
fi

if ! incus storage volume show "$INCUS_STORAGE_POOL" "$REGISTRY_VOLUME" &>/dev/null; then
    log "creating registry volume $REGISTRY_VOLUME ($REGISTRY_SIZE)"
    incus storage volume create "$INCUS_STORAGE_POOL" "$REGISTRY_VOLUME" size="$REGISTRY_SIZE"
fi

if incus_missing instance "$REGISTRY_INSTANCE"; then
    log "launching pull-through registry container"
    incus launch images:alpine/3.22 "$REGISTRY_INSTANCE"
    incus storage volume attach "$INCUS_STORAGE_POOL" "$REGISTRY_VOLUME" \
        "$REGISTRY_INSTANCE" registry-data /var/lib/docker-registry

    # wait for network inside the container
    for _ in $(seq 30); do
        incus exec "$REGISTRY_INSTANCE" -- ping -c1 -W1 dl-cdn.alpinelinux.org &>/dev/null && break
        sleep 1
    done

    incus exec "$REGISTRY_INSTANCE" -- sh -eu <<'EOF'
apk add --no-cache docker-registry
cat > /etc/docker-registry/config.yml <<'YML'
version: 0.1
storage:
  filesystem:
    rootdirectory: /var/lib/docker-registry
  delete:
    enabled: true
http:
  addr: :5000
proxy:
  remoteurl: https://registry-1.docker.io
YML
chown -R docker-registry:docker-registry /var/lib/docker-registry
rc-update add docker-registry default
service docker-registry restart
EOF
elif incus list -f csv -c ns | grep -qxF "${REGISTRY_INSTANCE},STOPPED"; then
    log "starting stopped registry container"
    incus start "$REGISTRY_INSTANCE"
fi

# The registry may still be coming up (OpenRC start is asynchronous).
registry_ok=false
for _ in $(seq 15); do
    if incus exec "$REGISTRY_INSTANCE" -- wget -qO- http://localhost:5000/v2/ &>/dev/null; then
        registry_ok=true
        break
    fi
    sleep 1
done
[[ $registry_ok == true ]] || die "registry is not answering on :5000"
log "registry OK at ${REGISTRY_INSTANCE}.incus:5000"
