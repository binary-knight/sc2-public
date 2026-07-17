# shellcheck shell=bash
# rpm.sh - offline package installation from the bundled per-major RPM repo.
#
# Strategy: the bundle carries a createrepo'd directory per RHEL major
# (rpms/el7, rpms/el8, rpms/el9). We drop a temporary file:// repo config and
# let yum resolve ordering/conflicts with every other repo disabled, so no
# network access is ever attempted.

SC2_REPO_ID="sc2-local"
SC2_REPO_FILE="/etc/yum.repos.d/sc2-local.repo"
RPM_REPO_MODE="none"    # none | repo | plain
RPM_REPO_DIR=""

rpm_repo_setup() {
    RPM_REPO_MODE="none"
    RPM_REPO_DIR="$SC2_ROOT/rpms/el${RHEL_MAJOR}"
    ls "$RPM_REPO_DIR"/*.rpm >/dev/null 2>&1 || return 0

    if [ -d "$RPM_REPO_DIR/repodata" ]; then
        # module_hotfixes: RHEL 8 ships podman & friends as a dnf module;
        # without modular metadata (which createrepo_c does not generate)
        # dnf refuses them. This flag makes dnf treat the bundle's packages
        # as plain RPMs. Ignored by el7 yum and harmless on el9.
        cat > "$SC2_REPO_FILE" <<EOF
[$SC2_REPO_ID]
name=SC2 offline bundle (el${RHEL_MAJOR})
baseurl=file://$RPM_REPO_DIR
enabled=0
gpgcheck=0
module_hotfixes=1
EOF
        RPM_REPO_MODE="repo"
    else
        ui_warn "rpms/el${RHEL_MAJOR} has no repodata/ (bundle built without createrepo); using direct install"
        RPM_REPO_MODE="plain"
    fi
}

rpm_repo_teardown() {
    rm -f "$SC2_REPO_FILE"
}

# rpm_install <pkg>... - install any of the named packages that are missing.
rpm_install() {
    local missing=() p
    for p in "$@"; do
        rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        ui_ok "Required packages already installed: $*"
        return 0
    fi

    case "$RPM_REPO_MODE" in
        repo)
            ui_log "Installing from bundle: ${missing[*]}"
            run_cmd "package install" yum -y -q --disablerepo='*' --enablerepo="$SC2_REPO_ID" install "${missing[@]}"
            ;;
        plain)
            ui_log "Installing all bundled RPMs (no repodata): ${missing[*]}"
            run_cmd "package install" yum -y -q --disablerepo='*' localinstall "$RPM_REPO_DIR"/*.rpm
            ;;
        *)
            die "packages required but not installed (${missing[*]}) and no RPM bundle exists at rpms/el${RHEL_MAJOR}/"
            ;;
    esac

    for p in "${missing[@]}"; do
        if rpm -q "$p" >/dev/null 2>&1; then
            ledger_add rpm "$p"
        else
            die "package '$p' still missing after install"
        fi
    done
    ui_ok "Packages installed: ${missing[*]}"
}
