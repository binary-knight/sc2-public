# shellcheck shell=bash
# support.sh - one-command support bundle for air-gapped troubleshooting.
# Collects logs, status and configuration into a single tarball the operator
# can send back over whatever channel exists. NEVER includes private keys;
# passwords are scrubbed from logs.

support_bundle() {
    need_root
    local ts host staging out
    ts="$(date +%Y%m%d-%H%M%S)"
    host="$(hostname -s 2>/dev/null || echo host)"
    staging="$(mktemp -d)" || die "mktemp failed"
    out="/var/tmp/sc2-support-${host}-${ts}.tgz"

    ui_log "Collecting system information"
    {
        echo "SC2 version: $SC2_VERSION"
        echo "collected:   $(date)"
        echo
        uname -a
        cat /etc/os-release 2>/dev/null
    } > "$staging/system.txt"
    df -h  > "$staging/disk.txt"  2>&1 || true
    free -m > "$staging/memory.txt" 2>&1 || true

    ui_log "Collecting SC2 state"
    detect_system
    { detect_summary; echo; apps_status; echo; certs_status; } > "$staging/status.txt" 2>&1 || true
    certs_doctor > "$staging/certs-doctor.txt" 2>&1 || true
    [ -f "$SC2_LEDGER" ] && cp "$SC2_LEDGER" "$staging/ledger.txt"
    [ -f "$SC2_INSTALL_DIR/NEXT-STEPS.txt" ] && cp "$SC2_INSTALL_DIR/NEXT-STEPS.txt" "$staging/"
    # scrub anything password-shaped from the log
    [ -f "$SC2_LOG_FILE" ] && sed 's/--password[= ][^ ]*/--password ****/g' "$SC2_LOG_FILE" > "$staging/sc2.log"

    ui_log "Collecting service and container state"
    local u app
    for u in /etc/systemd/system/sc2-*.service; do
        [ -f "$u" ] || continue
        cp "$u" "$staging/" 2>/dev/null || true
        u="$(basename "$u")"
        { systemctl status "$u" --no-pager -l; echo; journalctl -u "$u" --no-pager -n 300; } \
            > "$staging/${u}.txt" 2>&1 || true
    done
    if command -v "$ENGINE" >/dev/null 2>&1; then
        {
            "$ENGINE" ps -a
            echo; "$ENGINE" images
            echo; "$ENGINE" volume ls
            echo; "$ENGINE" network ls
        } > "$staging/engine.txt" 2>&1 || true
        local ids
        ids="$("$ENGINE" ps -aq --filter label=sc2.project 2>/dev/null || true)"
        # shellcheck disable=SC2086
        [ -n "$ids" ] && "$ENGINE" inspect $ids > "$staging/containers-inspect.json" 2>&1 || true
    fi

    ui_log "Collecting security subsystem state"
    { getenforce; sestatus; } > "$staging/selinux.txt" 2>&1 || true
    ausearch -m avc -ts recent > "$staging/selinux-denials.txt" 2>&1 || true
    systemctl status fapolicyd --no-pager > "$staging/fapolicyd.txt" 2>&1 || true

    ui_log "Collecting app configuration (certificates only - never keys)"
    for app in $(apps_installed); do
        mkdir -p "$staging/apps/$app"
        local f
        for f in manifest docker-compose.yml app.spec; do
            [ -f "$SC2_INSTALL_DIR/apps/$app/$f" ] && cp "$SC2_INSTALL_DIR/apps/$app/$f" "$staging/apps/$app/"
        done
        find "$SC2_INSTALL_DIR/apps/$app/certs" -name '*.crt' -exec cp --parents {} "$staging/" \; 2>/dev/null || true
    done

    tar -czf "$out" -C "$staging" .
    rm -rf "$staging"
    chmod 0600 "$out"

    # belt and braces: prove no private keys made it in
    if tar -tzf "$out" | grep -qE '\.key$|tls\.key'; then
        rm -f "$out"
        die "internal error: a key file almost entered the support bundle - aborted"
    fi

    ui_ok "Support bundle created: $out ($(du -h "$out" | cut -f1))"
    ui_log "It contains logs, status and public certificates - NO private keys."
    ui_log "Send this file to your support contact."
}
