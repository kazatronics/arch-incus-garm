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
│     └── garm-provider-incus (local pair: local_ct, local_vm;
│                              plus one pair per remote compute host)
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
| `10-packages.sh` | repo packages everywhere; `garm-bin` and `garm-provider-incus-bin` from the AUR on the controller |
| `15-client-cert.sh` | *(controller)* generates the GARM Incus client cert to copy to compute hosts |
| `20-incus-init.sh` | sysctl limits, incus daemon, btrfs pool, runner bridge, default profile |
| `25-incus-tls.sh` | *(compute)* exposes the Incus API over TLS and trusts the controller's client cert |
| `30-garm-user.sh` | *(controller)* adds `garm` to `incus-admin` via a sysusers.d drop-in |
| `40-cache-volumes.sh` | scratch + registry volumes, pull-through registry container |
| `50-profiles.sh` | `runner-ct` / `runner-vm` profiles (= GARM flavors) |
| `60-garm-config.sh` | *(controller)* `/etc/garm/*.toml`, generated secrets, enables `garm.service` |
| `70-garm-init.sh` | *(controller)* `garm-cli` init, GitHub credentials, repo/org, runner pools |

Leaving `GITHUB_AUTH_TYPE` empty skips step 70 entirely, so the infrastructure
can be provisioned before any GitHub wiring exists.

## Multiple hosts

One controller can drive runners across its own Incus **and** any number of
remote Incus *compute* hosts over TLS. `HOST_ROLE` in `config.env` selects which
half of the setup runs, and you run `sudo ./setup.sh` on **each** host with the
matching role:

- **`controller`** — the full stack: garm, the provider binary, the local Incus,
  and one external-provider pair (`<name>_ct` / `<name>_vm`) per remote compute
  host. Every step runs.
- **`compute`** — Incus only: storage pool, bridge, cache volumes, and runner
  profiles, with the API exposed over TLS and the controller's client
  certificate trusted. It runs no garm daemon, so the garm-only steps (`15`,
  `30`, `60`, `70`) return early and the compute-only step `25` does the TLS
  work.

A new compute host is added by exchanging two certificates and appending one
line to `REMOTE_HOSTS` — no host names are ever committed to this repo; they
live only in your `config.env`.

### Reachability

Runners on a compute host reach the controller across the network, so two
things must line up:

- **`GARM_URL` must be the controller's LAN-reachable address** — the one every
  host's runner network can route to — **not** the per-host bridge gateway
  `10.100.0.1`, which only resolves on the controller itself. Runners fetch
  their metadata and post callbacks to `GARM_URL`.
- **Firewalls:** the controller must accept the GARM port (`GARM_BIND_PORT`,
  default `9997`) from each compute host's runner network, and each compute host
  must accept `8443` (the Incus API) from the controller.

### Adding a compute host

The controller and compute hosts never SSH to each other — they exchange two
certificate files. Only public halves travel: the controller's private key
(`GARM_CLIENT_KEY`) never leaves the controller, and each compute host's
`server.crt` is world-readable by design.

1. **On the controller:** `sudo ./setup.sh` (or at least `sudo ./setup.sh 15`)
   generates `GARM_CLIENT_CERT` (default `/etc/garm/incus-client.crt`).
2. Copy that `incus-client.crt` to the new compute host, to the path its
   `CONTROLLER_CLIENT_CERT` points at.
3. **On the compute host:** set `HOST_ROLE=compute` and `CONTROLLER_CLIENT_CERT`
   in `config.env`, then `sudo ./setup.sh`. This installs Incus, the pool,
   bridge, caches and profiles, exposes the API over TLS, and trusts the
   controller's cert.
4. Copy the compute host's `/var/lib/incus/server.crt` back to the controller,
   to the `server-cert-path` you will use in its `REMOTE_HOSTS` entry.
5. **On the controller:** append `name|https-url|server-cert-path` to
   `REMOTE_HOSTS`, then `sudo ./setup.sh 60 && sudo ./setup.sh 70`. Step 60
   regenerates `config.toml` with the new provider pair (secrets are preserved
   from a sidecar, so the DB passphrase never rotates); step 70 adds a runner
   pool per loaded provider, tagged with the provider name so a job can target a
   specific host. A remote whose `server.crt` is not yet present is warned about
   and skipped, so a first controller run before the cert exchange still
   succeeds — just rerun `sudo ./setup.sh 60` once the cert is in place.

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
| `runner-ct` | `local_ct` | container (with `security.nesting` for docker) |
| `runner-vm` | `local_vm` | virtual machine |

Each remote compute host adds its own `<name>_ct` / `<name>_vm` provider pair
reusing the same two flavors, so step 70 creates one pool per provider — a
container and a VM pool for the local Incus and for every remote host.

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
- `/etc/garm/.garm-secrets` — the generated JWT secret and database passphrase
  (owned by `garm`, mode 0600). They are created once and reused, so
  `config.toml` can be regenerated on every run — e.g. when you add a compute
  host — without rotating the DB passphrase (which would break the encrypted DB)
- `/etc/garm/config.toml` — regenerated from those secrets each run (owned by
  `garm`, mode 0640); garm restarts only when the file actually changes
- `/etc/garm/incus-client.{crt,key}` (controller) — the client cert/key GARM
  presents to remote compute hosts. The `.crt` is public and copyable (0644);
  the `.key` (0640, `garm:garm`) never leaves the controller
- The admin password — printed **once** by step 70 when
  `GARM_ADMIN_PASSWORD` is left empty; save it. `garm-cli` keeps its own
  login token under your user's home.

## The AUR packages

- [`garm-bin`](https://aur.archlinux.org/packages/garm-bin) — the GARM
  daemon and `garm-cli`, plus `garm.service`, the `garm` user, `/etc/garm/`
  and `/var/lib/garm/`
- [`garm-provider-incus-bin`](https://aur.archlinux.org/packages/garm-provider-incus-bin)
  — the provider binary in `/opt/garm/providers.d/`, registered as the local
  pair (`local_ct`, `local_vm`) in `config.toml` with different provider
  configs, plus one pair per remote compute host

Step 10 installs both on the controller; everything after that assumes their
file layout.
