#!/usr/bin/env bash
#
# build-bundle.sh - assemble the shippable SC2 tarball.
#
# PACKAGES what is already in this tree (rpms/, images/, containers/, apps/,
# artifacts/, docs/) into dist/sc2-<version>-x86_64.tgz with a sha256 manifest.
# Requires only bash + tar; runs fully offline.
#
#   build/build-bundle.sh                package the tree as-is
#   build/build-bundle.sh --fetch        run build/fetch-artifacts.sh first to
#                                        pull RPMs/images/artifacts, then package
#                                        (needs internet + podman/docker)
#
# The tree is populated by build/fetch-artifacts.sh from build.conf - that is
# where the RPM package sets, container images, and artifact payloads (and their
# source locations) are declared. See docs/BUILDING.md for the full workflow and
# docs/BUNDLING.md for the RPM closure caveats.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
VERSION="$(cat "$ROOT/VERSION")"
OUT="${OUT:-$ROOT/dist}"

say() { printf '\n==> %s\n' "$*"; }

# --- packaging ---------------------------------------------------------------
preflight_tree() {
    say "Checking the tree"
    local major ok=1 f
    for f in sc2 lib/cli.sh bundle.conf VERSION; do
        [ -e "$ROOT/$f" ] || { echo "missing: $f" >&2; ok=0; }
    done
    for major in 7 8 9 10; do
        if ls "$ROOT/rpms/el${major}"/*.rpm >/dev/null 2>&1; then
            [ -d "$ROOT/rpms/el${major}/repodata" ] \
                || { echo "rpms/el${major} has RPMs but no repodata/ (run createrepo)" >&2; ok=0; }
            printf '  el%-3s %s RPMs\n' "$major" "$(ls "$ROOT/rpms/el${major}"/*.rpm | wc -l)"
        else
            printf '  el%-3s EMPTY - installs on RHEL %s will need the runtime preinstalled\n' "$major" "$major"
        fi
    done
    local app img
    for app in "$ROOT"/apps/*/manifest; do
        [ -f "$app" ] || continue
        # shellcheck source=/dev/null
        ( . "$app"
          for img in $APP_IMAGES; do
              [ -f "$ROOT/images/$img" ] || { echo "missing image archive for $APP_NAME: images/$img" >&2; exit 1; }
          done ) || ok=0
    done
    for f in "$ROOT"/sc2 "$ROOT"/lib/*.sh; do
        bash -n "$f" || ok=0
    done
    [ "$ok" = 1 ] || { echo "tree checks failed" >&2; exit 1; }
    echo "  tree OK"
}

checksums_and_tar() {
    say "Writing sha256sums"
    ( cd "$ROOT" && find images containers artifacts rpms apps lib docs sc2 VERSION bundle.conf README.md \
        -type f ! -name sha256sums -print0 2>/dev/null \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum > sha256sums )
    say "Creating tarball"
    mkdir -p "$OUT"
    local name="sc2-${VERSION}-x86_64"
    tar -C "$(dirname "$ROOT")" -czf "$OUT/${name}.tgz" \
        --exclude "$(basename "$ROOT")/dist" \
        --exclude "$(basename "$ROOT")/build" \
        --exclude "$(basename "$ROOT")/.git" \
        --transform "s|^$(basename "$ROOT")|${name}|" "$(basename "$ROOT")"
    ( cd "$OUT" && sha256sum "${name}.tgz" > "${name}.tgz.sha256" )
    say "Bundle ready:"
    ls -lh "$OUT/${name}.tgz" | awk '{print "   "$NF"  ("$5")"}'
    echo "   verify on the target with: sha256sum -c ${name}.tgz.sha256"
}

if [ "${1:-}" = "--fetch" ]; then
    "$HERE/fetch-artifacts.sh"
fi
preflight_tree
checksums_and_tar
