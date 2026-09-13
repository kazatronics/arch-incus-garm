# Multi-Host GARM Controller Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let one GARM controller host manage runners across its own Incus **and** any number of remote Incus compute hosts over TLS, so a new compute host is added by appending to a list and running a cert exchange — with no host names committed anywhere.

**Architecture:** A `HOST_ROLE` splits setup into two roles. A **controller** runs the full stack (garm + provider binary + local Incus) and additionally holds one `[[provider]]` pair (container + VM) per remote compute host, each talking to that host's Incus API over TLS using GARM client-cert auth. A **compute** host runs only Incus — storage pool, bridge, cache volumes, runner profiles — with its API exposed over TLS and the controller's client certificate in its trust store; it runs no garm daemon. GARM's Incus provider selects remote mode automatically when `unix_socket_path` is empty and `url` + cert paths are set. Certs move between hosts as files at known paths (no SSH trust between prod hosts); the controller's client `.crt` is public and copyable, its `.key` never leaves the controller, and each compute host's world-readable `server.crt` is copied back to the controller.

**Tech Stack:** Bash (shellcheck-clean), Incus 7.4 (`config trust add-certificate`, `core.https_address`), garm-cli 0.2.1 external providers, openssl (EC client cert).

**Verified facts this plan relies on:**
- garm-provider-incus v0.1.5 config fields `client_certificate` / `client_key` / `tls_server_certificate` are **file paths** (validated with `os.Stat`), not inline PEM. Empty `unix_socket_path` ⇒ remote URL mode; otherwise local socket.
- Incus 7.4: `incus config trust add-certificate <file>` adds a client cert; the daemon TLS cert is world-readable at `/var/lib/incus/server.crt`; `core.https_address` must be set to expose the API (Incus default port `8443`).
- `setup.sh` sources numbered `steps/*.sh` in order in one shell (globals persist across steps within a full run, but a single-step run like `setup.sh 70` does not see another step's globals — each step must stand alone).
- Existing steps: 10 packages, 20 incus-init (shared), 30 garm-user, 40 cache-volumes (shared), 50 profiles (shared), 60 garm-config, 70 garm-init. Steps 20/40/50 work unchanged for both roles.

**Reachability (call out to operators, not code):**
- **GARM API URL:** remote runners live behind the *compute* host's NAT bridge, so `GARM_URL` must be the controller's address reachable from every host's runner network (its LAN address), **not** the per-host bridge gateway `10.100.0.1`. Set `GARM_URL` accordingly on the controller. The controller's firewall must accept the GARM port from the remote runner networks.
- **Incus TLS:** the compute host's firewall must accept `8443` from the controller.

---

## Task 1: Config schema + helper

**Files:**
- Modify: `config.env.example`
- Modify: `lib/common.sh`

**Step 1: Add role + multi-host settings to `config.env.example`.** Insert a role block near the top (after the header comment) and a controller/compute credentials block. Use only placeholder names.

```bash
## Host role: 'controller' runs garm + local Incus + remote providers;
## 'compute' runs Incus only (exposed over TLS) for a remote controller.
HOST_ROLE="controller"              # controller | compute

## --- Remote Incus over TLS -------------------------------------------------
# Controller: generated client cert/key GARM uses to authenticate to remote
# compute hosts. The .crt is public (copy it to each compute host); the .key
# never leaves this host.
GARM_CLIENT_CERT="/etc/garm/incus-client.crt"
GARM_CLIENT_KEY="/etc/garm/incus-client.key"

# Controller: the compute hosts to manage. One entry per host, space-separated,
# each "name|https-url|server-cert-path". The name is cosmetic (used for
# provider/pool names and a runner tag); the server cert is that host's
# /var/lib/incus/server.crt copied here. Leave empty for a single-host setup.
#   REMOTE_HOSTS="compute-a|https://compute-a.lan:8443|/etc/garm/remotes/compute-a.crt \
#                 compute-b|https://compute-b.lan:8443|/etc/garm/remotes/compute-b.crt"
REMOTE_HOSTS=""

# Compute: address to expose the Incus API on, and the controller client cert
# to trust (copy the controller's GARM_CLIENT_CERT here first).
INCUS_HTTPS_ADDRESS="[::]:8443"
CONTROLLER_CLIENT_CERT="/root/incus-client.crt"
```

**Step 2: Add a sanitizer to `lib/common.sh`** (host name → provider-name-safe token). Append near the other helpers:

```bash
# provider/pool names must be alphanumeric+underscore; map a host name to one
sanitize() { printf '%s' "${1//[^a-zA-Z0-9]/_}"; }
```

**Step 3: Verify + commit**

```bash
shellcheck lib/common.sh && bash -n lib/common.sh
git add config.env.example lib/common.sh
git commit -m "feat: host role + remote-host config schema"
```

## Task 2: Role-gate package installation (step 10)

**Files:** Modify: `steps/10-packages.sh`

**Step 1:** Split the repo-package line and gate the AUR/controller-only packages. Replace the top of the file:

```bash
log "installing repo packages"
pacman -S --needed --noconfirm incus btrfs-progs

# Only the controller builds/runs garm and the provider binary, and only it
# needs python (step 70) and the AUR build toolchain.
if [[ $HOST_ROLE == controller ]]; then
    pacman -S --needed --noconfirm git base-devel python
fi
```

Then guard the two `aur_install` calls at the bottom so they run only on the controller:

```bash
if [[ $HOST_ROLE == controller ]]; then
    aur_install garm-bin
    aur_install garm-provider-incus-bin
fi
```

**Step 2: Verify + commit**

```bash
shellcheck steps/10-packages.sh && bash -n steps/10-packages.sh
git add steps/10-packages.sh
git commit -m "feat: install garm packages only on the controller role"
```

## Task 3: Generate the GARM client certificate (new step 15, controller-only)

**Files:** Create: `steps/15-client-cert.sh`

**Step 1: Write the step.** EC cert matching Incus's own style; the `.crt` is public (0644 so it can be copied to compute hosts), the `.key` is `0640 garm:garm`.

```bash
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
```

**Step 2: Verify + commit**

```bash
shellcheck steps/15-client-cert.sh && bash -n steps/15-client-cert.sh
git add steps/15-client-cert.sh
git commit -m "feat: generate GARM incus client certificate on the controller"
```

## Task 4: Expose Incus over TLS + trust the controller (new step 25, compute-only)

**Files:** Create: `steps/25-incus-tls.sh`

**Step 1: Write the step.** Idempotent: only sets the address if unset, only adds the cert if its fingerprint isn't already trusted.

```bash
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
```

**Step 2: Verify + commit**

```bash
shellcheck steps/25-incus-tls.sh && bash -n steps/25-incus-tls.sh
git add steps/25-incus-tls.sh
git commit -m "feat: expose Incus over TLS and trust the controller (compute role)"
```

## Task 5: Role-gate the garm user (step 30)

**Files:** Modify: `steps/30-garm-user.sh`

**Step 1:** Add a guard as the first executable line (after the header comment):

```bash
[[ $HOST_ROLE == controller ]] || return 0
```

**Step 2: Verify + commit**

```bash
shellcheck steps/30-garm-user.sh && bash -n steps/30-garm-user.sh
git add steps/30-garm-user.sh
git commit -m "feat: gate garm-user step to the controller role"
```

## Task 6: Dynamic provider generation (step 60, controller-only + remotes)

**Files:** Modify: `steps/60-garm-config.sh` (substantial rewrite)

**Design:** config.toml becomes fully **regenerable** so adding a host is idempotent. Secrets are generated once into a sidecar (`/etc/garm/.garm-secrets`, `0600`) and reused, so regenerating config.toml never rotates the DB passphrase (which would break the encrypted DB). Providers: always the local pair; plus a pair per `REMOTE_HOSTS` entry whose server cert is present (missing cert ⇒ warn + skip, so a first controller run before the cert exchange still succeeds and you rerun `setup.sh 60` afterward). garm is restarted only if config.toml actually changed.

**Step 1: Replace the whole file** with:

```bash
#!/bin/bash
# Controller-only: assemble /etc/garm/config.toml (local provider pair + one
# pair per reachable remote compute host) and its per-provider config files,
# then (re)start garm. Fully regenerable: secrets persist in a sidecar so
# adding a host and rerunning does not rotate the DB passphrase.

[[ $HOST_ROLE == controller ]] || return 0

prev_umask=$(umask); umask 077
install -d /etc/garm /etc/garm/remotes

write_local_provider() {
    local file=$1 itype=$2
    cat > "$file" <<EOF
unix_socket_path = "/var/lib/incus/unix.socket"
include_default_profile = false
instance_type = "$itype"
secure_boot = false
project_name = "default"

[image_remotes]
    [image_remotes.images]
    addr = "https://images.linuxcontainers.org"
    public = true
    protocol = "simplestreams"
    skip_verify = false
EOF
}

write_remote_provider() {
    local file=$1 itype=$2 url=$3 servercert=$4
    cat > "$file" <<EOF
include_default_profile = false
instance_type = "$itype"
secure_boot = false
project_name = "default"
url = "$url"
client_certificate = "$GARM_CLIENT_CERT"
client_key = "$GARM_CLIENT_KEY"
tls_server_certificate = "$servercert"

[image_remotes]
    [image_remotes.images]
    addr = "https://images.linuxcontainers.org"
    public = true
    protocol = "simplestreams"
    skip_verify = false
EOF
}

providers_toml=""
add_provider_block() {
    local name=$1 desc=$2 cfg=$3
    providers_toml+="
[[provider]]
  name = \"$name\"
  provider_type = \"external\"
  description = \"$desc\"
  [provider.external]
    provider_executable = \"/opt/garm/providers.d/garm-provider-incus\"
    config_file = \"$cfg\"
"
}

# local provider pair
write_local_provider /etc/garm/garm-provider-incus-ct.toml container
write_local_provider /etc/garm/garm-provider-incus-vm.toml virtual-machine
add_provider_block "local_ct" "Local Incus - containers" /etc/garm/garm-provider-incus-ct.toml
add_provider_block "local_vm" "Local Incus - VMs" /etc/garm/garm-provider-incus-vm.toml

# one pair per reachable remote compute host
for entry in $REMOTE_HOSTS; do
    IFS='|' read -r rname rurl rcert <<<"$entry"
    if [[ ! -r $rcert ]]; then
        warn "server cert for '$rname' missing at $rcert — skipping (copy it, then: sudo ./setup.sh 60)"
        continue
    fi
    tok=$(sanitize "$rname")
    write_remote_provider "/etc/garm/garm-provider-incus-${tok}-ct.toml" container "$rurl" "$rcert"
    write_remote_provider "/etc/garm/garm-provider-incus-${tok}-vm.toml" virtual-machine "$rurl" "$rcert"
    add_provider_block "${tok}_ct" "Remote Incus ($rname) - containers" "/etc/garm/garm-provider-incus-${tok}-ct.toml"
    add_provider_block "${tok}_vm" "Remote Incus ($rname) - VMs" "/etc/garm/garm-provider-incus-${tok}-vm.toml"
done

# secrets: generate once, reuse forever (rotating the passphrase breaks the DB)
secrets_file=/etc/garm/.garm-secrets
if [[ -f $secrets_file ]]; then
    # shellcheck source=/dev/null
    source "$secrets_file"
else
    JWT_SECRET=$(head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | cut -c 1-64)
    DB_PASSPHRASE=$(head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | cut -c 1-32)
    { printf 'JWT_SECRET=%q\n' "$JWT_SECRET"
      printf 'DB_PASSPHRASE=%q\n' "$DB_PASSPHRASE"; } > "$secrets_file"
fi

new=$(cat <<EOF
[default]
enable_webhook_management = true

[logging]
enable_log_streamer = true
log_format = "text"
log_level = "info"
log_source = false

[metrics]
enable = true
disable_auth = false

[jwt_auth]
secret = "$JWT_SECRET"
time_to_live = "8760h"

[apiserver]
  bind = "0.0.0.0"
  port = $GARM_BIND_PORT
  use_tls = false
  [apiserver.webui]
    enable = true

[database]
  backend = "sqlite3"
  passphrase = "$DB_PASSPHRASE"
  [database.sqlite3]
    db_file = "/var/lib/garm/garm.db"
$providers_toml
EOF
)

changed=1
[[ -f /etc/garm/config.toml ]] && diff -q <(printf '%s\n' "$new") /etc/garm/config.toml >/dev/null && changed=0
printf '%s\n' "$new" > /etc/garm/config.toml

chown -R garm:garm /etc/garm
chmod 0640 /etc/garm/*.toml /etc/garm/.garm-secrets
umask "$prev_umask"

if [[ $changed -eq 1 ]]; then
    log "starting/reloading garm (config changed)"
    systemctl enable garm.service >/dev/null 2>&1
    systemctl restart garm.service
else
    systemctl enable --now garm.service
fi

garm_up=false
for _ in $(seq 30); do
    if curl -s -o /dev/null "http://127.0.0.1:${GARM_BIND_PORT}/"; then garm_up=true; break; fi
    systemctl is-active --quiet garm.service || die "garm.service failed — journalctl -u garm"
    sleep 1
done
[[ $garm_up == true ]] || die "garm did not answer on :${GARM_BIND_PORT} after 30s"
```

**Step 2: Verify + commit**

```bash
shellcheck steps/60-garm-config.sh && bash -n steps/60-garm-config.sh
git add steps/60-garm-config.sh
git commit -m "feat: generate local + per-remote-host providers, regenerable config"
```

## Task 7: Per-provider pools (step 70, controller-only)

**Files:** Modify: `steps/70-garm-init.sh`

**Design:** derive the actual loaded providers from garm itself (source of truth — a remote whose cert was missing won't appear), and create one pool per provider. Suffix `_ct` ⇒ flavor `runner-ct`, `_vm` ⇒ `runner-vm`. Tags carry the provider name so jobs can target a specific host, plus the common tags for load-spreading.

**Step 1:** Add the controller gate as the first line after the header, and replace the `add_pool` section (the two hard-coded `add_pool` calls) with a loop over garm's providers:

```bash
# derive pools from the providers garm actually loaded
providers=$(garm_cli provider list --format json |
    python -c "import json,sys; print(' '.join(p['name'] for p in json.load(sys.stdin) or []))")

add_pool() {
    local provider=$1 flavor=$2 tags=$3
    garm_cli pool list "$entity_flag" "$entity_id" 2>/dev/null | grep -qw "$provider" && return 0
    log "creating pool for $provider (flavor $flavor)"
    garm_cli pool add "$entity_flag" "$entity_id" --enabled=true \
        --provider-name "$provider" --flavor "$flavor" --image "$RUNNER_IMAGE" \
        --min-idle-runners "$POOL_MIN_IDLE" --max-runners "$POOL_MAX_RUNNERS" \
        --os-arch amd64 --os-type linux --tags "$tags" \
        --extra-specs "$extra_specs"
}

for provider in $providers; do
    case "$provider" in
        *_ct) add_pool "$provider" runner-ct "self-hosted,linux,incus,container,${provider}" ;;
        *_vm) add_pool "$provider" runner-vm "self-hosted,linux,incus,vm,${provider}" ;;
        *)    warn "provider $provider has no _ct/_vm suffix — skipping pool" ;;
    esac
done

log "pools:"
garm_cli pool list "$entity_flag" "$entity_id"
```

Add after the header comment (before the auth `case`):

```bash
[[ $HOST_ROLE == controller ]] || return 0
```

Note the pool-existence guard now greps for the **provider** name (unique per pool here) rather than the flavor, since multiple providers share the same flavor.

**Step 2: Verify + commit**

```bash
shellcheck steps/70-garm-init.sh && bash -n steps/70-garm-init.sh
git add steps/70-garm-init.sh
git commit -m "feat: one runner pool per loaded provider, host-tagged"
```

## Task 8: README — multi-host model + add-a-host runbook

**Files:** Modify: `README.md`

**Step 1:** Add a "Multiple hosts" section documenting (generically, no host names):
- The controller/compute split and that `setup.sh` runs on each host with the matching `HOST_ROLE`.
- The **reachability** requirements: `GARM_URL` must be the controller's LAN-reachable address; controller firewall opens the GARM port to remote runner networks; compute firewall opens `8443` to the controller.
- The **add-a-compute-host runbook** (the cert exchange), as an ordered list:
  1. On the controller: `sudo ./setup.sh` (or at least step 15) generates `GARM_CLIENT_CERT`.
  2. Copy the controller's `incus-client.crt` to the new compute host (path = its `CONTROLLER_CLIENT_CERT`).
  3. On the compute host: set `HOST_ROLE=compute`, then `sudo ./setup.sh` (installs Incus, pool, bridge, caches, profiles, exposes TLS, trusts the cert).
  4. Copy the compute host's `/var/lib/incus/server.crt` back to the controller (path = the `server-cert-path` in its `REMOTE_HOSTS` entry).
  5. On the controller: append the host's `name|url|server-cert-path` to `REMOTE_HOSTS`, then `sudo ./setup.sh 60 && sudo ./setup.sh 70`.
- Note the private key (`GARM_CLIENT_KEY`) never leaves the controller; only the public `.crt` and each compute host's `server.crt` are copied.

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: multi-host controller model and add-a-host runbook"
```

## Task 9: Full lint pass

**Step 1:**

```bash
shellcheck setup.sh lib/common.sh steps/*.sh
bash -n setup.sh lib/common.sh steps/*.sh
```

Expected: no output, exit 0.

**Step 2: Commit** any fixes.

## Task 10 (integration, semi-manual): two-host end-to-end

Run against the real controller + one real compute host (no host names in the repo — these are operator-supplied at runtime via `config.env`).

**Step 1:** Controller: `config.env` with `HOST_ROLE=controller`, `GARM_URL` = controller LAN address, `REMOTE_HOSTS` empty for now; `sudo ./setup.sh`. Expect local `local_ct`/`local_vm` providers, garm up.

**Step 2:** Copy controller `incus-client.crt` → compute host.

**Step 3:** Compute: `config.env` with `HOST_ROLE=compute`, `CONTROLLER_CLIENT_CERT` = copied path; `sudo ./setup.sh`. Expect Incus exposed on `8443`, controller cert trusted, pool/bridge/registry/profiles present, no garm service.

**Step 4:** Open `8443` (compute firewall) to the controller and the GARM port (controller firewall) to the compute runner network. Copy compute `server.crt` → controller.

**Step 5:** Controller: set `REMOTE_HOSTS="<name>|https://<compute-addr>:8443|<server-cert-path>"`; `sudo ./setup.sh 60`. Expect a `<tok>_ct`/`<tok>_vm` provider pair loaded (`garm-cli provider list`). Then `sudo ./setup.sh 70` → a pool per provider.

**Step 6:** With a real credential + a queued job tagged for a host token, confirm GARM spawns a runner on the intended host and it registers.

**Step 7:** Tear down test runners.
