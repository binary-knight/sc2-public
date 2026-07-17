# shellcheck shell=bash
# orchestrator.sh - SC2's built-in single-host orchestrator. Replaces
# docker-compose: drives the container engine CLI directly, so the exact same
# logic runs on Docker (RHEL 7) and Podman (RHEL 8/9) with no API socket, no
# third-party binary, and no python.
#
# Model, per app:
#   network   sc2-<app>            one isolated network; services resolve each
#                                  other by service name (network alias)
#   volumes   sc2-<app>_<vol>      named volumes from the spec
#   container sc2-<app>-<svc>-1    labeled sc2.project / sc2.service / sc2.hash
#
# Idempotent up: each container's full run-configuration is hashed (including
# the image ID). Unchanged+running is left alone, unchanged+stopped is
# started, changed is recreated. That is what makes upgrades minimal.

orch_svcvar() {  # <service> <KEY>
    local v="SVC_${1//[!a-zA-Z0-9_]/_}_$2"
    eval "printf '%s' \"\${$v:-}\""
}

orch_load_spec() {  # <appdir>
    local appdir="$1" stale
    local spec="$appdir/app.spec"
    if [ ! -f "$spec" ]; then
        [ -f "$appdir/docker-compose.yml" ] || die "no app.spec or docker-compose.yml in $appdir"
        compose_to_spec "$appdir/docker-compose.yml" "$spec"
    fi
    # clear any SVC_ globals left from a previously loaded app
    stale="$(compgen -v | grep '^SVC_' || true)"
    # shellcheck disable=SC2086
    [ -n "$stale" ] && unset $stale
    SPEC_SERVICES="" SPEC_VOLUMES=""
    # shellcheck source=/dev/null
    . "$spec"
    [ -n "$SPEC_SERVICES" ] || die "spec has no services: $spec"
}

# dependency-ordered service list (dies on cycles)
orch_order() {
    local remaining=() ordered=() next=() svc dep ok progressed
    # shellcheck disable=SC2206
    remaining=($SPEC_SERVICES)
    while [ "${#remaining[@]}" -gt 0 ]; do
        progressed=0
        next=()
        for svc in "${remaining[@]}"; do
            ok=1
            for dep in $(orch_svcvar "$svc" DEPENDS); do
                case " ${ordered[*]:-} " in
                    *" $dep "*) : ;;
                    *) ok=0 ;;
                esac
            done
            if [ "$ok" = 1 ]; then
                ordered+=("$svc"); progressed=1
            else
                next+=("$svc")
            fi
        done
        if [ "$progressed" = 0 ]; then
            die "dependency cycle (or unknown depends_on target) among: ${remaining[*]}"
        fi
        remaining=(${next[@]+"${next[@]}"})
    done
    printf '%s\n' "${ordered[@]}"
}

# resolve a compose volume entry to engine syntax
_orch_volume_arg() {  # <app> <appdir> <entry>
    local app="$1" appdir="$2" entry="$3" src rest
    src="${entry%%:*}"
    rest="${entry#*:}"
    case "$src" in
        /*)   printf '%s' "$entry" ;;                              # absolute bind
        ./*)  printf '%s:%s' "$appdir/${src#./}" "$rest" ;;        # bundle-relative bind
        *)    printf 'sc2-%s_%s:%s' "$app" "$src" "$rest" ;;       # named volume
    esac
}

orch_service_up() {  # <app> <appdir> <service>
    local app="$1" appdir="$2" svc="$3"
    local cname="sc2-${app}-${svc}-1" net="sc2-${app}"
    local image restart user priv ep cmd env ports vols p v e

    image="$(orch_svcvar "$svc" IMAGE)"
    restart="$(orch_svcvar "$svc" RESTART)"
    user="$(orch_svcvar "$svc" USER)"
    priv="$(orch_svcvar "$svc" PRIVILEGED)"
    ep="$(orch_svcvar "$svc" ENTRYPOINT)"
    cmd="$(orch_svcvar "$svc" COMMAND)"
    env="$(orch_svcvar "$svc" ENV)"
    ports="$(orch_svcvar "$svc" PORTS)"
    vols="$(orch_svcvar "$svc" VOLUMES)"

    "$ENGINE" image inspect "$image" >/dev/null 2>&1 \
        || die "image '$image' (service $svc) is not loaded - is its archive in the bundle?"

    local args=(--name "$cname" --network "$net" --network-alias "$svc"
                --label "sc2.project=sc2-${app}" --label "sc2.service=${svc}")
    [ -n "$restart" ] && [ "$restart" != no ] && args+=(--restart "$restart")
    [ -n "$user" ] && args+=(--user "$user")
    [ "$priv" = true ] && args+=(--privileged)
    for p in $ports; do args+=(-p "$p"); done
    for v in $vols; do args+=(-v "$(_orch_volume_arg "$app" "$appdir" "$v")"); done
    if [ -n "$env" ]; then
        eval "set -- $env"
        for e in "$@"; do args+=(-e "$e"); done
    fi
    [ -n "$ep" ] && args+=(--entrypoint "$ep")

    # SC2-managed TLS material (lib/certs.sh) mounts read-only at a fixed path
    local certdir="$appdir/certs/$svc" certsum=""
    if [ -d "$certdir" ]; then
        args+=(-v "$certdir:$CERTS_MOUNT:ro,Z")
        certsum="$(cat "$certdir"/*.crt "$certdir"/tls.key 2>/dev/null | sha256sum | cut -c1-12)"
    fi

    args+=("$image")
    if [ -n "$cmd" ]; then
        eval "set -- $cmd"
        args+=("$@")
    fi

    # config hash: full argv + image ID + cert material, so spec changes,
    # same-tag image updates and cert rotation all trigger recreation
    local iid hash ehash running
    iid="$("$ENGINE" image inspect -f '{{.Id}}' "$image" 2>/dev/null)"
    hash="$(printf '%s\n' "$iid" "$certsum" "${args[@]}" | sha256sum | cut -c1-12)"

    ehash="$("$ENGINE" inspect -f '{{ index .Config.Labels "sc2.hash" }}' "$cname" 2>/dev/null || true)"
    if [ -n "$ehash" ]; then
        if [ "$ehash" = "$hash" ]; then
            running="$("$ENGINE" inspect -f '{{.State.Running}}' "$cname" 2>/dev/null)"
            if [ "$running" = "true" ]; then
                ui_log "$svc: unchanged, already running"
                return 0
            fi
            run_cmd "start $cname" "$ENGINE" start "$cname"
            ui_ok "$svc: started"
            return 0
        fi
        ui_log "$svc: configuration changed - recreating"
        "$ENGINE" rm -f "$cname" >/dev/null 2>&1 || true
    fi
    run_cmd "create $cname" "$ENGINE" run -d --label "sc2.hash=$hash" "${args[@]}"
    ui_ok "$svc: up"
}

orch_up() {  # <app> <appdir>
    local app="$1" appdir="$2" net="sc2-$1" vol svc
    orch_load_spec "$appdir"

    if ! "$ENGINE" network inspect "$net" >/dev/null 2>&1; then
        run_cmd "create network $net" "$ENGINE" network create "$net"
    fi
    for vol in $SPEC_VOLUMES; do
        "$ENGINE" volume inspect "sc2-${app}_${vol}" >/dev/null 2>&1 \
            || run_cmd "create volume sc2-${app}_${vol}" "$ENGINE" volume create "sc2-${app}_${vol}"
    done
    for svc in $(orch_order); do
        orch_service_up "$app" "$appdir" "$svc"
    done
}

orch_down() {  # <app> <appdir> [purge]
    local app="$1" appdir="$2" purge="${3:-}" ids vol
    # stop dependents first (reverse dependency order), then catch strays by label
    if [ -f "$appdir/app.spec" ]; then
        orch_load_spec "$appdir"
        local svcs=() svc i
        while IFS= read -r svc; do svcs+=("$svc"); done <<< "$(orch_order)"
        for (( i = ${#svcs[@]} - 1; i >= 0; i-- )); do
            "$ENGINE" stop "sc2-${app}-${svcs[$i]}-1" >/dev/null 2>&1 || true
            "$ENGINE" rm -f "sc2-${app}-${svcs[$i]}-1" >/dev/null 2>&1 || true
        done
    fi
    ids="$("$ENGINE" ps -aq --filter "label=sc2.project=sc2-${app}" 2>/dev/null)"
    if [ -n "$ids" ]; then
        # shellcheck disable=SC2086
        "$ENGINE" stop $ids >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        "$ENGINE" rm -f $ids >/dev/null 2>&1 || true
    fi
    "$ENGINE" network rm "sc2-${app}" >/dev/null 2>&1 || true
    if [ "$purge" = purge ] && [ -n "${SPEC_VOLUMES:-}" ]; then
        for vol in $SPEC_VOLUMES; do
            "$ENGINE" volume rm "sc2-${app}_${vol}" >/dev/null 2>&1 || true
        done
    fi
    ui_log "$app: stack down"
}

# entrypoints for the systemd units (ExecStart / ExecStop)
orch_app_start() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: sc2 app-start <app>"
    local appdir="$SC2_ROOT/apps/$name"
    [ -d "$appdir" ] || die "unknown app '$name' (no $appdir)"
    [ "$ENGINE_PRESENT" = 1 ] || die "container engine '$ENGINE' not available"
    orch_up "$name" "$appdir"
}

orch_app_stop() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: sc2 app-stop <app>"
    local appdir="$SC2_ROOT/apps/$name"
    [ -d "$appdir" ] || die "unknown app '$name' (no $appdir)"
    orch_down "$name" "$appdir"
}
