# GARM-on-Incus Arch Host Setup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Publish a `garm-provider-incus-bin` AUR package (companion to KazW's `garm-bin`), and build idempotent setup scripts that turn a fresh Arch host into a GARM-managed GitHub Actions runner farm on Incus with btrfs storage, shared workflow-scratch volume, and a Docker pull-through registry cache.

**Architecture:** GARM runs on the host via systemd (from `garm-bin`), talking to the local Incus daemon over the unix socket as the `garm` user (added to `incus-admin` via a sysusers drop-in). Two external provider registrations (`incus_ct`, `incus_vm`) share one provider binary with different configs, giving container and VM runner pools. Cache volumes are Incus custom btrfs volumes: a multi-attach `garm-scratch` volume mounted into every runner via profiles, and a `registry-cache` volume backing an Alpine container running a Docker Hub pull-through registry (`registry.incus:5000`).

**Tech Stack:** Bash (shellcheck-clean), PKGBUILD/makepkg, systemd (sysusers.d, sysctl.d, tmpfiles.d), Incus CLI, garm-cli v0.2.1, GitHub Actions (AUR auto-deploy workflow reused from `aur-garm-bin`).

**Verified facts this plan relies on:**
- `garm-bin` 0.2.1 installs `/usr/bin/garm{,-cli}`, `garm.service` (User=garm), `/etc/garm`, `/var/lib/garm`, `/opt/garm/providers.d/` (checked from the live AUR repo).
- `garm-provider-incus` v0.1.5 release assets and sha256s:
  - amd64 `1489b5f9b3f01528e338c604c13dabe8321ed6f1bc6de77c7344119d7731c43f`
  - arm64 `667bc66828758711be51e928457b712ea460294f195b310cf1e93ed609c1e9af`
- Provider config format (from v0.1.5 `testdata/garm-provider-incus.toml`): `unix_socket_path`, `instance_type` (`container`|`virtual-machine`), `include_default_profile`, `secure_boot`, `project_name`, `[image_remotes.images]`.
- GARM v0.2.1 config format and CLI flow (from `doc/quickstart-systemd.md` and `doc/first-steps.md` at tag v0.2.1): `[[provider]]` external blocks, `garm-cli init --name --url [--callback-url --metadata-url --webhook-url]`, `garm-cli github credentials add --auth-type pat`, `garm-cli repo add ... --install-webhook`, `garm-cli pool add --flavor <incus profile> --image images:... --provider-name ...`.
- Provider `extra_specs` supports `extra_packages` (apt package list) and `pre_install_scripts` (map of filename → base64 content), used here to install docker and point it at the registry mirror.
- On Arch, the Incus socket is `/var/lib/incus/unix.socket`, full-API group is `incus-admin`.
- Sharing one custom filesystem volume across many containers requires `security.shifted=true` on the volume.

---

## Part A — `garm-provider-incus-bin` AUR package

New repo `~/Work/garm-provider-incus-aur`, GitHub `kazatronics/aur-garm-provider-incus-bin`, AUR pkgname `garm-provider-incus-bin`. Mirrors the conventions of `~/Work/garm-aur` exactly.

### Task A1: Scaffold the packaging repo

**Files:**
- Create: `~/Work/garm-provider-incus-aur/.gitignore`
- Create: `~/Work/garm-provider-incus-aur/LICENSE.md`

**Step 1: Init repo**

```bash
mkdir -p ~/Work/garm-provider-incus-aur && cd ~/Work/garm-provider-incus-aur
git init -b main
```

**Step 2: Copy license and gitignore from the sibling repo**

```bash
cp ~/Work/garm-aur/LICENSE.md .
cp ~/Work/garm-aur/.gitignore .
cat .gitignore   # expect: build artifacts (src/, pkg/, *.tgz, *.pkg.tar.zst) ignored
```

If `.gitignore` doesn't already cover them, it must contain:

```
src/
pkg/
*.tgz
*.tar.zst
```

**Step 3: Commit**

```bash
git add -A && git commit -m "chore: scaffold packaging repo"
```

### Task A2: Write PKGBUILD and install file

**Files:**
- Create: `~/Work/garm-provider-incus-aur/PKGBUILD`
- Create: `~/Work/garm-provider-incus-aur/garm-provider-incus-bin.install`

**Step 1: Write PKGBUILD**

```bash
# Maintainer: Kaz Walker <me@kaz.codes>
pkgname=garm-provider-incus-bin
pkgver=0.1.5
pkgrel=1
pkgdesc='Incus external compute provider for GARM (official binary release)'
arch=('x86_64' 'aarch64')
url='https://github.com/cloudbase/garm-provider-incus'
license=('Apache-2.0')
provides=('garm-provider-incus')
conflicts=('garm-provider-incus')
optdepends=('garm: GitHub Actions Runner Manager that consumes this provider'
            'incus: local Incus daemon for the provider to talk to')
options=('!strip' '!debug')
install="$pkgname.install"

source_x86_64=("garm-provider-incus-${pkgver}-linux-amd64.tgz::${url}/releases/download/v${pkgver}/garm-provider-incus-linux-amd64.tgz")
source_aarch64=("garm-provider-incus-${pkgver}-linux-arm64.tgz::${url}/releases/download/v${pkgver}/garm-provider-incus-linux-arm64.tgz")
sha256sums_x86_64=('1489b5f9b3f01528e338c604c13dabe8321ed6f1bc6de77c7344119d7731c43f')
sha256sums_aarch64=('667bc66828758711be51e928457b712ea460294f195b310cf1e93ed609c1e9af')

package() {
    # Tarball contains a single static binary. Installed into garm's default
    # external provider directory (owned by the garm package).
    install -Dm755 garm-provider-incus \
        "$pkgdir/opt/garm/providers.d/garm-provider-incus"
}
```

**Step 2: Write install file**

```bash
post_install() {
    echo ':: Register the provider in /etc/garm/config.toml:'
    echo '       [[provider]]'
    echo '         name = "incus"'
    echo '         provider_type = "external"'
    echo '         [provider.external]'
    echo '           provider_executable = "/opt/garm/providers.d/garm-provider-incus"'
    echo '           config_file = "/etc/garm/garm-provider-incus.toml"'
    echo ':: Sample provider config:'
    echo '       https://github.com/cloudbase/garm-provider-incus/blob/main/testdata/garm-provider-incus.toml'
    echo ':: The user garm runs as needs access to the Incus socket, e.g.:'
    echo '       echo "m garm incus-admin" > /etc/sysusers.d/garm-incus.conf && systemd-sysusers'
}
```

**Step 3: Commit**

```bash
git add PKGBUILD garm-provider-incus-bin.install
git commit -m "feat: garm-provider-incus-bin 0.1.5 PKGBUILD"
```

### Task A3: Build-test the package

**Step 1: Build**

```bash
cd ~/Work/garm-provider-incus-aur && makepkg -f
```

Expected: `Finished making: garm-provider-incus-bin 0.1.5-1` with checksum validation PASS.

**Step 2: Verify package contents**

```bash
bsdtar -tf garm-provider-incus-bin-0.1.5-1-x86_64.pkg.tar.zst | grep -v '^\.'
```

Expected: exactly `opt/garm/providers.d/garm-provider-incus` (plus dirs).

**Step 3: Generate .SRCINFO**

```bash
makepkg --printsrcinfo > .SRCINFO
git add .SRCINFO && git commit -m "chore: add .SRCINFO"
```

### Task A4: README and auto-update workflow

**Files:**
- Create: `~/Work/garm-provider-incus-aur/README.md`
- Create: `~/Work/garm-provider-incus-aur/.github/workflows/update.yml`

**Step 1: Write README** — same shape as `aur-garm-bin`'s: what's included (`/opt/garm/providers.d/garm-provider-incus`), install via `yay -S garm-provider-incus-bin` or makepkg, setup pointer to the `[[provider]]` block and provider config sample, auto-update note, Apache-2.0.

**Step 2: Write workflow** — copy `~/Work/garm-aur/.github/workflows/update.yml`, then change:
- release check: `gh release view --repo cloudbase/garm-provider-incus`
- deploy step `pkgname: garm-provider-incus-bin`
- deploy `assets:` list → `garm-provider-incus-bin.install` and `.gitignore` only (no service/sysusers/tmpfiles)

**Step 3: Commit**

```bash
git add README.md .github && git commit -m "docs: README + AUR auto-update workflow"
```

### Task A5: Publish (GitHub + AUR)

**Step 1: Create GitHub repo and push**

```bash
gh repo create kazatronics/aur-garm-provider-incus-bin --public --source . --push
```

**Step 2: Configure workflow credentials** — the deploy action needs `AUR_SSH_PRIVATE_KEY` (secret) and `AUR_USERNAME`/`AUR_EMAIL` (vars), same values as `aur-garm-bin`. `gh secret set` / `gh variable set` or copy in the UI. **User step if the key isn't on this machine.**

**Step 3: First AUR push** — either trigger the workflow (`gh workflow run update.yml -f force=true`) or push by hand:

```bash
git remote add aur ssh://aur@aur.archlinux.org/garm-provider-incus-bin.git
git push aur main:master   # AUR uses master; needs PKGBUILD/.SRCINFO/install/.gitignore only
```

Note: the AUR remote must contain *only* the packaging files. The `KSXGitHub/github-actions-deploy-aur` action handles this filtering — prefer the workflow path.

**Step 4: Verify**

```bash
curl -s 'https://aur.archlinux.org/rpc/v5/info?arg[]=garm-provider-incus-bin' | python -m json.tool
```

Expected: `resultcount: 1`, Version `0.1.5-1`.

---

## Part B — `incus-garm` host setup scripts

Repo `~/Work/incus-garm`. Idempotent, config-driven, numbered steps run by an orchestrator. Every script passes `shellcheck` and `bash -n`.

Final layout:

```
incus-garm/
├── README.md
├── config.env.example      # copy to config.env (gitignored) and edit
├── setup.sh                # orchestrator: sources lib, runs steps/*.sh in order
├── lib/common.sh           # logging, config loading, guards, helpers
├── steps/
│   ├── 10-packages.sh      # pacman + AUR packages
│   ├── 20-incus-init.sh    # sysctl, incus service, btrfs pool, bridge, default profile
│   ├── 30-garm-user.sh     # garm → incus-admin via sysusers.d
│   ├── 40-cache-volumes.sh # scratch volume + registry volume + registry container
│   ├── 50-profiles.sh      # runner-ct / runner-vm profiles (= GARM flavors)
│   ├── 60-garm-config.sh   # /etc/garm/*.toml, secrets, enable garm.service
│   └── 70-garm-init.sh     # garm-cli init, credentials, entity, pools
└── docs/plans/...
```

### Task B1: Config template and common library

**Files:**
- Create: `config.env.example`
- Create: `lib/common.sh`
- Create: `.gitignore`

**Step 1: Write `.gitignore`**

```
config.env
```

**Step 2: Write `config.env.example`**

```bash
# incus-garm host configuration — copy to config.env and edit.
# Everything has a sane default except GITHUB_PAT and the entity settings.

## Incus
INCUS_STORAGE_POOL="garm"
# Empty → loop-backed btrfs file of INCUS_STORAGE_SIZE. Set to a block device
# (e.g. /dev/nvme1n1) to give Incus the whole device instead.
INCUS_STORAGE_SOURCE=""
INCUS_STORAGE_SIZE="50GiB"
INCUS_BRIDGE="incusbr0"
INCUS_BRIDGE_ADDR="10.100.0.1/24"   # host side of the runner bridge

## GARM
GARM_BIND_PORT="9997"
# Must be reachable from inside runner instances (metadata/callback) — the
# bridge address works. Also used by garm-cli on this host.
GARM_URL="http://10.100.0.1:9997"
GARM_CONTROLLER_NAME="$(hostname)-garm"
GARM_ADMIN_USER="admin"
GARM_ADMIN_EMAIL="root@localhost"
GARM_ADMIN_PASSWORD=""              # empty → generated, printed once by step 70

## Cache volumes
SCRATCH_VOLUME="garm-scratch"
SCRATCH_SIZE="20GiB"
SCRATCH_MOUNT="/mnt/scratch"        # path inside every runner
REGISTRY_VOLUME="registry-cache"
REGISTRY_SIZE="30GiB"
REGISTRY_INSTANCE="registry"        # reachable from runners as registry.incus:5000

## Runner shape (flavors are Incus profiles created by step 50)
RUNNER_CT_CPU="4"
RUNNER_CT_MEM="8GiB"
RUNNER_VM_CPU="4"
RUNNER_VM_MEM="8GiB"
RUNNER_VM_ROOT="20GiB"
RUNNER_IMAGE="images:ubuntu/24.04/cloud"

## GitHub wiring (step 70; skip the step entirely by leaving GITHUB_PAT empty)
GITHUB_PAT=""
GITHUB_CRED_NAME="github-pat"
GITHUB_ENTITY_TYPE="repo"           # repo | org
GITHUB_ORG=""                       # org name (org mode) or repo owner (repo mode)
GITHUB_REPO=""                      # repo name (repo mode only)
# Webhooks need GARM_URL (or a tunnel) reachable from github.com.
GITHUB_INSTALL_WEBHOOK="false"
POOL_MAX_RUNNERS="4"
POOL_MIN_IDLE="0"
```

**Step 3: Write `lib/common.sh`**

```bash
#!/bin/bash
# Shared helpers for incus-garm setup steps. Sourced, never executed.

set -euo pipefail

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_root() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo)"
    # makepkg refuses to run as root; we drop to the invoking user for AUR builds
    [[ -n ${SUDO_USER:-} ]] || die "run via sudo from a regular user, not a root login"
}

load_config() {
    local cfg="$REPO_ROOT/config.env"
    [[ -f $cfg ]] || die "config.env not found — cp config.env.example config.env and edit it"
    # shellcheck source=/dev/null
    source "$cfg"
}

# incus_missing <kind> <name> — true if the object doesn't exist yet
incus_missing() { ! incus "$1" show "$2" &>/dev/null; }

as_user() { sudo -u "$SUDO_USER" -- "$@"; }
```

**Step 4: Verify and commit**

```bash
shellcheck lib/common.sh && bash -n lib/common.sh
git add .gitignore config.env.example lib/common.sh
git commit -m "feat: config template and shared shell library"
```

### Task B2: Orchestrator and package installation

**Files:**
- Create: `setup.sh`
- Create: `steps/10-packages.sh`

**Step 1: Write `setup.sh`**

```bash
#!/bin/bash
# incus-garm: turn an Arch host into a GARM-managed runner farm on Incus.
# Usage: sudo ./setup.sh [step-prefix]
#   sudo ./setup.sh        # run all steps in order
#   sudo ./setup.sh 40     # run only steps/40-*.sh

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/common.sh disable=SC1091
source lib/common.sh

require_root
load_config

ran_any=false
for step in steps/[0-9]*.sh; do
    if [[ -n ${1:-} && $(basename "$step") != "$1"* ]]; then
        continue
    fi
    log "─── ${step#steps/} ───"
    # shellcheck source=/dev/null
    source "$step"
    ran_any=true
done
if [[ $ran_any == true ]]; then
    log "done"
else
    warn "no step matches prefix '${1:-}' — nothing ran"
fi
```

Steps are *sourced* so they share config and helpers; each must be a no-op when its work is already done.

**Step 2: Write `steps/10-packages.sh`**

```bash
#!/bin/bash
# Repo packages + AUR packages (garm-bin, garm-provider-incus-bin).

log "installing repo packages"
pacman -S --needed --noconfirm incus btrfs-progs git base-devel python

aur_install() {
    local pkg=$1
    if pacman -Qi "$pkg" &>/dev/null; then
        log "$pkg already installed"
        return 0
    fi
    if command -v paru &>/dev/null; then
        as_user paru -S --noconfirm "$pkg"
    elif command -v yay &>/dev/null; then
        as_user yay -S --noconfirm "$pkg"
    else
        log "no AUR helper — building $pkg with makepkg as $SUDO_USER"
        local bdir pkgfile
        bdir=$(as_user mktemp -d)
        as_user git clone "https://aur.archlinux.org/$pkg.git" "$bdir/$pkg"
        (cd "$bdir/$pkg" && as_user makepkg -s --noconfirm)
        for pkgfile in "$bdir/$pkg"/*.pkg.tar.zst; do
            if [[ $pkgfile != *-debug-* ]]; then
                pacman -U --noconfirm "$pkgfile"
            fi
        done
        rm -rf "$bdir"
    fi
}

aur_install garm-bin
aur_install garm-provider-incus-bin
```

**Step 3: Verify and commit**

```bash
shellcheck setup.sh steps/10-packages.sh
git add setup.sh steps/10-packages.sh
git commit -m "feat: orchestrator and package installation step"
```

### Task B3: Incus initialization

**Files:**
- Create: `steps/20-incus-init.sh`

**Step 1: Write the step**

```bash
#!/bin/bash
# Kernel limits, incus daemon, btrfs storage pool, runner bridge, default profile.

log "applying kernel limits for container density"
cat > /etc/sysctl.d/90-incus-garm.conf <<'EOF'
fs.inotify.max_queued_events = 1048576
fs.inotify.max_user_instances = 1048576
fs.inotify.max_user_watches = 1048576
kernel.keys.maxkeys = 2000
kernel.keys.maxbytes = 2000000
vm.max_map_count = 262144
EOF
sysctl -p /etc/sysctl.d/90-incus-garm.conf >/dev/null

log "enabling incus"
systemctl enable --now incus.service
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
```

**Step 2: Verify and commit**

```bash
shellcheck steps/20-incus-init.sh
git add steps/20-incus-init.sh && git commit -m "feat: incus init step (btrfs pool, bridge, sysctl)"
```

### Task B4: garm user ↔ Incus socket

**Files:**
- Create: `steps/30-garm-user.sh`

**Step 1: Write the step**

```bash
#!/bin/bash
# The provider binary runs as the garm user and talks to the local Incus
# socket; membership in incus-admin grants the full API. A sysusers.d drop-in
# keeps this declarative and reprovision-safe.

if ! id -nG garm 2>/dev/null | grep -qw incus-admin; then
    log "adding garm to incus-admin via sysusers.d"
    printf 'm garm incus-admin\n' > /etc/sysusers.d/garm-incus.conf
    systemd-sysusers
fi
id -nG garm | grep -qw incus-admin || die "garm is not in incus-admin"
```

**Step 2: Verify and commit**

```bash
shellcheck steps/30-garm-user.sh
git add steps/30-garm-user.sh && git commit -m "feat: grant garm user incus API access"
```

### Task B5: Cache volumes and registry container

**Files:**
- Create: `steps/40-cache-volumes.sh`

**Step 1: Write the step**

```bash
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
```

**Step 2: Verify and commit**

```bash
shellcheck steps/40-cache-volumes.sh
git add steps/40-cache-volumes.sh && git commit -m "feat: scratch + docker registry cache volumes"
```

### Task B6: Runner profiles (GARM flavors)

**Files:**
- Create: `steps/50-profiles.sh`

**Step 1: Write the step**

```bash
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
```

**Step 2: Verify and commit**

```bash
shellcheck steps/50-profiles.sh
git add steps/50-profiles.sh && git commit -m "feat: runner-ct and runner-vm flavor profiles"
```

### Task B7: GARM configuration

**Files:**
- Create: `steps/60-garm-config.sh`

**Step 1: Write the step**

```bash
#!/bin/bash
# /etc/garm/config.toml plus two provider configs (container + VM). Secrets
# are generated once; an existing config.toml is left untouched.

# The configs carry secrets — never create them world-readable, even for the
# instant before the explicit chmod below. Steps are sourced, so restore the
# previous umask once the files are in place.
prev_umask=$(umask)
umask 077

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
umask "$prev_umask"

log "starting garm"
systemctl enable --now garm.service
# Probe the API server root: curl fails only while nothing is listening —
# any HTTP response (even 404) means garm is up.
garm_up=false
for _ in $(seq 30); do
    if curl -s -o /dev/null "http://127.0.0.1:${GARM_BIND_PORT}/"; then
        garm_up=true
        break
    fi
    systemctl is-active --quiet garm.service || die "garm.service failed — journalctl -u garm"
    sleep 1
done
[[ $garm_up == true ]] || die "garm did not answer on :${GARM_BIND_PORT} after 30s"
```

**Step 2: Verify and commit**

```bash
shellcheck steps/60-garm-config.sh
git add steps/60-garm-config.sh && git commit -m "feat: garm + provider config generation"
```

### Task B8: GARM bootstrap (init, credentials, pools)

**Files:**
- Create: `steps/70-garm-init.sh`

**Step 1: Write the step**

```bash
#!/bin/bash
# One-time controller init and GitHub wiring. Entirely skipped when
# GITHUB_PAT is empty so the infra steps can run standalone.

if [[ -z $GITHUB_PAT ]]; then
    warn "GITHUB_PAT empty — skipping garm bootstrap (rerun: sudo ./setup.sh 70)"
    return 0
fi

garm_cli() { as_user garm-cli "$@"; }

if ! garm_cli profile list 2>/dev/null | grep -qw "$GARM_CONTROLLER_NAME"; then
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

# GARM requires a webhook secret on every entity even when it never installs
# the webhook — only the actual installation is optional.
webhook_flags=(--random-webhook-secret)
[[ $GITHUB_INSTALL_WEBHOOK == "true" ]] && webhook_flags+=(--install-webhook)

# Entity lookups go through --format json; names are handed to python via the
# environment so they can't break out of the expression.
org_id() {
    garm_cli org list --format json | GITHUB_ORG="$GITHUB_ORG" python -c \
        "import json,os,sys; print(next((o['id'] for o in json.load(sys.stdin) or [] if o['name'] == os.environ['GITHUB_ORG']), ''))"
}
repo_id() {
    garm_cli repo list -o "$GITHUB_ORG" -n "$GITHUB_REPO" --format json \
        | GITHUB_REPO="$GITHUB_REPO" python -c \
            "import json,os,sys; print(next((r['id'] for r in json.load(sys.stdin) or [] if r['name'] == os.environ['GITHUB_REPO']), ''))"
}

if [[ $GITHUB_ENTITY_TYPE == "org" ]]; then
    entity_id=$(org_id)
    if [[ -z $entity_id ]]; then
        garm_cli org add --name "$GITHUB_ORG" \
            --credentials "$GITHUB_CRED_NAME" "${webhook_flags[@]}"
        entity_id=$(org_id)
    fi
    entity_flag="--org"
else
    entity_id=$(repo_id)
    if [[ -z $entity_id ]]; then
        garm_cli repo add --owner "$GITHUB_ORG" --name "$GITHUB_REPO" \
            --credentials "$GITHUB_CRED_NAME" "${webhook_flags[@]}"
        entity_id=$(repo_id)
    fi
    entity_flag="--repo"
fi
[[ -n $entity_id ]] || die "could not resolve the $GITHUB_ENTITY_TYPE id from garm-cli"

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
```

**Step 2: Verify and commit**

```bash
shellcheck steps/70-garm-init.sh
git add steps/70-garm-init.sh && git commit -m "feat: garm controller bootstrap and pool creation"
```

**Note:** `garm-cli init` flag names for non-interactive user creation should be confirmed against `garm-cli init --help` from the installed 0.2.1 binary during execution; fall back to interactive prompts if they differ.

### Task B9: README and final lint pass

**Files:**
- Create: `README.md`

**Step 1: Write README** covering: what this builds (diagram of host → incus → runners + registry + scratch), prerequisites (fresh-ish Arch host, sudo user, optional AUR helper), quickstart (`cp config.env.example config.env`, edit, `sudo ./setup.sh`), re-running single steps, how pools/flavors map to profiles, webhook reachability caveat, where secrets land, and how the two AUR packages fit in.

**Step 2: Full lint**

```bash
shellcheck setup.sh lib/common.sh steps/*.sh
bash -n setup.sh lib/common.sh steps/*.sh
```

Expected: no output, exit 0.

**Step 3: Commit**

```bash
git add README.md && git commit -m "docs: README"
```

### Task B10 (integration, semi-manual): End-to-end test in an Incus VM

Run the whole thing inside a disposable Arch VM before touching a real host (nested containers work; nested VMs need host virt support).

**Step 1:** Launch an Arch VM: `incus launch images:archlinux/cloud test-garm --vm -c limits.cpu=4 -c limits.memory=8GiB` (on any machine that already runs Incus — or use a nexus VM).

**Step 2:** Push the repo in, create a user, run `sudo ./setup.sh` with a `config.env` pointing at a small loop pool.

**Step 3:** Verify: `garm.service` active; `incus list` shows `registry` running; `garm-cli pool list` shows both pools; with a real PAT + `POOL_MIN_IDLE=1`, a runner instance appears and registers as idle on the GitHub side.

**Step 4:** Tear down the VM.
