# shellcheck shell=bash
# cli.sh - argument parsing and the top-level operations. The TUI calls the
# same sc2_* functions, so CLI and GUI behavior never drift apart.

cli_usage() {
    cat <<EOF
SC2 - Simple Container Carrier v$SC2_VERSION
Offline container deployment for RHEL 7 / 8 / 9 / 10 (x86_64).

Usage: sc2 [verb] [options]

Verbs:
  (none)      launch the interactive TUI (default on a terminal)
  install     configure host, install runtime, load images, deploy apps
  upgrade     load newer images from this bundle and upgrade deployed apps
  status      show system detection and application status
  uninstall <app>   stop and remove one application (data kept unless --purge)
  firewall    (re-)apply firewall rules for all bundled applications
  certs       TLS: status | rotate | guide | doctor | import <app> <svc> <file>
  support-bundle   collect logs/status into one file to send to support
  remove      stop and remove everything SC2 installed
  version     print version
  help        this text

Internal verbs (used by the generated systemd units):
  app-start <name> / app-stop <name>   orchestrate one application stack

Options:
  -y, --yes     assume yes on confirmations (non-interactive)
      --cli     force CLI mode even on a terminal
      --purge   with 'remove': also delete application data volumes

Logs: $SC2_LOG_FILE
Docs: $SC2_ROOT/docs/ (INSTALL.md, OPERATIONS.md, BUNDLING.md)
EOF
}

sc2_install() {
    local P=0 T=9
    ui_phase $(( ++P )) $T "Preflight checks";            preflight_run
    ui_phase $(( ++P )) $T "Installing packages";         runtime_install
    ui_phase $(( ++P )) $T "Starting container runtime";  runtime_enable
    ui_phase $(( ++P )) $T "Installing SC2 payload";      payload_install; trust_binaries
    ui_phase $(( ++P )) $T "Applying bundle directives";  bundle_apply
    ui_phase $(( ++P )) $T "Loading container images";    images_load_all; images_load_auto
    ui_phase $(( ++P )) $T "Deploying applications";      apps_deploy_all
    ui_phase $(( ++P )) $T "Running post-install hooks";  bundle_run_hooks
    ui_phase $(( ++P )) $T "Verifying";                   apps_verify_all
    certs_write_next_steps
    ui_ok "SC2 install complete"
    if [ "$UI_MODE" = cli ] && certs_has_pki; then
        printf '\n'
        certs_guide
    fi
}

# guided per-app install (the TUI's Install <app> action): shared host setup
# runs idempotently, then only the chosen app is deployed
sc2_install_app() {
    local target="$1" P=0 T=8
    ui_phase $(( ++P )) $T "Checking this system";        preflight_run
    ui_phase $(( ++P )) $T "Installing packages";         runtime_install
    ui_phase $(( ++P )) $T "Starting container runtime";  runtime_enable
    ui_phase $(( ++P )) $T "Installing SC2 payload";      payload_install; trust_binaries
    ui_phase $(( ++P )) $T "Applying bundle directives";  bundle_apply; images_load_auto
    ui_phase $(( ++P )) $T "Loading container images";    app_load_images "$target"
    ui_phase $(( ++P )) $T "Starting the application";    app_deploy "$target"; bundle_run_hooks
    ui_phase $(( ++P )) $T "Verifying";                   app_verify "$APP_NAME"
    certs_write_next_steps
    ui_ok "$APP_NAME is installed and running"
}

sc2_upgrade() {
    local P=0 T=6
    ui_phase $(( ++P )) $T "Preflight checks";            preflight_run
    ui_phase $(( ++P )) $T "Checking container runtime";  runtime_enable
    ui_phase $(( ++P )) $T "Refreshing SC2 payload";      payload_install; trust_binaries
    ui_phase $(( ++P )) $T "Applying bundle directives";  bundle_apply; images_load_auto
    ui_phase $(( ++P )) $T "Upgrading applications";      apps_upgrade
    ui_phase $(( ++P )) $T "Verifying";                   apps_verify_all
    ui_ok "Upgrade complete"
}

sc2_firewall() {
    need_root
    detect_firewall
    if [ "$FIREWALL" = none ]; then
        ui_warn "No active firewall (firewalld/iptables/nftables) detected - nothing to configure"
        return 0
    fi
    ui_log "Active firewall backend: $FIREWALL"
    local app port
    for app in $(apps_available); do
        app_load_manifest "$SC2_ROOT/apps/$app"
        for port in $APP_PORTS; do
            fw_open "$port"
        done
    done
    for port in $(bundle_ports); do
        fw_open "$port"
    done
    ui_ok "Firewall rules applied"
}

sc2_remove() {
    need_root
    sc2_remove_all
}

sc2_status() {
    detect_summary
    if [ "$(id -u)" -eq 0 ]; then
        apps_status
    else
        printf '\n(run as root for application/container status)\n'
    fi
}

cli_main() {
    local verb="" force_cli=0 app_arg="" certs_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)   ASSUME_YES=1 ;;
            --cli)      force_cli=1 ;;
            --purge)    PURGE_DATA=1 ;;
            -h|--help|help)     verb=help ;;
            -V|--version|version) verb=version ;;
            app-start|app-stop|uninstall)
                verb="$1"
                app_arg="${2:-}"
                [ -n "$app_arg" ] && shift
                ;;
            certs)
                verb=certs
                shift
                certs_args=(${@+"$@"})
                set --
                continue
                ;;
            install|upgrade|status|firewall|remove|tui|support-bundle) verb="$1" ;;
            *) printf 'unknown argument: %s\n\n' "$1" >&2; cli_usage; exit 2 ;;
        esac
        shift
    done

    case "$verb" in
        help)    cli_usage; exit 0 ;;
        version) printf 'SC2 v%s\n' "$SC2_VERSION"; exit 0 ;;
    esac

    detect_system

    if [ -z "$verb" ] || [ "$verb" = tui ]; then
        if [ "$force_cli" = 1 ]; then
            cli_usage
            exit 0
        fi
        tui_main
        exit 0
    fi

    case "$verb" in
        install)   need_root; sc2_install ;;
        upgrade)   need_root; sc2_upgrade ;;
        status)    sc2_status ;;
        firewall)  sc2_firewall ;;
        remove)    sc2_remove ;;
        app-start) need_root; orch_app_start "$app_arg" ;;
        app-stop)  need_root; orch_app_stop "$app_arg" ;;
        uninstall)
            need_root
            [ -n "$app_arg" ] || die "usage: sc2 uninstall <app>"
            detect_engine
            app_uninstall "$app_arg"
            ;;
        certs)     need_root; certs_cli ${certs_args[@]+"${certs_args[@]}"} ;;
        support-bundle) support_bundle ;;
    esac
}
