#!/bin/bash
# /etc/garm/config.toml plus two provider configs (container + VM). Secrets
# are generated once; an existing config.toml is left untouched.

if [[ ! -f /etc/garm/config.toml ]]; then
    log "generating /etc/garm/config.toml"
    # head bounds the urandom read so tr isn't SIGPIPE-killed under pipefail
    jwt_secret=$(head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | cut -c 1-64)
    db_passphrase=$(head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | cut -c 1-32)

    cat > /etc/garm/config.toml <<EOF
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
secret = "$jwt_secret"
time_to_live = "8760h"

[apiserver]
  bind = "0.0.0.0"
  port = $GARM_BIND_PORT
  use_tls = false
  [apiserver.webui]
    enable = true

[database]
  backend = "sqlite3"
  passphrase = "$db_passphrase"
  [database.sqlite3]
    db_file = "/var/lib/garm/garm.db"

[[provider]]
  name = "incus_ct"
  provider_type = "external"
  description = "Local Incus - container runners"
  [provider.external]
    provider_executable = "/opt/garm/providers.d/garm-provider-incus"
    config_file = "/etc/garm/garm-provider-incus-ct.toml"

[[provider]]
  name = "incus_vm"
  provider_type = "external"
  description = "Local Incus - VM runners"
  [provider.external]
    provider_executable = "/opt/garm/providers.d/garm-provider-incus"
    config_file = "/etc/garm/garm-provider-incus-vm.toml"
EOF
fi

write_provider_config() {
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
write_provider_config /etc/garm/garm-provider-incus-ct.toml container
write_provider_config /etc/garm/garm-provider-incus-vm.toml virtual-machine

chown -R garm:garm /etc/garm
chmod 0640 /etc/garm/*.toml

log "starting garm"
systemctl enable --now garm.service
for _ in $(seq 30); do
    curl -sf "http://127.0.0.1:${GARM_BIND_PORT}/api/v1/metrics" &>/dev/null && break
    systemctl is-active --quiet garm.service || die "garm.service failed — journalctl -u garm"
    sleep 1
done
