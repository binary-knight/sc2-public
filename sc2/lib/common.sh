# shellcheck shell=bash
# common.sh - logging, state ledger, UI plumbing shared by all modules.

SC2_VERSION="$(cat "$SC2_ROOT/VERSION" 2>/dev/null || echo 0.0.0-dev)"
SC2_INSTALL_DIR="/opt/sc2"
SC2_STATE_DIR="/etc/sc2"
SC2_LEDGER="$SC2_STATE_DIR/ledger"
SC2_LOG_DIR="/var/log/sc2"
SC2_LOG_FILE="$SC2_LOG_DIR/sc2.log"

UI_MODE="cli"        # cli | tui
ASSUME_YES=0
PURGE_DATA=0

# --- glyphs: unicode when the locale can render it, ASCII otherwise ---
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*8*) SC2_UTF8=1 ;;
    *)                SC2_UTF8=0 ;;
esac
if [ "$SC2_UTF8" = 1 ]; then
    GL_OK='✓'; GL_BAD='✗'; GL_WARN='!'; GL_FULL='█'; GL_EMPTY='░'
    GL_H='─'; GL_V='│'; GL_TL='┌'; GL_TR='┐'; GL_BL='└'; GL_BR='┘'; GL_LT='├'; GL_RT='┤'
    GL_PTR='▸'; GL_DOT='·'
else
    GL_OK='+'; GL_BAD='x'; GL_WARN='!'; GL_FULL='#'; GL_EMPTY='-'
    GL_H='-'; GL_V='|'; GL_TL='+'; GL_TR='+'; GL_BL='+'; GL_BR='+'; GL_LT='+'; GL_RT='+'
    GL_PTR='>'; GL_DOT='.'
fi

# --- colors (disabled when stdout is not a tty) ---
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_REV=$'\033[7m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_REV=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

_logfile_write() {
    [ -d "$SC2_LOG_DIR" ] || mkdir -p "$SC2_LOG_DIR" 2>/dev/null || return 0
    printf '%s %s\n' "$(_timestamp)" "$*" >> "$SC2_LOG_FILE" 2>/dev/null || true
}

ui_log() {
    _logfile_write "INFO  $*"
    if [ "$UI_MODE" = tui ]; then tui_log "  $*"; else printf '  %s\n' "$*"; fi
}

ui_ok() {
    _logfile_write "OK    $*"
    if [ "$UI_MODE" = tui ]; then tui_log "$GL_OK $*"; else printf '%s %s\n' "${C_GREEN}${GL_OK}${C_RESET}" "$*"; fi
}

ui_warn() {
    _logfile_write "WARN  $*"
    if [ "$UI_MODE" = tui ]; then tui_log "$GL_WARN $*"; else printf '%s %s\n' "${C_YELLOW}${GL_WARN}${C_RESET}" "$*" >&2; fi
}

die() {
    _logfile_write "FATAL $*"
    if [ "$UI_MODE" = tui ]; then
        # Inside the TUI, actions run in a subshell: log the failure and let
        # the parent menu loop survive.
        tui_log "$GL_BAD $*"
        exit 1
    fi
    printf '%s %s\n' "${C_RED}${GL_BAD}${C_RESET}" "$*" >&2
    exit 1
}

# ui_phase <current> <total> <label> - coarse progress across an operation
ui_phase() {
    local cur=$1 tot=$2 label=$3
    _logfile_write "PHASE [$cur/$tot] $label"
    if [ "$UI_MODE" = tui ]; then
        tui_phase "$cur" "$tot" "$label"
    else
        printf '\n%s[%d/%d] %s%s\n' "${C_BOLD}${C_CYAN}" "$cur" "$tot" "$label" "$C_RESET"
    fi
}

# ui_progress <current> <total> <label> - fine progress within a phase
ui_progress() {
    local cur=$1 tot=$2 label=$3 width=30 pct filled bar='' i
    [ "$tot" -gt 0 ] || tot=1
    pct=$(( cur * 100 / tot ))
    if [ "$UI_MODE" = tui ]; then tui_progress "$pct" "$label"; return 0; fi
    if [ ! -t 1 ]; then printf '  %s (%d%%)\n' "$label" "$pct"; return 0; fi
    filled=$(( cur * width / tot ))
    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then bar+="$GL_FULL"; else bar+="$GL_EMPTY"; fi
    done
    printf '\r  %s[%s]%s %3d%%  %s\033[K' "$C_CYAN" "$bar" "$C_RESET" "$pct" "$label"
    [ "$cur" -ge "$tot" ] && printf '\n'
    return 0
}

# run_cmd <description> <cmd> [args...] - run, log output, die on failure
run_cmd() {
    local desc="$1" out rc
    shift
    _logfile_write "RUN   $*"
    out="$("$@" 2>&1)"; rc=$?
    [ -n "$out" ] && _logfile_write "$out"
    if [ "$rc" -ne 0 ]; then
        [ "$UI_MODE" = tui ] || printf '%s\n' "$out" | tail -n 15 >&2
        die "$desc failed (details: $SC2_LOG_FILE)"
    fi
    return 0
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "this operation must run as root (try: sudo $0 ...)"
}

confirm() {
    local prompt="$1" ans
    [ "$ASSUME_YES" = 1 ] && return 0
    if [ "$UI_MODE" = tui ]; then tui_confirm "$prompt"; return $?; fi
    printf '%s [y/N] ' "$prompt"
    read -r ans || return 1
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- state ledger: every mutation SC2 makes is recorded here so that
# --- remove/upgrade replay facts instead of guessing.
ledger_add() {  # <type> <value>
    mkdir -p "$SC2_STATE_DIR"
    grep -qxF "$1|$2" "$SC2_LEDGER" 2>/dev/null || printf '%s|%s\n' "$1" "$2" >> "$SC2_LEDGER"
}

ledger_get() {  # <type> -> values, one per line
    [ -r "$SC2_LEDGER" ] || return 0
    grep "^$1|" "$SC2_LEDGER" 2>/dev/null | cut -d'|' -f2-
    return 0
}

ledger_clear() { rm -f "$SC2_LEDGER"; }
