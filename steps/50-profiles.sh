#!/bin/bash
# Profiles double as GARM "flavors": a pool created with --flavor runner-ct
# gets this profile applied to every instance the provider spawns.

if incus_missing profile runner-ct; then
    log "creating profile runner-ct"
    incus profile create runner-ct
fi
incus profile set runner-ct security.nesting=true
incus profile set runner-ct limits.cpu="$RUNNER_CT_CPU" limits.memory="$RUNNER_CT_MEM"
incus profile device get runner-ct root type &>/dev/null || \
    incus profile device add runner-ct root disk path=/ pool="$INCUS_STORAGE_POOL"
incus profile device get runner-ct eth0 type &>/dev/null || \
    incus profile device add runner-ct eth0 nic network="$INCUS_BRIDGE" name=eth0
incus profile device get runner-ct scratch type &>/dev/null || \
    incus profile device add runner-ct scratch disk \
        pool="$INCUS_STORAGE_POOL" source="$SCRATCH_VOLUME" path="$SCRATCH_MOUNT"

if incus_missing profile runner-vm; then
    log "creating profile runner-vm"
    incus profile create runner-vm
fi
incus profile set runner-vm limits.cpu="$RUNNER_VM_CPU" limits.memory="$RUNNER_VM_MEM"
incus profile device get runner-vm root type &>/dev/null || \
    incus profile device add runner-vm root disk path=/ pool="$INCUS_STORAGE_POOL" \
        size="$RUNNER_VM_ROOT"
incus profile device get runner-vm eth0 type &>/dev/null || \
    incus profile device add runner-vm eth0 nic network="$INCUS_BRIDGE" name=eth0
incus profile device get runner-vm scratch type &>/dev/null || \
    incus profile device add runner-vm scratch disk \
        pool="$INCUS_STORAGE_POOL" source="$SCRATCH_VOLUME" path="$SCRATCH_MOUNT"
