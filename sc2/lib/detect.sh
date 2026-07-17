# shellcheck shell=bash
# detect.sh - discover what we are running on. Sets globals, never mutates.

OS_PRETTY="unknown"
RHEL_MAJOR=""
ARCH=""
SELINUX_MODE="unavailable"
FIPS_MODE="off"
FAPOLICYD="inactive"
FIREWALL="none"
ENGINE=""
ENGINE_PRESENT=0
ENGINE_VERSION=""

detect_system() {
    ARCH="$(uname -m)"

    if [ -r /etc/os-release ]; then
        OS_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
        local vid
        vid="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
        RHEL_MAJOR="${vid%%.*}"
    fi
    if [ -z "$RHEL_MAJOR" ] && [ -r /etc/redhat-release ]; then
        OS_PRETTY="$(cat /etc/redhat-release)"
        RHEL_MAJOR="$(sed -n 's/.*release \([0-9][0-9]*\).*/\1/p' /etc/redhat-release)"
    fi

    SELINUX_MODE="$(getenforce 2>/dev/null || echo unavailable)"

    FIPS_MODE=off
    [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = "1" ] && FIPS_MODE=on

    FAPOLICYD=inactive
    systemctl is-active fapolicyd >/dev/null 2>&1 && FAPOLICYD=active

    detect_firewall
    detect_engine
}

detect_firewall() {
    if systemctl is-active firewalld >/dev/null 2>&1; then
        FIREWALL=firewalld
    elif systemctl is-active iptables >/dev/null 2>&1; then
        FIREWALL=iptables
    elif systemctl is-active nftables >/dev/null 2>&1; then
        FIREWALL=nftables
    else
        FIREWALL=none
    fi
}

# Engine policy: adopt a running docker anywhere; otherwise docker on el7
# (podman there is far too old), podman on el8/el9/el10.
detect_engine() {
    if command -v docker >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
        ENGINE=docker
    elif [ "${RHEL_MAJOR:-0}" = "7" ]; then
        ENGINE=docker
    else
        ENGINE=podman
    fi

    ENGINE_PRESENT=0
    ENGINE_VERSION=""
    if command -v "$ENGINE" >/dev/null 2>&1; then
        ENGINE_PRESENT=1
        ENGINE_VERSION="$("$ENGINE" --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -n1)"
    fi
}

detect_summary() {
    printf '%-18s %s\n' "OS:"        "$OS_PRETTY"
    printf '%-18s %s\n' "Arch:"      "$ARCH"
    printf '%-18s %s' "Runtime:"     "$ENGINE"
    if [ "$ENGINE_PRESENT" = 1 ]; then printf ' %s (installed)\n' "$ENGINE_VERSION"; else printf ' (not installed - will install from bundle)\n'; fi
    printf '%-18s %s\n' "SELinux:"   "$SELINUX_MODE"
    printf '%-18s %s\n' "FIPS mode:" "$FIPS_MODE"
    printf '%-18s %s\n' "fapolicyd:" "$FAPOLICYD"
    printf '%-18s %s\n' "Firewall:"  "$FIREWALL"
}

# One-line variant for the TUI header
detect_statline() {
    local eng="$ENGINE"
    [ -n "$ENGINE_VERSION" ] && eng="$ENGINE $ENGINE_VERSION"
    local os="$OS_PRETTY"
    case "$os" in
        Red\ Hat\ Enterprise\ Linux*) os="RHEL $(sed -n 's/.*Linux[^0-9]*\([0-9.][0-9.]*\).*/\1/p' <<<"$OS_PRETTY")" ;;
    esac
    printf '%s %s %s %s SELinux %s %s FIPS %s %s fw %s' \
        "$os" "$GL_DOT" "$eng" "$GL_DOT" "$SELINUX_MODE" "$GL_DOT" "$FIPS_MODE" "$GL_DOT" "$FIREWALL"
}
