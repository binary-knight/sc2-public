# shellcheck shell=bash
# apps.sh - application lifecycle: load images, deploy compose stacks as
# systemd units, verify, upgrade, remove.
#
# An "app" is a directory under apps/ containing:
#   manifest            bash-sourceable: APP_NAME, APP_VERSION, APP_PORTS, APP_IMAGES
#   docker-compose.yml  the stack definition

APP_NAME=""
APP_VERSION=""
APP_PORTS=""
APP_IMAGES=""
APP_TLS=""
APP_PKI=""
APP_DESC=""

apps_available() {
    local m
    for m in "$SC2_ROOT"/apps/*/manifest; do
        [ -f "$m" ] && basename "$(dirname "$m")"
    done
    return 0
}

apps_installed() {
    local v
    for v in "$SC2_STATE_DIR"/apps/*.version; do
        [ -f "$v" ] && basename "$v" .version
    done
    return 0
}

app_load_manifest() {  # <app-dir>
    APP_NAME="" APP_VERSION="" APP_PORTS="" APP_IMAGES="" APP_TLS="" APP_PKI="" APP_DESC=""
    local _stale
    _stale="$(compgen -v | grep '^APP_TLS_SANS_' || true)"
    # shellcheck disable=SC2086
    [ -n "$_stale" ] && unset $_stale
    # shellcheck source=/dev/null
    . "$1/manifest"
    [ -n "$APP_NAME" ] || die "manifest in $1 does not set APP_NAME"
    [ -n "$APP_VERSION" ] || die "manifest in $1 does not set APP_VERSION"
}

app_installed_version() {  # <name>
    cat "$SC2_STATE_DIR/apps/$1.version" 2>/dev/null
    return 0
}

# Load every image archive referenced by the app manifests (falls back to
# every images/*.tgz if a manifest doesn't list its images).
images_load_all() {
    local files=() app f i n
    for app in $(apps_available); do
        app_load_manifest "$SC2_ROOT/apps/$app"
        for f in $APP_IMAGES; do
            files+=("$SC2_ROOT/images/$f")
        done
    done
    if [ "${#files[@]}" -eq 0 ]; then
        for f in "$SC2_ROOT"/images/*.tgz "$SC2_ROOT"/images/*.tar; do
            [ -f "$f" ] && files+=("$f")
        done
    fi
    if [ "${#files[@]}" -eq 0 ]; then
        ui_warn "No container image archives found in images/"
        return 0
    fi
    n="${#files[@]}"; i=0
    for f in "${files[@]}"; do
        [ -f "$f" ] || die "image archive missing from bundle: $f"
        i=$(( i + 1 ))
        ui_progress "$(( i - 1 ))" "$n" "Loading $(basename "$f")"
        ctr_load "$f"
        ui_progress "$i" "$n" "Loaded $(basename "$f")"
    done
    ui_ok "Loaded $n image archive(s)"
}

_app_unit_write() {  # <name>
    local name="$1"
    local unit="/etc/systemd/system/sc2-${name}.service"
    local dep_lines=""

    if [ "$ENGINE" = docker ]; then
        dep_lines="After=network-online.target docker.service
Requires=docker.service"
    else
        # podman is daemonless - nothing to depend on beyond the network
        dep_lines="After=network-online.target"
    fi

    cat > "$unit" <<EOF
# Managed by SC2 (Simple Container Carrier) - do not edit by hand.
[Unit]
Description=SC2 application stack: ${name}
Wants=network-online.target
${dep_lines}

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=600
ExecStart=$SC2_INSTALL_DIR/sc2 app-start ${name}
ExecStop=$SC2_INSTALL_DIR/sc2 app-stop ${name}

[Install]
WantedBy=multi-user.target
EOF
    ledger_add unit "sc2-${name}.service"
}

app_deploy() {  # <app-subdir-name>
    local name="$1" src="$SC2_ROOT/apps/$1" dst="$SC2_INSTALL_DIR/apps/$1"
    app_load_manifest "$src"
    [ -f "$src/docker-compose.yml" ] || die "app '$name' has no docker-compose.yml"

    mkdir -p "$dst"
    cp -a "$src/." "$dst/"
    ledger_add dir "$dst"

    # convert compose -> spec now, so a bad file fails the deploy, not a
    # 3am unit start
    rm -f "$dst/app.spec"
    compose_to_spec "$dst/docker-compose.yml" "$dst/app.spec"

    # issue TLS material for APP_TLS services before the stack starts
    certs_ensure_app "$dst"

    local port
    for port in $APP_PORTS; do
        fw_open "$port"
    done

    _app_unit_write "$APP_NAME"
    run_cmd "systemd reload" systemctl daemon-reload
    run_cmd "start stack $APP_NAME" systemctl enable --now "sc2-${APP_NAME}.service"

    mkdir -p "$SC2_STATE_DIR/apps"
    printf '%s\n' "$APP_VERSION" > "$SC2_STATE_DIR/apps/${APP_NAME}.version"
    ui_ok "Deployed $APP_NAME $APP_VERSION"
}

apps_deploy_all() {
    local apps=() app i n
    for app in $(apps_available); do apps+=("$app"); done
    if [ "${#apps[@]}" -eq 0 ]; then
        ui_warn "No applications found in apps/"
        return 0
    fi
    n="${#apps[@]}"; i=0
    for app in "${apps[@]}"; do
        i=$(( i + 1 ))
        ui_progress "$(( i - 1 ))" "$n" "Deploying $app"
        app_deploy "$app"
    done
    ui_progress "$n" "$n" "All applications deployed"
}

# images referenced by one app's manifest (used by per-app install)
app_load_images() {  # <app-subdir>
    local src="$SC2_ROOT/apps/$1" f
    app_load_manifest "$src"
    for f in $APP_IMAGES; do
        [ -f "$SC2_ROOT/images/$f" ] || die "image archive missing from bundle: images/$f"
        ctr_load "$SC2_ROOT/images/$f"
    done
}

app_uninstall() {  # <app-subdir-name>
    local name="$1"
    local dst="$SC2_INSTALL_DIR/apps/$name"
    [ -d "$dst" ] || die "app '$name' is not installed"
    confirm "Uninstall $name? (its saved data is kept unless you chose purge)" \
        || { ui_log "Uninstall cancelled"; return 1; }
    ui_log "Stopping $name"
    systemctl disable --now "sc2-${name}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/sc2-${name}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$PURGE_DATA" = 1 ]; then
        orch_down "$name" "$dst" purge
    else
        orch_down "$name" "$dst"
    fi
    if [ -f "$dst/manifest" ]; then
        app_load_manifest "$dst"
        local port
        for port in $APP_PORTS; do
            fw_close "$port"
        done
    fi
    rm -rf "$dst"
    rm -f "$SC2_STATE_DIR/apps/${name}.version"
    certs_write_next_steps
    ui_ok "$name uninstalled (shared runtime and other apps untouched)"
}

app_verify() {  # <name> - wait until the stack's containers are up
    local name="$1" tries=0 running
    while [ "$tries" -lt 30 ]; do
        running="$("$ENGINE" ps --filter "label=sc2.project=sc2-${name}" --format '{{.ID}}' 2>/dev/null | wc -l)"
        if [ "${running:-0}" -gt 0 ] && systemctl is-active "sc2-${name}.service" >/dev/null 2>&1; then
            ui_ok "$name: unit active, $running container(s) running"
            return 0
        fi
        tries=$(( tries + 1 ))
        sleep 1
    done
    die "$name failed verification - unit or containers not running (systemctl status sc2-${name})"
}

apps_verify_all() {
    local app
    for app in $(apps_installed); do
        app_verify "$app"
    done
}

apps_upgrade() {
    local app changed=0 cur new
    for app in $(apps_available); do
        app_load_manifest "$SC2_ROOT/apps/$app"
        cur="$(app_installed_version "$APP_NAME")"
        new="$APP_VERSION"
        if [ "$cur" = "$new" ]; then
            ui_ok "$APP_NAME already at $new"
            continue
        fi
        changed=1
        if [ -n "$cur" ]; then
            ui_log "Upgrading $APP_NAME: $cur -> $new"
        else
            ui_log "Installing new app $APP_NAME $new"
        fi
        local f
        for f in $APP_IMAGES; do
            ctr_load "$SC2_ROOT/images/$f"
        done
        app_deploy "$app"
        # in-place minimal update: only services whose config hash changed
        # are recreated; volumes persist. (The unit stays active; app-start
        # is idempotent against this state.)
        orch_up "$APP_NAME" "$SC2_INSTALL_DIR/apps/$app"
        app_verify "$APP_NAME"
    done
    [ "$changed" = 0 ] && ui_ok "Everything already up to date"
    return 0
}

apps_status() {
    local app v unit state running
    printf '\n%-16s %-10s %-12s %s\n' "APP" "VERSION" "UNIT" "CONTAINERS"
    for app in $(apps_installed); do
        v="$(app_installed_version "$app")"
        unit="sc2-${app}.service"
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        running="$("$ENGINE" ps --filter "label=sc2.project=sc2-${app}" --format '{{.Names}} ({{.Status}})' 2>/dev/null | paste -sd ', ' -)"
        printf '%-16s %-10s %-12s %s\n' "$app" "$v" "${state:-unknown}" "${running:-none}"
    done
    [ -z "$(apps_installed)" ] && printf '(no applications installed)\n'
    return 0
}

sc2_remove_all() {
    confirm "Remove all SC2 applications, units, firewall rules and images from this system?" || { ui_log "Remove cancelled"; return 1; }

    local app unit dst
    for app in $(apps_installed); do
        dst="$SC2_INSTALL_DIR/apps/$app"
        if [ "$PURGE_DATA" = 1 ] && [ -d "$dst" ]; then
            ui_log "Purging $app (including data volumes)"
            orch_down "$app" "$dst" purge
        fi
    done

    local u
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        ui_log "Removing unit $u"
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"
    done <<< "$(ledger_get unit)"
    systemctl daemon-reload >/dev/null 2>&1 || true

    fw_close_all
    ctr_remove_images
    untrust_binaries
    bundle_remove

    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$d" in
            "$SC2_INSTALL_DIR"*) rm -rf "$d" ;;
            *) ui_warn "refusing to delete unexpected ledger path: $d" ;;
        esac
    done <<< "$(ledger_get dir)"

    local rpms
    rpms="$(ledger_get rpm | paste -sd ' ' -)"
    [ -n "$rpms" ] && ui_log "Leaving installed packages in place (other software may use them): $rpms"

    rm -rf "$SC2_STATE_DIR/apps"
    if [ "$PURGE_DATA" = 1 ]; then
        rm -rf "$CERTS_PKI_DIR"
    elif [ -d "$CERTS_PKI_DIR" ]; then
        ui_log "Keeping SC2 CA at $CERTS_PKI_DIR (stable trust anchor for reinstalls; remove --purge deletes it)"
    fi
    ledger_clear
    rmdir "$SC2_STATE_DIR" 2>/dev/null || true
    if [ "$PURGE_DATA" = 1 ]; then
        ui_ok "SC2 removed (including application data volumes)"
    else
        ui_ok "SC2 removed (application data volumes preserved; use 'remove --purge' to delete them)"
    fi
}
