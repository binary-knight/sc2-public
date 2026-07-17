# SC2 — Simple Container Carrier

Offline container deployment for **RHEL 7 / 8 / 9 / 10 (x86_64)**, in pure bash.
Built for air-gapped, DISA-STIG-hardened systems: no internet, no python, no
assumptions about what is already installed.

## What it does

SC2 is delivered as a single tarball carrying everything it needs:

- **RPM closures** per RHEL major (`rpms/el7`, `el8`, `el9`) — installed from a
  temporary local `file://` yum repo with all other repos disabled.
- **A container runtime** — Docker CE on RHEL 7, Podman on RHEL 8/9. An
  already-running Docker is adopted rather than replaced.
- **A built-in orchestrator** — SC2 executes `docker-compose.yml` files itself
  (a documented subset), converting them on-target with awk and driving the
  engine CLI directly. No compose binary, no API socket, no python: the exact
  same orchestration logic runs on every RHEL. Idempotent and minimal — only
  containers whose configuration actually changed get recreated.
- **Container images** as `images/*.tgz` (`docker save` format).
- **Applications** as `apps/<name>/` (compose file + manifest); each deploys as
  a `sc2-<name>.service` systemd unit that survives reboots.
- **Pre-loaded containers**: any image archive dropped into `containers/` is
  auto-detected and loaded at install time — no manifest needed.
- **Bundle directives** in `bundle.conf`, authored before shipping: `copy`
  bundle files onto the host (e.g. `copy artifacts/app /opt/app`), `mkdir`,
  `port`, and `run` post-install hooks. All ledger-recorded and undone by
  `remove`.

## Documentation

Full guides ship inside the bundle under `docs/`:

- **[docs/INSTALL.md](docs/INSTALL.md)** — operator install guide for the
  air-gapped site (transfer, verify, TUI/CLI install, what each phase does)
- **[docs/OPERATIONS.md](docs/OPERATIONS.md)** — day-2 reference: commands,
  file locations, upgrades, removal, troubleshooting matrix, audit trail
- **[docs/BUNDLING.md](docs/BUNDLING.md)** — internet-side guide: adding apps,
  pre-loading containers, `bundle.conf` directives, building the tarball

## Usage

```
sudo ./sc2              # interactive TUI (default)
sudo ./sc2 install -y   # CLI: full install, no prompts
sudo ./sc2 status
sudo ./sc2 upgrade      # after unpacking a newer bundle
sudo ./sc2 remove       # keeps data volumes; add --purge to delete them
```

Everything SC2 changes on a host is recorded in `/etc/sc2/ledger`, so `remove`
replays facts instead of guessing. Logs go to `/var/log/sc2/sc2.log`.

## STIG/hardened-host behavior

- SELinux stays **enforcing**; `container-selinux` is bundled.
- On hosts running **fapolicyd**, SC2 registers its binaries as trusted.
- Firewall backend is auto-detected (firewalld / iptables / nftables) and app
  ports come from each app's manifest.
- Preflight fails fast on `noexec` container storage, low disk, wrong arch,
  or a corrupted bundle (sha256 manifest).

## Building a bundle

This repo carries **source only**; the offline payload (RPMs, images, artifact
copies) is fetched at build time from the locations declared in `build.conf`.
On an internet-connected host:

```
SC2_PROFILE=public build/fetch-artifacts.sh   # pull the payload
build/build-bundle.sh                          # -> dist/sc2-<version>-x86_64.tgz
```

See `docs/BUILDING.md` for the config, the `public`/`work` profiles, and the
GitLab CI pipeline; `docs/BUNDLING.md` for RPM-closure caveats.

## Layout

```
sc2                 entrypoint (bash, works on 4.2+)
lib/                detect, preflight, rpm, runtime, compose (yml converter),
                    orchestrator, firewall, apps, bundle, tui, cli, common
rpms/el{7,8,9,10}/     offline RPM closures (added by build)
images/*.tgz        saved container images for managed apps (added by build)
containers/*.tgz    pre-loaded container images, auto-detected at install
artifacts/          files shipped for bundle.conf 'copy' directives
bundle.conf         pre-bundle install directives (copy/mkdir/port/run)
apps/<name>/        manifest + docker-compose.yml per application
docs/               INSTALL, OPERATIONS, BUNDLING guides (ship with bundle)
build/              bundle assembly (internet side)
```
