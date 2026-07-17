# SC2 Bundling Guide

For the engineer preparing an SC2 bundle on the internet-connected side,
before it ships across the air gap. Everything the target host needs must be
inside the tarball — assume the target has nothing but a base RHEL install.

## Bundle layout

```
sc2                  installer entrypoint (do not modify)
lib/                 installer + orchestrator modules (do not modify)
rpms/el{7,8,9,10}/      offline RPM closures + repodata <- build script adds
images/*.tgz         images for managed apps         <- you add
containers/*.tgz     pre-loaded images, auto-detected<- you add
artifacts/           files for bundle.conf 'copy'    <- you add
bundle.conf          install directives              <- you author
apps/<name>/         one directory per managed app   <- you author
docs/                this documentation (ships as-is)
VERSION, sha256sums
```

## Adding a managed application

A managed app gets a systemd unit, firewall rules, verification, and upgrade
handling. Create `apps/<name>/` with two files:

**`apps/myapp/manifest`** (bash-sourceable, values only):

```
APP_NAME="myapp"
APP_VERSION="1.4.2"
APP_PORTS="8443/tcp 5140/udp"
APP_IMAGES="myapp-api-1.4.2.tgz myapp-db-1.4.2.tgz"
APP_DESC="One-line description shown in the installer menu"   # optional
APP_TLS="api db"      # services that get SC2-issued TLS certs (optional)
APP_PKI="api"         # services that ultimately need an OFFICIAL (e.g. DoD
                      # PKI) certificate. They get an SC2 bootstrap cert so
                      # the app works immediately, and the installer shows
                      # the operator step-by-step import instructions.
```

**`apps/myapp/docker-compose.yml`** — SC2 executes compose files with its own
built-in orchestrator (no compose binary, same behavior on Docker and
Podman). It supports a documented subset and **rejects anything else loudly at
preflight** — an unsupported key never gets silently ignored.

Supported per service: `image` (required), `command` (string, list, or inline
array), `entrypoint` (single value), `ports`, `volumes`, `environment` (list
or map), `depends_on` (start ordering; health conditions are ignored with a
warning), `restart`, `user`, `privileged`, `expose` (accepted, ignored). Plus
top-level `services:` and `volumes:` (named volumes, no driver options).

Explicitly rejected: custom `networks:` (each app gets one isolated network;
services reach each other by service name), `container_name` (SC2 names
containers `sc2-<app>-<service>-1`), `healthcheck`, and anything unrecognized.

Rules of thumb:

- Reference images by the **exact name** the archives were saved under.
- Use named volumes for persistent data (they survive upgrades and plain
  `remove`; only `remove --purge` deletes them). Bind mounts may be absolute
  paths or `./relative` (resolved against the deployed app directory); add
  `:Z`/`:z` suffixes on SELinux hosts.
- Set `restart: unless-stopped` so container crashes self-heal.
- Prefer the array form for `command` (exact argv, no shell-splitting
  surprises).

Save the images (name must match the compose reference):

```
docker save myregistry/myapp-api:1.4.2 | gzip > images/myapp-api-1.4.2.tgz
```

## TLS between containers (and https:// at the edge)

Declare which services get TLS material in the manifest:

```
APP_TLS="web proxy backend"
APP_TLS_SANS_web="app.example.mil 10.20.30.40"   # optional extra SANs per service
```

At deploy time SC2 maintains a local CA (`/etc/sc2/pki/`) and issues each
listed service a certificate whose SANs are derived automatically from the
orchestrator's own naming: the service name (the DNS name other containers
use), the container name, `localhost`, the host's short and FQDN names, and
`127.0.0.1` — plus any `APP_TLS_SANS_*` extras. The material is mounted
read-only at a fixed path in the container:

```
/run/sc2/tls/tls.key         private key (0600)
/run/sc2/tls/tls.crt         leaf certificate
/run/sc2/tls/fullchain.crt   leaf + chain (use this in Apache/nginx)
/run/sc2/tls/ca.crt          the SC2 CA (trust anchor for peer verification)
```

Point the app's TLS config at those paths once (e.g. Apache
`SSLCertificateFile /run/sc2/tls/fullchain.crt`) and every install on every
host is identical. Cert content feeds the container config hash, so
`sc2 certs rotate` recreates exactly the services whose certs changed.

For the browser-facing endpoint that must chain to an external PKI (e.g. DoD),
issuance stays with your RA process; once the file exists, one command
installs it: `sc2 certs import <app> <svc> <file>` (PKCS#12 or PEM,
auto-detected — see docs/OPERATIONS.md). Imported certs are marked and never
touched by rotation.

## Pre-loading standalone containers

Drop image archives into `containers/`. Every `*.tgz` / `*.tar` / `*.tar.gz`
there is auto-detected and loaded at install and upgrade time — no manifest.
Use this for images referenced dynamically at runtime or run by operators by
hand. They are not started or supervised by SC2.

## bundle.conf directives

Authored pre-ship, validated before anything is modified, applied in file
order, fully undone by `remove` (via the ledger). Whitespace-separated, no
spaces in paths, `#` comments:

```
copy  artifacts/app /opt/app      # bundle-relative src -> absolute dest
mkdir /var/lib/myapp 0750         # created only if missing
port  9443/tcp                    # opened on whichever firewall is active
run   /bin/sh /opt/app/setup.sh   # post-install hook: root, runs AFTER apps are up
```

Semantics worth knowing:

- `copy` results are owned `root:root` regardless of who built the bundle.
  If the destination directory already exists, only the copied items are
  ledger-recorded, so `remove` never deletes pre-existing content.
- `remove` refuses to delete protected system paths (`/etc`, `/usr`, `/var`,
  ...) no matter what the ledger says; `/opt/...` and `/usr/local/...` are the
  intended destinations.
- `mkdir` directories are removed only if empty, unless `remove --purge`.
- Directives are re-applied on `upgrade` (idempotent).

## Versioning and upgrades

Bump `APP_VERSION` in each changed app's manifest and include the new image
archives. On the target, the operator unpacks the new bundle and runs
`sudo ./sc2 upgrade`: SC2 compares each app's manifest version against
`/etc/sc2/apps/<name>.version`, loads only changed apps' images, and recreates
only changed containers. Data volumes persist. Set the bundle-wide `VERSION`
file to your release number.

## Building the shippable tarball

The build is two steps: **fetch** the artifacts declared in `build.conf`, then
**package** the tree. A fresh clone carries only source — the RPMs, images, and
artifact payloads are pulled by the fetch step.

```
SC2_PROFILE=public build/fetch-artifacts.sh   # pull RPMs, images, artifacts
build/build-bundle.sh                          # -> dist/sc2-<version>-x86_64.tgz
```

`build/build-bundle.sh --fetch` runs both in one shot. Fetching requires bash,
curl, tar, and podman or docker; packaging needs only bash + tar and runs
offline. `build/fetch-artifacts.sh --dry-run` prints what would be pulled
without touching anything. **Where** each artifact comes from — RPM package
sets, container image refs, registries/mirrors, and the `public` vs `work`
profiles — is all declared in `build.conf`. See `docs/BUILDING.md` for the
end-to-end workflow (including GitLab CI).

**RPM closure caveats (read this):**

- Resolve closures against the **oldest minor** of each major you support,
  from a **minimal** install, so the set is complete on any field system.
  Extra RPMs cost disk, not correctness — yum only installs what's missing.
- el8/el9: UBI images do not expose the full RHEL repos. Use a subscribed
  RHEL container/host or an internal mirror for `podman container-selinux`.
- el8 specifically: podman is built as part of the `container-tools` dnf
  module. `createrepo_c` generates no modular metadata, so SC2's repo config
  sets `module_hotfixes=1` to install them as plain RPMs — this is expected
  and already handled; do not try to bundle modules.yaml.
- Use `dnf download --resolve --alldeps` (el8/9) so the closure is complete
  even against a minimal field install, and download from a host matching the
  oldest minor you support. Missing transitive deps are the #1 install
  failure: the install fails cleanly at the package phase naming the missing
  dependency, but the fix requires rebuilding the bundle.
- Watch for *conditional* dependencies on the target baseline: packages
  already installed on the field system can carry rich deps (e.g.
  `insights-core` requires `insights-core-selinux` if `selinux-policy-targeted`
  is present) that a closure resolved elsewhere cannot know about. There is no
  general fix — test the bundle against an image of the actual target baseline
  (e.g. the CANES build) before shipping.
- el7: the script uses the CentOS 7 vault plus the docker-ce repo. Docker CE
  ended CentOS 7 builds at 24.x — pin and test; it will never be patched.

## Pre-ship checklist

- [ ] `bash -n sc2 lib/*.sh` passes (no syntax damage from edits)
- [ ] every image referenced in every compose file exists in `images/` or is
      already on the target
- [ ] `bundle.conf` sources exist (`copy` paths are bundle-relative)
- [ ] `rpms/elN/` populated with `repodata/` for every RHEL major you target
- [ ] `sha256sums` regenerated after the last change (the build script does)
- [ ] test install + upgrade + remove on a clean VM of each target major
