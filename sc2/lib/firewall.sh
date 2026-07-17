# shellcheck shell=bash
# firewall.sh - open/close app ports on whichever firewall is actually running.
# Backend was detected in detect_firewall(): firewalld | iptables | nftables | none

fw_open() {  # <port/proto> e.g. "8080/tcp"
    local port="$1" p proto
    p="${port%%/*}"; proto="${port##*/}"

    case "$FIREWALL" in
        firewalld)
            run_cmd "open port $port (firewalld)" firewall-cmd -q --permanent --add-port="$port"
            run_cmd "reload firewalld" firewall-cmd -q --reload
            ;;
        iptables)
            if ! iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1; then
                run_cmd "open port $port (iptables)" iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT
            fi
            service iptables save >/dev/null 2>&1 || ui_warn "could not persist iptables rules (service iptables save failed)"
            ;;
        nftables)
            if ! nft list table inet sc2 >/dev/null 2>&1; then
                run_cmd "create nft table" nft add table inet sc2
                run_cmd "create nft chain" nft add chain inet sc2 input '{ type filter hook input priority -10 ; policy accept ; }'
            fi
            if ! nft list chain inet sc2 input 2>/dev/null | grep -qw "dport $p"; then
                run_cmd "open port $port (nftables)" nft add rule inet sc2 input "$proto" dport "$p" accept
            fi
            ;;
        none)
            ui_warn "no active firewall - skipping rule for $port"
            return 0
            ;;
    esac
    ledger_add port "$port"
    ui_ok "Firewall: $port open ($FIREWALL)"
}

fw_close() {  # <port/proto>
    local port="$1" p proto
    p="${port%%/*}"; proto="${port##*/}"

    case "$FIREWALL" in
        firewalld)
            firewall-cmd -q --permanent --remove-port="$port" 2>/dev/null || true
            firewall-cmd -q --reload 2>/dev/null || true
            ;;
        iptables)
            iptables -D INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
            service iptables save >/dev/null 2>&1 || true
            ;;
        nftables)
            local handle
            handle="$(nft -a list chain inet sc2 input 2>/dev/null | awk -v p="$p" '$0 ~ "dport "p" " || $0 ~ "dport "p"$" { for (i=1;i<=NF;i++) if ($i=="handle") print $(i+1) }' | head -n1)"
            [ -n "$handle" ] && nft delete rule inet sc2 input handle "$handle" >/dev/null 2>&1 || true
            ;;
        none) : ;;
    esac
    ui_log "Firewall: $port closed"
}

fw_close_all() {
    local port
    while IFS= read -r port; do
        [ -n "$port" ] && fw_close "$port"
    done <<< "$(ledger_get port)"
}
