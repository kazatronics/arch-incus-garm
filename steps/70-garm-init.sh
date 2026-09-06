#!/bin/bash
# One-time controller init and GitHub wiring. Entirely skipped when
# GITHUB_PAT is empty so the infra steps can run standalone.

if [[ -z $GITHUB_PAT ]]; then
    warn "GITHUB_PAT empty — skipping garm bootstrap (rerun: sudo ./setup.sh 70)"
    return 0
fi

garm_cli() { as_user garm-cli "$@"; }

if ! garm_cli profile list 2>/dev/null | grep -q .; then
    if [[ -z $GARM_ADMIN_PASSWORD ]]; then
        # head bounds the urandom read so tr isn't SIGPIPE-killed under pipefail
        GARM_ADMIN_PASSWORD=$(head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | cut -c 1-24)
        log "generated admin password: $GARM_ADMIN_PASSWORD  (save this!)"
    fi
    log "initializing controller $GARM_CONTROLLER_NAME"
    garm_cli init --name "$GARM_CONTROLLER_NAME" --url "$GARM_URL" \
        --username "$GARM_ADMIN_USER" --password "$GARM_ADMIN_PASSWORD" \
        --email "$GARM_ADMIN_EMAIL"
fi

if ! garm_cli github credentials list | grep -qw "$GITHUB_CRED_NAME"; then
    log "adding github credentials $GITHUB_CRED_NAME"
    garm_cli github credentials add \
        --name "$GITHUB_CRED_NAME" \
        --description "PAT for $GITHUB_ORG" \
        --auth-type pat --pat-oauth-token "$GITHUB_PAT" \
        --endpoint github.com
fi

webhook_flags=()
[[ $GITHUB_INSTALL_WEBHOOK == "true" ]] && webhook_flags=(--random-webhook-secret --install-webhook)

if [[ $GITHUB_ENTITY_TYPE == "org" ]]; then
    if ! garm_cli org list | grep -qw "$GITHUB_ORG"; then
        garm_cli org add --name "$GITHUB_ORG" \
            --credentials "$GITHUB_CRED_NAME" "${webhook_flags[@]}"
    fi
    entity_id=$(garm_cli org list -f json | as_user python -c \
        "import json,sys; print([o['id'] for o in json.load(sys.stdin) if o['name']=='$GITHUB_ORG'][0])")
    entity_flag="--org"
else
    if ! garm_cli repo list | grep -qw "$GITHUB_REPO"; then
        garm_cli repo add --owner "$GITHUB_ORG" --name "$GITHUB_REPO" \
            --credentials "$GITHUB_CRED_NAME" "${webhook_flags[@]}"
    fi
    entity_id=$(garm_cli repo list -f json | as_user python -c \
        "import json,sys; print([r['id'] for r in json.load(sys.stdin) if r['name']=='$GITHUB_REPO'][0])")
    entity_flag="--repo"
fi

# Runners that build images get docker plus a daemon.json pointing at the
# pull-through cache, injected before the runner installs.
mirror_script=$(base64 -w0 <<'EOF'
#!/bin/bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": ["http://registry.incus:5000"],
  "insecure-registries": ["registry.incus:5000"]
}
JSON
EOF
)
extra_specs=$(cat <<EOF
{"extra_packages": ["docker.io"], "pre_install_scripts": {"001-docker-mirror.sh": "$mirror_script"}}
EOF
)

add_pool() {
    local provider=$1 flavor=$2 tags=$3
    garm_cli pool list "$entity_flag" "$entity_id" 2>/dev/null | grep -qw "$flavor" && return 0
    log "creating $flavor pool"
    garm_cli pool add "$entity_flag" "$entity_id" --enabled=true \
        --provider-name "$provider" --flavor "$flavor" --image "$RUNNER_IMAGE" \
        --min-idle-runners "$POOL_MIN_IDLE" --max-runners "$POOL_MAX_RUNNERS" \
        --os-arch amd64 --os-type linux --tags "$tags" \
        --extra-specs "$extra_specs"
}

add_pool incus_ct runner-ct "self-hosted,linux,incus,container"
add_pool incus_vm runner-vm "self-hosted,linux,incus,vm"

log "pools:"
garm_cli pool list "$entity_flag" "$entity_id"
