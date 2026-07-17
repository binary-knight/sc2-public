# shellcheck shell=bash
# tui.sh - full-screen guided installer UI. Pure ANSI escapes + tput, no
# dialog/ncurses dependency, works on bash 4.2 / RHEL 7 consoles (with ASCII
# fallback when the locale is not UTF-8).
#
# The menu is built from what is actually in the bundle and on the system:
# each app gets Install / Upgrade / Uninstall entries as appropriate, every
# entry has a plain-language hint, and installs finish with a "next steps"
# page for anything SC2 could not do automatically (external PKI certs).

TUI_W=76
TUI_IW=72          # inner text width
TUI_LOG_N=9        # log pane height
TUI_HR=""          # cached horizontal rule
TUI_LOG_BUF=()
TUI_ITEMS=()       # menu labels
TUI_ACTIONS=()     # parallel action tokens, e.g. install:example
TUI_HINTS=()       # parallel plain-language hints

# row positions, computed in tui_layout
R_TITLE=2; R_STAT=3; R_MENU=5; R_PHASE=0; R_PROG=0; R_LOG=0; R_BOT=0; R_FOOT=0

_t_goto() { printf '\033[%d;%dH' "$1" "$2"; }

# pad/truncate to N characters (bash ${#s} counts characters, not bytes)
_t_fit() {
    local s="$1" w="$2"
    [ "${#s}" -gt "$w" ] && s="${s:0:$w}"
    printf '%s%*s' "$s" $(( w - ${#s} )) ''
}

_t_row() {  # <row> <text> [sgr] - draw one bordered content row
    local row="$1" text="$2" sgr="${3:-}"
    _t_goto "$row" 1
    printf '%s %s%s%s %s' "$GL_V" "$sgr" "$(_t_fit "$text" "$TUI_IW")" "$C_RESET" "$GL_V"
}

_t_hline() {  # <row> <left-glyph> <right-glyph>
    _t_goto "$1" 1
    printf '%s%s%s' "$2" "$TUI_HR" "$3"
}

# build menu entries from bundle contents + installed state
tui_build_menu() {
    TUI_ITEMS=() TUI_ACTIONS=() TUI_HINTS=()
    local app cur
    for app in $(apps_available); do
        app_load_manifest "$SC2_ROOT/apps/$app"
        cur="$(app_installed_version "$APP_NAME")"
        if [ -z "$cur" ]; then
            TUI_ITEMS+=("Install ${APP_NAME}")
            TUI_ACTIONS+=("install:$app")
            TUI_HINTS+=("${APP_DESC:-Installs and starts ${APP_NAME}: containers, firewall and TLS are automatic}")
        else
            if [ "$cur" != "$APP_VERSION" ]; then
                TUI_ITEMS+=("Upgrade ${APP_NAME}  ($cur -> $APP_VERSION)")
                TUI_ACTIONS+=("upgrade:$app")
                TUI_HINTS+=("Updates ${APP_NAME} to $APP_VERSION; saved data is kept")
            fi
            TUI_ITEMS+=("Uninstall ${APP_NAME}")
            TUI_ACTIONS+=("uninstall:$app")
            TUI_HINTS+=("Stops and removes ${APP_NAME}; saved data is kept")
        fi
    done
    TUI_ITEMS+=("Certificate setup guide")
    TUI_ACTIONS+=("guide")
    TUI_HINTS+=("Shows what is automatic and the exact steps for official certificates")
    TUI_ITEMS+=("Run diagnostics")
    TUI_ACTIONS+=("doctor")
    TUI_HINTS+=("Checks certificates and running apps, explains any problem it finds")
    TUI_ITEMS+=("Create support file")
    TUI_ACTIONS+=("support")
    TUI_HINTS+=("Packs logs and status into one file to send to your support contact")
    TUI_ITEMS+=("System status")
    TUI_ACTIONS+=("status")
    TUI_HINTS+=("Shows what SC2 found on this system and what is running")
    TUI_ITEMS+=("Remove everything")
    TUI_ACTIONS+=("removeall")
    TUI_HINTS+=("Removes ALL apps, containers, firewall rules and SC2 itself")
    TUI_ITEMS+=("Quit")
    TUI_ACTIONS+=("quit")
    TUI_HINTS+=("Leave this menu (running apps keep running)")
}

tui_layout() {
    local cols rows
    cols="$(tput cols 2>/dev/null || echo 80)"
    rows="$(tput lines 2>/dev/null || echo 24)"
    TUI_W=$(( cols - 2 )); [ "$TUI_W" -gt 76 ] && TUI_W=76
    TUI_IW=$(( TUI_W - 4 ))
    TUI_LOG_N=$(( rows - 12 - ${#TUI_ITEMS[@]} ))
    [ "$TUI_LOG_N" -gt 9 ] && TUI_LOG_N=9
    [ "$TUI_LOG_N" -lt 3 ] && TUI_LOG_N=3

    TUI_HR=""
    local i
    for (( i = 0; i < TUI_W - 2; i++ )); do TUI_HR+="$GL_H"; done

    local n=${#TUI_ITEMS[@]}
    R_TITLE=2; R_STAT=3; R_MENU=5
    R_PHASE=$(( R_MENU + n + 1 ))
    R_PROG=$(( R_PHASE + 1 ))
    R_LOG=$(( R_PROG + 2 ))
    R_BOT=$(( R_LOG + TUI_LOG_N ))
    R_FOOT=$(( R_BOT + 1 ))
}

tui_setup() {
    [ -t 0 ] && [ -t 1 ] || die "the menu needs an interactive terminal (see: $0 help)"
    local cols; cols="$(tput cols 2>/dev/null || echo 80)"
    [ "$cols" -ge 60 ] || die "terminal too narrow for the menu (need >= 60 columns); see: $0 help"
    UI_MODE=tui
    printf '\033[?1049h\033[?25l'    # alternate screen, hide cursor
    stty -echo 2>/dev/null || true
    trap 'tui_teardown' EXIT
    trap 'tui_teardown; exit 130' INT TERM
}

tui_teardown() {
    [ "$UI_MODE" = tui ] || return 0
    UI_MODE=cli
    printf '\033[?25h\033[?1049l'
    stty echo 2>/dev/null || true
}

tui_draw_frame() {
    printf '\033[2J'
    _t_hline 1 "$GL_TL" "$GL_TR"
    local title="SC2 $GL_DOT Simple Container Carrier"
    local ver="v$SC2_VERSION"
    _t_row "$R_TITLE" "$title$(printf '%*s' $(( TUI_IW - ${#title} - ${#ver} )) '')$ver" "$C_BOLD"
    _t_row "$R_STAT" "$(detect_statline)" "$C_DIM"
    _t_hline 4 "$GL_LT" "$GL_RT"
    local i
    for (( i = 0; i < ${#TUI_ITEMS[@]}; i++ )); do
        _t_row $(( R_MENU + i )) ""
    done
    _t_hline $(( R_PHASE - 1 )) "$GL_LT" "$GL_RT"
    _t_row "$R_PHASE" ""
    _t_row "$R_PROG" ""
    _t_hline $(( R_LOG - 1 )) "$GL_LT" "$GL_RT"
    for (( i = 0; i < TUI_LOG_N; i++ )); do
        _t_row $(( R_LOG + i )) ""
    done
    _t_hline "$R_BOT" "$GL_BL" "$GL_BR"
}

tui_footer() {  # <text> - word-wraps across the two lines below the box
    local text="$1" line1="" line2="" w word
    w=$(( TUI_W - 2 ))
    for word in $text; do
        if [ -z "$line1" ]; then
            line1="$word"
        elif [ $(( ${#line1} + 1 + ${#word} )) -le "$w" ]; then
            line1="$line1 $word"
        elif [ -z "$line2" ]; then
            line2="$word"
        elif [ $(( ${#line2} + 1 + ${#word} )) -le "$w" ]; then
            line2="$line2 $word"
        else
            line2="${line2}..."
            break
        fi
    done
    _t_goto "$R_FOOT" 1
    printf ' %s%s%s\033[K' "$C_DIM" "$(_t_fit "$line1" "$w")" "$C_RESET"
    _t_goto $(( R_FOOT + 1 )) 1
    printf ' %s%s%s\033[K' "$C_DIM" "$(_t_fit "$line2" "$w")" "$C_RESET"
}

tui_menu_draw() {  # <selected-index>
    local sel="$1" i label
    for (( i = 0; i < ${#TUI_ITEMS[@]}; i++ )); do
        if [ "$i" -eq "$sel" ]; then
            label=" $GL_PTR ${TUI_ITEMS[$i]}"
            _t_row $(( R_MENU + i )) "$label" "$C_REV$C_BOLD"
        else
            label="   ${TUI_ITEMS[$i]}"
            _t_row $(( R_MENU + i )) "$label"
        fi
    done
    tui_footer "Keys: up/down, Enter, q $GL_DOT ${TUI_HINTS[$sel]:-}"
}

tui_read_key() {
    local k rest=''
    IFS= read -rsn1 k || { echo quit; return; }
    if [ "$k" = $'\x1b' ]; then
        IFS= read -rsn2 -t 0.05 rest || rest=''
        case "$rest" in
            '[A') echo up ;;
            '[B') echo down ;;
            *)    echo esc ;;
        esac
    elif [ -z "$k" ]; then
        echo enter
    else
        case "$k" in
            q|Q) echo quit ;;
            k)   echo up ;;
            j)   echo down ;;
            y|Y) echo yes ;;
            n|N) echo no ;;
            *)   echo other ;;
        esac
    fi
}

tui_log() {
    TUI_LOG_BUF+=("$1")
    local overflow=$(( ${#TUI_LOG_BUF[@]} - TUI_LOG_N ))
    [ "$overflow" -gt 0 ] && TUI_LOG_BUF=("${TUI_LOG_BUF[@]:$overflow}")
    local i
    for (( i = 0; i < TUI_LOG_N; i++ )); do
        if [ "$i" -lt "${#TUI_LOG_BUF[@]}" ]; then
            _t_row $(( R_LOG + i )) "${TUI_LOG_BUF[$i]}"
        else
            _t_row $(( R_LOG + i )) ""
        fi
    done
}

tui_log_clear() {
    TUI_LOG_BUF=()
    local i
    for (( i = 0; i < TUI_LOG_N; i++ )); do
        _t_row $(( R_LOG + i )) ""
    done
}

tui_phase() {  # <cur> <tot> <label>
    _t_row "$R_PHASE" "[$1/$2] $3" "$C_BOLD$C_CYAN"
    tui_progress $(( ($1 - 1) * 100 / $2 )) "$3"
}

tui_progress() {  # <pct> <label>
    local pct="$1" label="$2"
    local bw=$(( TUI_IW - 26 )) filled bar='' i
    [ "$bw" -lt 10 ] && bw=10
    filled=$(( pct * bw / 100 ))
    for (( i = 0; i < bw; i++ )); do
        if (( i < filled )); then bar+="$GL_FULL"; else bar+="$GL_EMPTY"; fi
    done
    _t_row "$R_PROG" "[$bar] $(printf '%3d' "$pct")%  $(_t_fit "$label" 16)" "$C_CYAN"
}

tui_confirm() {  # <prompt>
    tui_footer "$1  [y = yes / n = no]"
    local k
    while :; do
        k="$(tui_read_key)"
        case "$k" in
            yes) tui_footer ""; return 0 ;;
            no|quit|esc|enter) tui_footer ""; return 1 ;;
        esac
    done
}

tui_pause() {
    tui_footer "${1:-Press any key to return to the menu}"
    IFS= read -rsn1 || true
}

# full-screen text page (guide, status); content lines on stdin, paginated
tui_page() {  # <title>
    local title="$1" lines=() line rows avail start i row
    while IFS= read -r line; do lines+=("$line"); done
    rows="$(tput lines 2>/dev/null || echo 24)"
    avail=$(( rows - 6 ))
    [ "$avail" -lt 5 ] && avail=5
    start=0
    while :; do
        printf '\033[2J'
        _t_hline 1 "$GL_TL" "$GL_TR"
        _t_row 2 "$title" "$C_BOLD"
        _t_hline 3 "$GL_LT" "$GL_RT"
        for (( i = 0; i < avail; i++ )); do
            row=$(( 4 + i ))
            if [ $(( start + i )) -lt "${#lines[@]}" ]; then
                _t_row "$row" "${lines[$(( start + i ))]}"
            else
                _t_row "$row" ""
            fi
        done
        _t_hline $(( 4 + avail )) "$GL_BL" "$GL_BR"
        _t_goto $(( 5 + avail )) 1
        if [ $(( start + avail )) -lt "${#lines[@]}" ]; then
            printf ' %sMore below - press any key for the next page (q to close)%s\033[K' "$C_DIM" "$C_RESET"
            IFS= read -rsn1 line < /dev/tty || line=q
            case "$line" in q|Q) break ;; esac
            start=$(( start + avail ))
        else
            printf ' %sPress any key to return to the menu%s\033[K' "$C_DIM" "$C_RESET"
            IFS= read -rsn1 < /dev/tty || true
            break
        fi
    done
}

tui_run_action() {  # <busy-label> <command> [args...]
    local label="$1" rc
    shift
    tui_log_clear
    _t_row "$R_PHASE" "$label" "$C_BOLD$C_CYAN"
    _t_row "$R_PROG" ""
    tui_footer "Working - please wait..."
    # Subshell so die() aborts the action, not the menu.
    ( "$@" ); rc=$?
    if [ "$rc" -eq 0 ]; then
        tui_progress 100 "done"
        tui_pause "Done - press any key to continue"
    else
        _t_row "$R_PROG" "Something went wrong - details: $SC2_LOG_FILE" "$C_RED"
        tui_pause "Press any key to return to the menu"
    fi
    return "$rc"
}

tui_action_status() {
    detect_summary
    apps_status
    printf '\n'
    certs_status
}

tui_main() {
    need_root
    detect_system
    tui_build_menu
    tui_setup
    tui_layout
    tui_draw_frame
    local sel=0 n key act app
    n=${#TUI_ITEMS[@]}
    while :; do
        [ "$sel" -ge "$n" ] && sel=$(( n - 1 ))
        tui_menu_draw "$sel"
        key="$(tui_read_key)"
        case "$key" in
            up)   sel=$(( (sel + n - 1) % n )) ;;
            down) sel=$(( (sel + 1) % n )) ;;
            quit) break ;;
            enter)
                act="${TUI_ACTIONS[$sel]}"
                app="${act#*:}"
                case "$act" in
                    install:*)
                        if tui_run_action "Installing $app" sc2_install_app "$app"; then
                            app_load_manifest "$SC2_ROOT/apps/$app"
                            if [ -n "${APP_PKI:-}" ]; then
                                certs_guide | tui_page "Next steps for $APP_NAME - certificates"
                            fi
                        fi
                        ;;
                    upgrade:*)   tui_run_action "Upgrading $app" sc2_upgrade ;;
                    uninstall:*) tui_run_action "Uninstalling $app" app_uninstall "$app" ;;
                    guide)       certs_guide 2>/dev/null | tui_page "Certificate setup guide" ;;
                    doctor)      certs_doctor 2>/dev/null | tui_page "Diagnostics" ;;
                    support)     tui_run_action "Creating support file" support_bundle ;;
                    status)      tui_action_status 2>/dev/null | tui_page "System status" ;;
                    removeall)   tui_run_action "Removing everything" sc2_remove_all ;;
                    quit)        break ;;
                esac
                # state changed: engine may be installed, apps added/removed
                detect_system
                tui_build_menu
                n=${#TUI_ITEMS[@]}
                tui_layout
                tui_draw_frame
                ;;
        esac
    done
    tui_teardown
}
