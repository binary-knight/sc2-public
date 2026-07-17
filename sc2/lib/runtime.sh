# shellcheck shell=bash
# runtime.sh - container engine handling (docker on el7, podman on el8/9).
# SC2 orchestrates the engine CLI directly (lib/orchestrator.sh); there is no
# compose binary, no API socket, and no daemon dependency beyond the engine
# itself.

runtime_required_pkgs() {
    if [ "$ENGINE" = docker ]; then
        echo "docker-ce docker-ce-cli containerd.io container-selinux"
    else
        echo "podman container-selinux"
    fi
}

runtime_install() {
    rpm_repo_setup
    # shellcheck disable=SC2046  # word splitting intended
    rpm_install $(runtime_required_pkgs)
    rpm_repo_teardown
}

runtime_enable() {
    if [ "$ENGINE" = docker ]; then
        run_cmd "enable docker daemon" systemctl enable --now docker
    fi
    detect_engine
    [ "$ENGINE_PRESENT" = 1 ] || die "container engine '$ENGINE' is not available after install"
    ui_ok "Container runtime ready: $ENGINE $ENGINE_VERSION"
}

# Install SC2 itself to a stable path: the systemd units run
# /opt/sc2/sc2 app-start <name>, which must work after the unpacked bundle
# directory is deleted.
payload_install() {
    mkdir -p "$SC2_INSTALL_DIR/lib" "$SC2_INSTALL_DIR/apps" "$SC2_STATE_DIR/apps"
    ledger_add dir "$SC2_INSTALL_DIR"
    install -m 0755 "$SC2_ROOT/sc2" "$SC2_INSTALL_DIR/sc2"
    install -m 0644 "$SC2_ROOT/lib/"*.sh "$SC2_INSTALL_DIR/lib/"
    install -m 0644 "$SC2_ROOT/VERSION" "$SC2_INSTALL_DIR/VERSION"
    ui_ok "SC2 payload installed to $SC2_INSTALL_DIR"
}

# On fapolicyd (RHEL 8/9 STIG) hosts, untrusted files are denied execution.
# Register the installed SC2 files or the systemd units cannot run them.
trust_binaries() {
    [ "$FAPOLICYD" = active ] || return 0
    local f failed=0
    for f in "$SC2_INSTALL_DIR/sc2" "$SC2_INSTALL_DIR/lib/"*.sh; do
        if fapolicyd-cli --file add "$f" >/dev/null 2>&1; then
            ledger_add trust "$f"
        else
            failed=1
        fi
    done
    fapolicyd-cli --update >/dev/null 2>&1 || true
    if [ "$failed" = 0 ]; then
        ui_ok "Registered SC2 with fapolicyd"
    else
        ui_warn "Some SC2 files could not be registered with fapolicyd - units may be blocked"
    fi
}

untrust_binaries() {
    local t had=0
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        had=1
        fapolicyd-cli --file delete "$t" >/dev/null 2>&1 || true
    done <<< "$(ledger_get trust)"
    [ "$had" = 1 ] && fapolicyd-cli --update >/dev/null 2>&1 || true
    return 0
}

# ctr_load <archive> - load an image archive, record what got loaded.
ctr_load() {
    local archive="$1" out rc
    _logfile_write "RUN   $ENGINE load -i $archive"
    out="$("$ENGINE" load -i "$archive" 2>&1)"; rc=$?
    [ -n "$out" ] && _logfile_write "$out"
    [ "$rc" -eq 0 ] || die "image load failed for $archive (details: $SC2_LOG_FILE)"
    local ref
    while IFS= read -r ref; do
        [ -n "$ref" ] && ledger_add image "$ref"
    done <<< "$(printf '%s\n' "$out" | sed -n 's/^Loaded image[^:]*: *//p')"
}

ctr_remove_images() {
    local ref
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        "$ENGINE" rmi "$ref" >/dev/null 2>&1 || true
    done <<< "$(ledger_get image)"
}
