#!/usr/bin/env bash
#
# fetch-artifacts.sh - populate the SC2 tree from build.conf.
#
# Pulls everything the shippable bundle needs from the locations declared in
# build.conf, so a fresh `git clone` (which carries only source) can be turned
# into a full offline bundle. After this runs, build/build-bundle.sh packages
# the tree into dist/sc2-<version>-x86_64.tgz.
#
#   build/fetch-artifacts.sh                 fetch everything for the profile
#   SC2_PROFILE=work build/fetch-artifacts.sh  use the 'work' profile
#   build/fetch-artifacts.sh --dry-run        print what would be fetched, do nothing
#   build/fetch-artifacts.sh --force          re-fetch even if files already exist
#   build/fetch-artifacts.sh --rpms-only      only build RPM closures
#   build/fetch-artifacts.sh --images-only    only pull+save container images
#   build/fetch-artifacts.sh --artifacts-only only fetch bundle 'copy' payloads
#
# Requires: bash, curl, tar, and podman or docker (for RPM closures + images).
# See docs/BUILDING.md for the full workflow and docs/BUNDLING.md for the RPM
# closure caveats (they are unchanged by this script - it just makes the
# fetch locations explicit in build.conf).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

# shellcheck source=/dev/null
. "$ROOT/build.conf"

FORCE=0 DRYRUN=0 DO_RPMS=1 DO_IMAGES=1 DO_ARTIFACTS=1
only=""
for arg in "$@"; do
    case "$arg" in
        --force)          FORCE=1 ;;
        --dry-run|-n)     DRYRUN=1 ;;
        --rpms-only)      only=rpms ;;
        --images-only)    only=images ;;
        --artifacts-only) only=artifacts ;;
        -h|--help)        sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
if [ -n "$only" ]; then
    DO_RPMS=0 DO_IMAGES=0 DO_ARTIFACTS=0
    case "$only" in rpms) DO_RPMS=1;; images) DO_IMAGES=1;; artifacts) DO_ARTIFACTS=1;; esac
fi

say() { printf '\n==> %s\n' "$*"; }
run() { if [ "$DRYRUN" = 1 ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

CTR=""
need_ctr() {
    [ -n "$CTR" ] && return 0
    CTR="$(command -v podman || command -v docker || true)"
    [ -n "$CTR" ] || { echo "need podman or docker to fetch RPMs/images" >&2; exit 1; }
}

# --- RPM closures -----------------------------------------------------------
# Resolve the full dependency set for RPMS_EL<major> inside BASEIMG_EL<major>
# and write it (plus repodata/) into rpms/el<major>. If RPM_MIRROR_BASE is set
# (work profile), point the build container at that internal mirror instead of
# the image's own repos.
build_closure() {
    local major="$1"
    local dest="$ROOT/rpms/el${major}"
    local pkgvar="RPMS_EL${major}" imgvar="BASEIMG_EL${major}"
    local pkgs="${!pkgvar:-}" image="${!imgvar:-}"

    [ -n "$pkgs" ] || { say "el${major}: RPMS_EL${major} empty - skipping"; return 0; }
    [ -n "$image" ] || { echo "el${major}: BASEIMG_EL${major} not set in build.conf" >&2; return 1; }
    if [ -d "$dest/repodata" ] && [ "$FORCE" != 1 ]; then
        say "el${major}: closure already present - skipping (use --force to rebuild)"
        return 0
    fi

    local mirror=""
    [ -n "${RPM_MIRROR_BASE:-}" ] && mirror="${RPM_MIRROR_BASE%/}/el${major}"

    say "el${major}: closure from $image [${mirror:-image repos}]: $pkgs"
    if [ "$DRYRUN" = 1 ]; then printf '   [dry-run] would build el%s closure into %s\n' "$major" "$dest"; return 0; fi

    need_ctr
    mkdir -p "$dest"
    case "$major" in
        7)
            "$CTR" run --rm -e "PKGS=$pkgs" -e "MIRROR=$mirror" -v "$dest:/out:z" "$image" bash -ec '
                if [ -n "$MIRROR" ]; then
                    printf "[sc2-mirror]\nname=sc2-mirror\nbaseurl=%s\nenabled=1\ngpgcheck=0\n" "$MIRROR" > /etc/yum.repos.d/sc2-mirror.repo
                    yum -y -q --disablerepo="*" --enablerepo="sc2-mirror" install yum-utils createrepo
                    yumdownloader --disablerepo="*" --enablerepo="sc2-mirror" --resolve --destdir=/out $PKGS
                else
                    # CentOS 7 is EOL: point yum at the vault, add the docker-ce repo.
                    sed -i -e "s|^mirrorlist=|#mirrorlist=|" -e "s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|" /etc/yum.repos.d/CentOS-Base.repo
                    yum -y -q install yum-utils createrepo curl
                    curl -fsSL -o /etc/yum.repos.d/docker-ce.repo https://download.docker.com/linux/centos/docker-ce.repo
                    yumdownloader --resolve --destdir=/out $PKGS
                fi
                createrepo /out
            '
            ;;
        8|9|10)
            "$CTR" run --rm -e "PKGS=$pkgs" -e "MIRROR=$mirror" -v "$dest:/out:z" "$image" bash -ec '
                dnf -y -q install dnf-plugins-core createrepo_c
                if [ -n "$MIRROR" ]; then
                    printf "[sc2-mirror]\nname=sc2-mirror\nbaseurl=%s\nenabled=1\ngpgcheck=0\nmodule_hotfixes=1\n" "$MIRROR" > /etc/yum.repos.d/sc2-mirror.repo
                    dnf --disablerepo="*" --enablerepo="sc2-mirror" download --resolve --alldeps --destdir /out $PKGS
                else
                    dnf download --resolve --alldeps --destdir /out $PKGS
                fi
                createrepo_c /out
            '
            ;;
        *) echo "el${major}: unsupported major" >&2; return 1 ;;
    esac
    printf '   el%-3s %s RPMs\n' "$major" "$(ls "$dest"/*.rpm 2>/dev/null | wc -l)"
}

fetch_rpms() {
    say "RPM closures (majors: $SC2_MAJORS)"
    local m
    for m in $SC2_MAJORS; do build_closure "$m"; done
}

# --- container images -------------------------------------------------------
# Pull ${IMAGE_REGISTRY}/<ref>, retag as <save-tag>, save gzip'd to <dest>.
fetch_images() {
    say "Container images (registry: ${IMAGE_REGISTRY:-<none>})"
    local row ref dest tag full
    while IFS='|' read -r ref dest tag; do
        ref="$(echo "$ref" | xargs)"; dest="$(echo "$dest" | xargs)"; tag="$(echo "$tag" | xargs)"
        [ -n "$ref" ] || continue
        local out="$ROOT/$dest"
        if [ -f "$out" ] && [ "$FORCE" != 1 ]; then
            printf '   have %s (skip)\n' "$dest"; continue
        fi
        full="${IMAGE_REGISTRY:+$IMAGE_REGISTRY/}$ref"
        say "image: $full -> $dest  (as $tag)"
        if [ "$DRYRUN" = 1 ]; then continue; fi
        need_ctr
        mkdir -p "$(dirname "$out")"
        "$CTR" pull "$full"
        "$CTR" tag "$full" "$tag"
        "$CTR" save "$tag" | gzip -c > "$out"
        printf '   wrote %s (%s)\n' "$dest" "$(du -h "$out" | cut -f1)"
    done <<< "$(printf '%s\n' "$IMAGES" | grep -v '^[[:space:]]*$')"
}

# --- bundle 'copy' artifact payloads ---------------------------------------
fetch_artifacts() {
    [ -n "${ARTIFACTS:-}" ] && [ -n "$(printf '%s' "$ARTIFACTS" | tr -d '[:space:]')" ] || {
        say "Artifact payloads: none declared (artifacts/app sample is in git)"; return 0; }
    say "Artifact payloads"
    local src dest out
    while IFS='|' read -r src dest; do
        src="$(echo "$src" | xargs)"; dest="$(echo "$dest" | xargs)"
        [ -n "$src" ] || continue
        out="$ROOT/artifacts/$dest"
        if [ -e "$out" ] && [ "$FORCE" != 1 ]; then printf '   have %s (skip)\n' "$dest"; continue; fi
        say "artifact: $src -> artifacts/$dest"
        if [ "$DRYRUN" = 1 ]; then continue; fi
        mkdir -p "$(dirname "$out")"
        case "$src" in
            file://*) cp -a "${src#file://}" "$out" ;;
            http://*|https://*)
                # GitLab generic-package pulls authenticate via a job/PAT token
                if [ -n "${SC2_GITLAB_TOKEN:-${CI_JOB_TOKEN:-}}" ] && [[ "$src" == *"/packages/generic/"* ]]; then
                    curl -fSL --header "JOB-TOKEN: ${SC2_GITLAB_TOKEN:-$CI_JOB_TOKEN}" -o "$out" "$src"
                else
                    curl -fSL -o "$out" "$src"
                fi ;;
            *) cp -a "$src" "$out" ;;
        esac
        printf '   wrote artifacts/%s\n' "$dest"
    done <<< "$(printf '%s\n' "$ARTIFACTS" | grep -v '^[[:space:]]*$')"
}

say "SC2 fetch  profile=$SC2_PROFILE  force=$FORCE  dry-run=$DRYRUN"
[ "$DO_RPMS" = 1 ]      && fetch_rpms
[ "$DO_IMAGES" = 1 ]    && fetch_images
[ "$DO_ARTIFACTS" = 1 ] && fetch_artifacts
say "Fetch complete. Next: build/build-bundle.sh"
