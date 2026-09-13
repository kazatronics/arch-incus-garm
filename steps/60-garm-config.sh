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
# (REMOTE_HOSTS is a deliberately space-separated list — word-split it)
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
