# incus-garm

Idempotent setup scripts that turn a fresh Arch Linux host into a
[GARM](https://github.com/cloudbase/garm)-managed GitHub Actions runner farm
on [Incus](https://linuxcontainers.org/incus/): container and VM runner
pools on btrfs storage, a shared workflow-scratch volume, and a Docker Hub
pull-through registry cache.

## What this builds

```
host (Arch)
├── garm.service ── unix socket ──> incus daemon
│     └── garm-provider-incus (registered twice: incus_ct, incus_vm)
└── incus
    ├── storage pool "garm" (btrfs, loop file or whole device)
    │   ├── garm-scratch    shared volume, mounted at /mnt/scratch in every runner
    │   └── registry-cache  backing volume for the registry
    ├── incusbr0 (10.100.0.1/24, NAT)
    ├── registry            Alpine container — Docker Hub pull-through cache,
    │                       reachable from runners as registry.incus:5000
    └── runner instances    containers (runner-ct) and VMs (runner-vm),
                            created and destroyed by GARM on demand
```

GARM runs on the host as the dedicated `garm` system user and drives the
local Incus daemon over the unix socket. Every runner gets the shared
scratch volume, plus docker pre-configured to pull through the local
registry cache.

## Prerequisites

- A fresh-ish Arch Linux host — the scripts install packages, write to
  `/etc/sysctl.d`, `/etc/sysusers.d`, and `/etc/garm`, and initialize Incus
- A regular user with sudo; run everything via `sudo`, not from a root
  login (AUR builds drop back to your user, makepkg refuses to run as root)
- Optionally `paru` or `yay` — without one, the AUR packages are cloned and
  built with plain makepkg; that fallback runs `makepkg -s` as your user, so
  your user needs working sudo (cached or passwordless) mid-run to install
  build dependencies

## Quickstart

```bash
cp config.env.example config.env
"$EDITOR" config.env        # at minimum: GITHUB_PAT and the entity settings
sudo ./setup.sh
```

Every step is idempotent, so re-run `sudo ./setup.sh` freely. To run a
single step, pass its number prefix:

```bash
sudo ./setup.sh 40          # just the cache volumes / registry step
```

| Step | What it does |
| --- | --- |
| `10-packages.sh` | repo packages plus `garm-bin` and `garm-provider-incus-bin` from the AUR |
| `20-incus-init.sh` | sysctl limits, incus daemon, btrfs pool, runner bridge, default profile |
| `30-garm-user.sh` | adds `garm` to `incus-admin` via a sysusers.d drop-in |
| `40-cache-volumes.sh` | scratch + registry volumes, pull-through registry container |
| `50-profiles.sh` | `runner-ct` / `runner-vm` profiles (= GARM flavors) |
| `60-garm-config.sh` | `/etc/garm/*.toml`, generated secrets, enables `garm.service` |
| `70-garm-init.sh` | `garm-cli` init, GitHub credentials, repo/org, runner pools |

Leaving `GITHUB_PAT` empty skips step 70 entirely, so the infrastructure
can be provisioned before any GitHub wiring exists.

## Flavors are profiles

A GARM pool names a provider and a "flavor"; the Incus provider applies the
flavor as an Incus profile to every instance it spawns. Step 50 creates the
profiles, step 70 creates one pool per provider registration:

| Pool flavor / profile | Provider | Instance type |
| --- | --- | --- |
| `runner-ct` | `incus_ct` | container (with `security.nesting` for docker) |
| `runner-vm` | `incus_vm` | virtual machine |

Both profiles carry the CPU/memory limits from `config.env` and mount the
shared `garm-scratch` volume at `/mnt/scratch`. To resize a flavor later,
edit the profile (`incus profile set runner-ct limits.cpu=8`) — new
instances pick it up on creation.

## Webhooks

GARM learns about queued jobs through GitHub webhooks.
`GITHUB_INSTALL_WEBHOOK` defaults to `false` because github.com must be
able to reach `GARM_URL`, and the default (the bridge address) is only
reachable from the host and its runners. To enable it, put GARM behind a
tunnel or reverse proxy, point `GARM_URL` at the public endpoint, and set
`GITHUB_INSTALL_WEBHOOK="true"` — or install the webhook by hand later with
`garm-cli repo webhook install`.

## Where secrets land

- `config.env` — your `GITHUB_PAT`; gitignored, keep it that way
- `/etc/garm/config.toml` — generated JWT secret and database passphrase
  (owned by `garm`, mode 0640, left untouched on re-runs)
- The admin password — printed **once** by step 70 when
  `GARM_ADMIN_PASSWORD` is left empty; save it. `garm-cli` keeps its own
  login token under your user's home.

## The AUR packages

- [`garm-bin`](https://aur.archlinux.org/packages/garm-bin) — the GARM
  daemon and `garm-cli`, plus `garm.service`, the `garm` user, `/etc/garm/`
  and `/var/lib/garm/`
- [`garm-provider-incus-bin`](https://aur.archlinux.org/packages/garm-provider-incus-bin)
  — the provider binary in `/opt/garm/providers.d/`, registered twice in
  `config.toml` (`incus_ct`, `incus_vm`) with different provider configs

Step 10 installs both; everything after that assumes their file layout.
