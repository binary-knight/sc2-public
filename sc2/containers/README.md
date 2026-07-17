# containers/

Drop container image archives here (`docker save ... | gzip > name.tgz`)
before bundling. Every `*.tgz` / `*.tar` / `*.tar.gz` in this directory is
auto-detected and loaded into the container runtime during `sc2 install` and
`sc2 upgrade` — no manifest required.

Use this for images that applications reference at runtime or that operators
run by hand. Images that belong to a managed compose stack should instead be
listed in that app's `apps/<name>/manifest` (`APP_IMAGES=`), which also lives
alongside a `docker-compose.yml` and gets a systemd unit.
