# SC2 Operations Guide

Day-2 reference for hosts running SC2-deployed applications.

## Command reference

```
sudo ./sc2              interactive TUI (arrows/jk, Enter, q)
sudo ./sc2 install -y   full install, no prompts
sudo ./sc2 status       detection summary + app/unit/container status
sudo ./sc2 upgrade      apply a newer unpacked bundle (see below)
sudo ./sc2 firewall     re-apply all app + bundle.conf port rules
sudo ./sc2 remove       stop and remove everything SC2 installed
sudo ./sc2 remove --purge    ... including application data volumes
./sc2 version | help
```

All verbs accept `-y`/`--yes` to skip confirmations (for scripted use).

## Where things live

| Path | What |
|---|---|
| `/opt/sc2/sc2`, `/opt/sc2/lib/` | installed SC2 (the systemd units run `sc2 app-start`) |
| `/opt/sc2/apps/<name>/` | deployed compose file, generated `app.spec`, manifest |
| `/etc/systemd/system/sc2-<name>.service` | one unit per application stack |
| `/etc/sc2/ledger` | record of every change SC2 made to this host |
| `/etc/sc2/apps/<name>.version` | installed version per app |
| `/var/log/sc2/sc2.log` | timestamped log of every SC2 run |

## Managing applications

Applications are ordinary systemd services:

```
systemctl status sc2-<name>.service
systemctl restart sc2-<name>.service      # compose down + up
journalctl -u sc2-<name>.service
```

Containers are visible to the native runtime tooling — `docker ps` on RHEL 7,
`sudo podman ps` on RHEL 8/9. Containers are named `sc2-<app>-<service>-1`
and labeled `sc2.project` / `sc2.service`. Logs:
`sudo podman logs sc2-<app>-<service>-1` (or `docker logs ...`).

Stacks start on boot via their unit and restart failed containers via the
engine `restart:` policy. `sc2 app-start <name>` is idempotent: unchanged
containers are left alone, stopped ones started, changed ones recreated.

## Upgrading

1. Transfer and unpack the new bundle tarball (do not overwrite the old
   directory; unpack alongside).
2. `cd` into the new bundle and run `sudo ./sc2 upgrade`.

Only apps whose manifest version differs are touched; their images are
loaded and only changed containers are recreated. Named volumes (application
data) persist. The old bundle directory can be deleted afterwards.

## Removing

`sudo ./sc2 remove` replays the ledger in reverse: stops and deletes units,
closes firewall ports, removes loaded images, deletes copied files
(`bundle.conf`), and removes `/opt/sc2`. Data volumes and RPMs installed as
dependencies are **kept** (other software may rely on the packages; volumes
may hold mission data). `remove --purge` also deletes the data volumes.

## Certificates

Apps that declare `APP_TLS` get SC2-issued certificates (from the local CA at
`/etc/sc2/pki/ca.crt`) mounted at `/run/sc2/tls` in their containers.

```
sudo ./sc2 certs doctor                 diagnose installed certs + live TLS
                                        endpoints, with plain-language fixes
sudo ./sc2 certs doctor file.p12 --password X
                                        pre-check a received certificate file
                                        BEFORE importing (password, key match,
                                        dates, names, chain)
sudo ./sc2 certs guide                  plain-language next-steps for official
                                        certs (also at /opt/sc2/NEXT-STEPS.txt)
sudo ./sc2 certs status                 CA + per-service expiry overview
sudo ./sc2 certs rotate                 re-issue all SC2-issued certs, recreate
                                        only the affected containers
sudo ./sc2 certs import <app> <svc> cert.p12 --password X
sudo ./sc2 certs import <app> <svc> combined.pem
sudo ./sc2 certs import <app> <svc> --cert c.pem --key k.pem --chain chain.pem
```

`import` installs an externally-issued certificate (e.g. DoD PKI) for one
service: format is auto-detected, the key is checked against the certificate
(a mismatch is rejected before anything is touched), expired certs are
refused, and the app is redeployed. Imported certs are marked and survive
`certs rotate`. To make clients trust internal endpoints, distribute
`/etc/sc2/pki/ca.crt` (it is world-readable by design; only the CA key is
secret).

The CA survives `remove` so a reinstall keeps the same trust anchor;
`remove --purge` deletes it (and any imported certs under `/opt/sc2`) —
keep the original issued files if you may need them again.

## Troubleshooting

Start with: `sudo ./sc2 certs doctor` (also in the menu as **Run
diagnostics**), then `sudo ./sc2 status` and `/var/log/sc2/sc2.log` (every
failed command's output is captured there).

If support needs to look at it: `sudo ./sc2 support-bundle` (menu: **Create
support file**) writes a single tarball to `/var/tmp/` containing logs,
status, unit journals, container state, SELinux/fapolicyd denials and public
certificates — never private keys, and passwords are scrubbed from logs.
Send that file to your support contact.

| Symptom | Likely cause / fix |
|---|---|
| Preflight: "bundle integrity check failed" | Tarball corrupted or modified in transfer. Re-transfer; compare `sha256sum` of the tarball itself with the source. |
| Preflight: "mounted noexec" | STIG partitioning mounts `/var` noexec; container storage cannot execute there. Remount or relocate container storage. |
| Install: "packages required but not installed ... no RPM bundle" | Bundle built without the RPM closure for this RHEL major. Rebuild bundle (see docs/BUNDLING.md). |
| Unit active but app unreachable from another host | Port not open (`sudo ./sc2 firewall`, then check `firewall-cmd --list-ports`), or no firewall was active at install (warned at install time). |
| Containers exit immediately on RHEL 8/9 STIG hosts | fapolicyd may be denying execution. Check `journalctl -u fapolicyd`; SC2 registers its own binaries, but binaries inside *your* artifacts may need `fapolicyd-cli --file add <path>`. |
| "Permission denied" on bind-mounted files, SELinux host | Missing `:Z`/`:z` on the bind mount in the compose file. Never disable SELinux; fix the label. |
| Preflight: "unsupported docker-compose.yml" | The compose file uses a key outside the supported subset (see docs/BUNDLING.md). The error names the line; fix the file in the bundle. |
| `sc2-<name>.service` fails at boot, works when started manually | On RHEL 7 verify `systemctl is-enabled docker.service`; on any OS check `journalctl -u sc2-<name>` — the orchestrator logs each service decision. |
| Image load fails in FIPS mode | Some images ship crypto that violates FIPS (old OpenSSL). This is an image problem — rebuild the image with FIPS-compatible libraries. |
| TUI looks wrong / garbled borders | Non-UTF-8 locale gets an ASCII fallback automatically; if the layout itself is broken the terminal is under 60 columns — use CLI verbs. |

## The ledger

`/etc/sc2/ledger` is line-oriented `type|value` — one line per change SC2 made
(`rpm`, `unit`, `port`, `image`, `file`, `mkdir`, `dir`, `trust`). It exists so
`remove` deletes exactly what SC2 created and nothing else. Do not edit it by
hand; if it is lost, `remove` cannot clean up automatically and you must
remove units/ports/images manually.

## Audit trail

Every run appends to `/var/log/sc2/sc2.log` with timestamps, including the
full output of every command SC2 executed — suitable as an install/change
record for accreditation evidence.
