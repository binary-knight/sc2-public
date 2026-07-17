# shellcheck shell=bash
# bundle.sh - pre-bundle customization, authored before the bundle ships:
#
#   containers/   every image archive (*.tgz/*.tar) dropped here is
#                 auto-detected and loaded at install time, no manifest needed.
#
#   bundle.conf   declarative install directives, one per line:
#                 copy  <bundle-relative-src> <absolute-dest>
#                 mkdir <absolute-path> [octal-mode]
#                 port  <port/proto>
#                 run   <command...>          (post-install hook, runs as root)
#
# Whitespace-separated fields; paths must not contain spaces. '#' comments and
# blank lines are ignored. Everything applied is recorded in the ledger so
# 'remove' can undo it.

SC2_BUNDLE_CONF="$SC2_ROOT/bundle.conf"

# emit "directive<TAB>rest" for each meaningful line
_bundle_lines() {
    [ -f "$SC2_BUNDLE_CONF" ] || return 0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        # trim
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$line" ] || continue
        printf '%s\n' "$line"
    done < "$SC2_BUNDLE_CONF"
    return 0
}

# validate early (called from preflight) so a bad conf fails before any mutation
bundle_validate() {
    [ -f "$SC2_BUNDLE_CONF" ] || return 0
    local line d a b n=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$(( n + 1 ))
        read -r d a b _ <<< "$line"
        case "$d" in
            copy)
                [ -n "${b:-}" ] || die "bundle.conf: 'copy' needs <src> <dest>: $line"
                [ -e "$SC2_ROOT/$a" ] || die "bundle.conf: copy source missing from bundle: $a"
                case "$b" in /*) : ;; *) die "bundle.conf: copy dest must be absolute: $b" ;; esac
                ;;
            mkdir)
                [ -n "${a:-}" ] || die "bundle.conf: 'mkdir' needs a path: $line"
                case "$a" in /*) : ;; *) die "bundle.conf: mkdir path must be absolute: $a" ;; esac
                case "${b:-0755}" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) : ;; *) die "bundle.conf: bad mkdir mode: $b" ;; esac
                ;;
            port)
                case "${a:-}" in
                    [0-9]*/tcp|[0-9]*/udp) : ;;
                    *) die "bundle.conf: bad port (want NNNN/tcp or NNNN/udp): $line" ;;
                esac
                ;;
            run)
                [ -n "${a:-}" ] || die "bundle.conf: 'run' needs a command: $line"
                ;;
            *)
                die "bundle.conf: unknown directive '$d' (know: copy mkdir port run)"
                ;;
        esac
    done <<< "$(_bundle_lines)"
    [ "$n" -gt 0 ] && ui_ok "bundle.conf valid ($n directive(s))"
    return 0
}

# paths we will never delete on remove, even if a directive put them in the ledger
_bundle_path_safe() {
    case "$1" in
        /usr/local/?*) : ;;  # explicitly allowed
        /|/bin*|/boot*|/dev*|/etc|/home|/lib*|/proc*|/root|/run*|/sbin*|/sys*|/usr*|/var|/var/lib|/var/log|/tmp)
            return 1 ;;
    esac
    # require at least two path components (e.g. /opt/app, not /opt)
    local slashes
    slashes="$(printf '%s' "$1" | tr -cd '/' | wc -c)"
    [ "$slashes" -ge 2 ]
}

_bundle_copy() {  # <bundle-relative-src> <absolute-dest>
    local rel="$1" dst="$2" src="$SC2_ROOT/$1" item
    if [ -d "$src" ]; then
        if [ -d "$dst" ]; then
            # dest already exists: copy contents and record each item, so
            # remove never deletes what we did not create.
            for item in "$src"/* "$src"/.[!.]*; do
                [ -e "$item" ] || continue
                cp -a "$item" "$dst/"
                chown -R root:root "$dst/$(basename "$item")"
                ledger_add file "$dst/$(basename "$item")"
            done
        else
            mkdir -p "$(dirname "$dst")"
            cp -a "$src" "$dst"
            chown -R root:root "$dst"
            ledger_add file "$dst"
        fi
    else
        [ -d "$dst" ] && dst="$dst/$(basename "$src")"
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        chown root:root "$dst"
        ledger_add file "$dst"
    fi
    ui_ok "Copied $rel -> $2"
}

bundle_apply() {
    if [ ! -f "$SC2_BUNDLE_CONF" ]; then
        ui_log "No bundle.conf - skipping directives"
        return 0
    fi
    local line d a b _rest
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read -r d a b _rest <<< "$line"
        case "$d" in
            copy)  _bundle_copy "$a" "$b" ;;
            mkdir)
                if [ ! -d "$a" ]; then
                    run_cmd "mkdir $a" mkdir -p -m "${b:-0755}" "$a"
                    ledger_add mkdir "$a"
                    ui_ok "Created directory $a"
                fi
                ;;
            port)  fw_open "$a" ;;
            run)   : ;;  # hooks run later, after apps are up
        esac
    done <<< "$(_bundle_lines)"
}

bundle_run_hooks() {
    [ -f "$SC2_BUNDLE_CONF" ] || return 0
    local line d rest ran=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        d="${line%%[[:space:]]*}"
        [ "$d" = run ] || continue
        rest="$(printf '%s' "$line" | sed -e 's/^run[[:space:]]*//')"
        ui_log "Hook: $rest"
        run_cmd "post-install hook '$rest'" bash -c "$rest"
        ran=1
    done <<< "$(_bundle_lines)"
    [ "$ran" = 1 ] && ui_ok "Post-install hooks complete"
    return 0
}

bundle_remove() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if _bundle_path_safe "$f"; then
            rm -rf "$f"
            ui_log "Removed $f"
        else
            ui_warn "refusing to delete protected path from ledger: $f"
        fi
    done <<< "$(ledger_get file)"

    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$PURGE_DATA" = 1 ]; then
            _bundle_path_safe "$d" && rm -rf "$d"
        else
            rmdir "$d" 2>/dev/null || ui_log "Keeping non-empty $d (use remove --purge to delete)"
        fi
    done <<< "$(ledger_get mkdir)"
}

bundle_ports() {
    _bundle_lines | awk '$1 == "port" { print $2 }'
    return 0
}

# auto-detect and load every image archive dropped into containers/
images_load_auto() {
    local files=() f i n
    for f in "$SC2_ROOT"/containers/*.tgz "$SC2_ROOT"/containers/*.tar "$SC2_ROOT"/containers/*.tar.gz; do
        [ -f "$f" ] && files+=("$f")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        ui_log "No pre-loaded containers in containers/"
        return 0
    fi
    n="${#files[@]}"; i=0
    for f in "${files[@]}"; do
        i=$(( i + 1 ))
        ui_progress "$(( i - 1 ))" "$n" "Loading $(basename "$f")"
        ctr_load "$f"
        ui_progress "$i" "$n" "Loaded $(basename "$f")"
    done
    ui_ok "Auto-loaded $n container archive(s) from containers/"
}
