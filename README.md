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
  login (the AUR packages are built with makepkg, which refuses to run as
  root, so step 10 drops back to your user for the build)
- No AUR helper is required — `garm-bin` and `garm-provider-incus-bin` are
  cloned from the AUR and built with plain makepkg. Build dependencies (if
  any) are installed as root first, and the build itself never invokes sudo,
  so you are only prompted for your password once, by the initial `sudo`

## Quickstart

```bash
cp config.env.example config.env
"$EDITOR" config.env        # at minimum: GITHUB_AUTH_TYPE + credentials + entity
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

Leaving `GITHUB_AUTH_TYPE` empty skips step 70 entirely, so the infrastructure
can be provisioned before any GitHub wiring exists.

## GitHub authentication

GARM needs credentials that can *mint* runner registration tokens on demand —
it cannot use a one-time runner registration token the way a manually
registered runner does. So step 70 wires one of two `GITHUB_AUTH_TYPE`s:

- **`app` (recommended)** — a GitHub App installed on the org. GARM uses
  short-lived installation tokens that it refreshes itself, so there is no
  long-lived secret in `config.env`. Create the App with **Repository:**
  Administration R/W + Metadata RO (+ Webhooks R/W for auto-webhooks) and
  **Organization:** Self-hosted runners R/W (+ Webhooks R/W), install it on the
  org, then set `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and
  `GITHUB_APP_PRIVATE_KEY_PATH` (a `.pem` readable by the user running setup).
- **`pat`** — a classic/fine-grained personal access token in `GITHUB_PAT`.

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

## Host firewall (ufw / firewalld)

If the host runs a firewall, the runner bridge needs to be allowed through
it — otherwise instances get an address but can't route out, DHCP/DNS from
Incus's dnsmasq time out, and the tell-tale symptom is that pings work
(ICMP is usually permitted by default) while every TCP/UDP connection
hangs. For `ufw`, allow the bridge named in `config.env` (default
`incusbr0`):

```bash
sudo ufw allow in on incusbr0
sudo ufw route allow in on incusbr0
sudo ufw route allow out on incusbr0
```

The first rule restores DHCP/DNS to guests; the two `route` rules let guest
traffic through the FORWARD chain ufw otherwise drops. This also matters for
GARM reachability: runners fetch their metadata and post callbacks to
`GARM_URL` on the bridge address, so a blocked bridge breaks registration.

## Where secrets land

- `config.env` — your GitHub credential (`GITHUB_PAT`, or the App's id /
  installation id / private-key path); gitignored, keep it that way. With the
  App, the private key itself stays wherever you put the `.pem`; GARM copies it
  into its encrypted DB when the credential is added
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
