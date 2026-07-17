# SC2 Installation Guide

For the operator installing SC2 on an air-gapped RHEL 7 / 8 / 9 / 10 (x86_64) host.
No internet, python, or pre-installed container runtime is required — the
bundle carries everything.

## Requirements

- RHEL 7, 8, 9, or 10 on x86_64
- root access (`sudo`)
- roughly 2× the bundle's `images/` size free under `/var`

## 1. Transfer and verify

Copy the bundle tarball to the target host (removable media, internal file
transfer, etc.), then:

```
tar -xzf sc2-<version>-x86_64.tgz
cd sc2-<version>-x86_64
sha256sum -c sha256sums          # optional here; install re-checks it anyway
```

## 2. Install

### Interactive (default)

```
sudo ./sc2
```

This opens the guided installer. Navigation: **↑/↓** (or `j`/`k`) to select,
**Enter** to run, **q** to quit. The header shows what SC2 detected: OS,
container runtime, SELinux mode, FIPS mode, and the active firewall. The
menu lists each application in the bundle with the action that makes sense
right now — **Install**, **Upgrade** (when the bundle is newer), or
**Uninstall** — and the bottom line explains whatever is selected.

Select **Install <app>**. Progress and per-step results appear in the lower
pane. If the application needs an official (e.g. DoD PKI) certificate, a
plain-language "next steps" page appears when the install finishes — it names
the exact files to request, where to put them, and the one command to run.
The same page is saved to `/opt/sc2/NEXT-STEPS.txt` and can be reopened any
time from the menu (**Certificate setup guide**) or with
`sudo ./sc2 certs guide`.

### Non-interactive

```
sudo ./sc2 install -y
```

### What install does (in order)

1. **Preflight** — verifies OS/arch, bundle integrity (sha256), disk space,
   `noexec` mount traps, SELinux/FIPS status, and validates `bundle.conf`.
   Nothing is modified if preflight fails.
2. **Packages** — installs missing RPMs from the bundle's offline repo for
   your RHEL major (`rpms/el7|el8|el9`). No network access is attempted.
3. **Container runtime** — Docker on RHEL 7, Podman on RHEL 8/9 (a Docker
   engine that is already running is adopted instead). Enabled at boot.
4. **SC2 payload** — installs SC2 itself to `/opt/sc2` (the systemd units run
   it) and, on fapolicyd-protected hosts, registers it as trusted.
5. **Bundle directives** — applies `bundle.conf` (`copy`, `mkdir`, `port`).
6. **Images** — loads application images from `images/` and every archive
   from `containers/` (auto-detected).
7. **Applications** — converts each `apps/<name>` compose file to an
   orchestrator spec, deploys it as a systemd unit `sc2-<name>.service`, and
   opens its firewall ports. SC2 orchestrates the containers directly; there
   is no compose binary or engine API socket involved.
8. **Hooks** — runs `bundle.conf` `run` commands.
9. **Verify** — waits until every unit is active with containers running.

## 3. Confirm it worked

```
sudo ./sc2 status
systemctl status sc2-<app>.service
```

## Security posture notes

- SELinux is **never** modified; it stays enforcing.
- FIPS mode is supported and reported in preflight.
- The firewall backend is auto-detected (firewalld, iptables, or nftables).
  If none is active, port rules are skipped with a warning — this is reported,
  not hidden.
- Every change SC2 makes (packages, units, ports, images, copied files) is
  recorded in `/etc/sc2/ledger`.

## If something fails

- Full detail is in `/var/log/sc2/sc2.log`.
- Preflight failures name the exact problem (disk space, noexec mount,
  unsupported OS, corrupted bundle). Fix and re-run — install is idempotent.
- See `docs/OPERATIONS.md` for the troubleshooting matrix.
