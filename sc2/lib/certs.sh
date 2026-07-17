# shellcheck shell=bash
# certs.sh - deterministic TLS for SC2 applications.
#
# Two tiers:
#   1. Internal (automatic): SC2 maintains a local CA (/etc/sc2/pki) and
#      issues per-service certificates whose SANs are derived from the
#      orchestrator's own naming - service name, container name, localhost,
#      host names. Declared in the app manifest:
#          APP_TLS="web proxy"                  services that get certs
#          APP_TLS_SANS_web="app.navy.mil 10.1.2.3"   optional extra SANs
#      Certs land in <appdir>/certs/<svc>/ and the orchestrator mounts them
#      read-only at /run/sc2/tls inside the container:
#          tls.key  tls.crt  fullchain.crt  ca.crt
#      Point Apache/nginx/app config at those fixed paths once; every
#      install on every host is then identical.
#
#   2. External (one command after issuance): 'sc2 certs import' ingests a
#      CA-issued certificate (PKCS#12 or PEM, auto-detected), validates that
#      key and cert actually match, and installs it for one service. Imported
#      certs are marked and never touched by rotation.
#
# The CA survives 'remove' (so reinstalls keep a stable trust anchor) and is
# deleted by 'remove --purge'. Pure openssl; works on el7's 1.0.2 through
# el10's 3.x (SANs via -extfile, no -addext).

CERTS_PKI_DIR="$SC2_STATE_DIR/pki"
CERTS_MOUNT="/run/sc2/tls"
CERTS_CA_DAYS=3650
CERTS_LEAF_DAYS=825

certs_ca_ensure() {
    if [ -s "$CERTS_PKI_DIR/ca.crt" ] && [ -s "$CERTS_PKI_DIR/ca.key" ]; then
        if openssl x509 -checkend 2592000 -noout -in "$CERTS_PKI_DIR/ca.crt" >/dev/null 2>&1; then
            return 0
        fi
        ui_warn "SC2 CA expires within 30 days - reissuing CA (rotate certs afterwards)"
    fi
    # dir and ca.crt stay world-readable (public trust anchor for operators
    # and host tools); only ca.key is secret
    mkdir -p "$CERTS_PKI_DIR"
    chmod 0755 "$CERTS_PKI_DIR"
    run_cmd "generate SC2 local CA" openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
        -days "$CERTS_CA_DAYS" \
        -keyout "$CERTS_PKI_DIR/ca.key" -out "$CERTS_PKI_DIR/ca.crt" \
        -subj "/O=SC2/CN=SC2 Local CA $(hostname -s 2>/dev/null || echo host)"
    chmod 0600 "$CERTS_PKI_DIR/ca.key"
    chmod 0644 "$CERTS_PKI_DIR/ca.crt"
    ui_ok "SC2 local CA ready ($CERTS_PKI_DIR/ca.crt)"
}

# build a deduplicated subjectAltName value; bare IPs become IP: entries
_certs_san() {
    local out="" seen=" " e
    for e in "$@"; do
        [ -n "$e" ] || continue
        case "$seen" in *" $e "*) continue ;; esac
        seen="$seen$e "
        case "$e" in
            *[!0-9.]*) out="$out${out:+,}DNS:$e" ;;
            *)         out="$out${out:+,}IP:$e" ;;
        esac
    done
    printf '%s' "$out"
}

# certs_issue <outdir> <cn> <san>... - key + CA-signed cert + fullchain
certs_issue() {
    local dir="$1" cn="$2" tmp
    shift 2
    mkdir -p "$dir"
    tmp="$(mktemp -d)" || die "mktemp failed"
    run_cmd "generate key/CSR for $cn" openssl req -new -newkey rsa:2048 -sha256 -nodes \
        -keyout "$tmp/key" -out "$tmp/csr" -subj "/O=SC2/CN=$cn"
    cat > "$tmp/ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=$(_certs_san "$@")
EOF
    run_cmd "sign certificate for $cn" openssl x509 -req -in "$tmp/csr" \
        -CA "$CERTS_PKI_DIR/ca.crt" -CAkey "$CERTS_PKI_DIR/ca.key" -CAcreateserial \
        -days "$CERTS_LEAF_DAYS" -sha256 -extfile "$tmp/ext" -out "$tmp/crt"
    install -m 0600 "$tmp/key" "$dir/tls.key"
    install -m 0644 "$tmp/crt" "$dir/tls.crt"
    cat "$tmp/crt" "$CERTS_PKI_DIR/ca.crt" > "$dir/fullchain.crt"
    chmod 0644 "$dir/fullchain.crt"
    install -m 0644 "$CERTS_PKI_DIR/ca.crt" "$dir/ca.crt"
    rm -rf "$tmp"
}

# certs_ensure_app <deployed-appdir> - manifest must already be loaded.
# Issues/refreshes certs for every APP_TLS service; never touches imports.
certs_ensure_app() {
    local appdir="$1"
    # APP_PKI services get an SC2 bootstrap cert too, so the app starts and
    # serves TLS immediately; 'certs import' replaces it with the real one.
    local tls_list="${APP_TLS:-}" s
    for s in ${APP_PKI:-}; do
        case " $tls_list " in *" $s "*) : ;; *) tls_list="$tls_list $s" ;; esac
    done
    [ -n "${tls_list// /}" ] || return 0
    certs_ca_ensure
    local svc dir extra hn fqdn
    hn="$(hostname -s 2>/dev/null || true)"
    fqdn="$(hostname -f 2>/dev/null || true)"
    for svc in $tls_list; do
        dir="$appdir/certs/$svc"
        if [ -f "$dir/.imported" ]; then
            ui_log "certs: $APP_NAME/$svc has an imported certificate - leaving it alone"
            continue
        fi
        if [ -s "$dir/tls.crt" ] \
            && openssl x509 -checkend 2592000 -noout -in "$dir/tls.crt" >/dev/null 2>&1 \
            && openssl verify -CAfile "$CERTS_PKI_DIR/ca.crt" "$dir/tls.crt" >/dev/null 2>&1; then
            continue
        fi
        eval "extra=\"\${APP_TLS_SANS_${svc//[!a-zA-Z0-9_]/_}:-}\""
        # shellcheck disable=SC2086
        certs_issue "$dir" "$svc" \
            "$svc" "sc2-${APP_NAME}-${svc}-1" localhost "$hn" "$fqdn" 127.0.0.1 $extra
        ui_ok "certs: issued TLS certificate for $APP_NAME/$svc"
    done
}

certs_status() {
    if [ ! -s "$CERTS_PKI_DIR/ca.crt" ]; then
        printf 'No SC2 PKI initialized (no app declares APP_TLS, or SC2 is not installed)\n'
        return 0
    fi
    printf 'SC2 CA:  %s\n' "$(openssl x509 -noout -enddate -in "$CERTS_PKI_DIR/ca.crt" | cut -d= -f2)"
    printf '\n%-12s %-10s %-10s %s\n' "APP" "SERVICE" "SOURCE" "EXPIRES"
    local app dir svc src end
    for app in $(apps_installed); do
        for dir in "$SC2_INSTALL_DIR/apps/$app/certs"/*/; do
            [ -f "${dir}tls.crt" ] || continue
            svc="$(basename "$dir")"
            src="sc2-ca"
            [ -f "${dir}.imported" ] && src="imported"
            end="$(openssl x509 -noout -enddate -in "${dir}tls.crt" | cut -d= -f2)"
            if ! openssl x509 -checkend $(( 30 * 86400 )) -noout -in "${dir}tls.crt" >/dev/null 2>&1; then
                end="$end  ${GL_WARN} <30 days"
            fi
            printf '%-12s %-10s %-10s %s\n' "$app" "$svc" "$src" "$end"
        done
    done
    return 0
}

certs_rotate() {
    local app dst svc rotated=0
    for app in $(apps_installed); do
        dst="$SC2_INSTALL_DIR/apps/$app"
        [ -f "$dst/manifest" ] || continue
        app_load_manifest "$dst"
        [ -n "${APP_TLS:-}" ] || continue
        for svc in $APP_TLS; do
            [ -f "$dst/certs/$svc/.imported" ] && continue
            rm -f "$dst/certs/$svc/tls.crt"
        done
        certs_ensure_app "$dst"
        # cert content feeds the container config hash, so this recreates
        # exactly the services whose certs changed
        orch_up "$app" "$dst"
        rotated=1
    done
    if [ "$rotated" = 1 ]; then
        ui_ok "Certificate rotation complete"
    else
        ui_log "No apps with APP_TLS certificates installed"
    fi
}

# --- import: bring a CA-issued (e.g. DoD PKI) cert in for one service ------

_certs_pkcs12_extract() {  # <file> <password> <tmpdir> -> key.pem certs.pem
    local f="$1" pw="$2" tmp="$3" legacy=""
    for legacy in "" "-legacy"; do
        # shellcheck disable=SC2086
        if openssl pkcs12 -in "$f" -passin "pass:$pw" -nocerts -nodes $legacy \
                -out "$tmp/key.pem" >/dev/null 2>&1 \
           && openssl pkcs12 -in "$f" -passin "pass:$pw" -nokeys $legacy \
                -out "$tmp/certs.pem" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

certs_import() {
    local app="" svc="" file="" pass="" certf="" keyf="" chainf="" arg
    while [ $# -gt 0 ]; do
        case "$1" in
            --password) pass="${2:-}"; shift ;;
            --cert)     certf="${2:-}"; shift ;;
            --key)      keyf="${2:-}"; shift ;;
            --chain)    chainf="${2:-}"; shift ;;
            -*) die "certs import: unknown option $1" ;;
            *)
                if [ -z "$app" ]; then app="$1"
                elif [ -z "$svc" ]; then svc="$1"
                elif [ -z "$file" ]; then file="$1"
                else die "certs import: unexpected argument $1"; fi
                ;;
        esac
        shift
    done
    [ -n "$app" ] && [ -n "$svc" ] || die "usage: sc2 certs import <app> <service> <file.p12|file.pem> [--password X] | --cert C --key K [--chain CH]"

    local appdir="$SC2_INSTALL_DIR/apps/$app"
    [ -d "$appdir" ] || die "app '$app' is not installed"

    local tmp
    tmp="$(mktemp -d)" || die "mktemp failed"
    chmod 0700 "$tmp"

    if [ -n "$file" ]; then
        [ -r "$file" ] || die "cannot read $file"
        if grep -q -- "-----BEGIN" "$file" 2>/dev/null; then
            # PEM: may contain key + one or more certs in one file
            openssl pkey -in "$file" -out "$tmp/key.pem" >/dev/null 2>&1 \
                || die "no private key found in $file (pass --key separately?)"
            cp "$file" "$tmp/certs.pem"
        else
            _certs_pkcs12_extract "$file" "$pass" "$tmp" \
                || die "could not unpack PKCS#12 $file (wrong password?)"
        fi
    else
        [ -n "$certf" ] && [ -n "$keyf" ] || die "need either a file argument or --cert and --key"
        openssl pkey -in "$keyf" -out "$tmp/key.pem" >/dev/null 2>&1 || die "cannot parse key $keyf"
        cat "$certf" ${chainf:+"$chainf"} > "$tmp/certs.pem"
    fi

    # split the cert blob and find the leaf: the cert whose public key
    # matches the private key ("part" prefix so the glob can never match
    # certs.pem/key.pem/chain files)
    awk -v dir="$tmp" '/-----BEGIN CERTIFICATE-----/{n++; f=dir"/part"n".pem"} f{print > f} /-----END CERTIFICATE-----/{f=""}' "$tmp/certs.pem"
    local keypub leaf="" c
    keypub="$(openssl pkey -in "$tmp/key.pem" -pubout 2>/dev/null | sha256sum | cut -d" " -f1)"
    [ -n "$keypub" ] || { rm -rf "$tmp"; die "cannot derive public key from private key"; }
    for c in "$tmp"/part*.pem; do
        [ -f "$c" ] || continue
        if [ "$(openssl x509 -in "$c" -noout -pubkey 2>/dev/null | sha256sum | cut -d" " -f1)" = "$keypub" ]; then
            leaf="$c"
            break
        fi
    done
    [ -n "$leaf" ] || { rm -rf "$tmp"; die "private key does not match any certificate in the input"; }

    openssl x509 -checkend 0 -noout -in "$leaf" >/dev/null 2>&1 \
        || { rm -rf "$tmp"; die "certificate is already expired"; }

    local dir="$appdir/certs/$svc"
    mkdir -p "$dir"
    install -m 0600 "$tmp/key.pem" "$dir/tls.key"
    install -m 0644 "$leaf" "$dir/tls.crt"
    : > "$dir/chain.crt"
    for c in "$tmp"/part*.pem; do
        [ "$c" = "$leaf" ] && continue
        cat "$c" >> "$dir/chain.crt"
    done
    cat "$dir/tls.crt" "$dir/chain.crt" > "$dir/fullchain.crt"
    chmod 0644 "$dir/chain.crt" "$dir/fullchain.crt"
    touch "$dir/.imported"
    rm -rf "$tmp"

    local subj sans
    subj="$(openssl x509 -noout -subject -in "$dir/tls.crt" | sed 's/^subject= *//')"
    sans="$(openssl x509 -noout -text -in "$dir/tls.crt" | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/^ *//')"
    ui_ok "Imported certificate for $app/$svc"
    ui_log "  subject: $subj"
    [ -n "$sans" ] && ui_log "  sans:    $sans"

    if systemctl is-active "sc2-${app}.service" >/dev/null 2>&1; then
        detect_engine
        orch_up "$app" "$appdir"
        ui_ok "$app redeployed with the imported certificate"
    else
        ui_log "app '$app' is not running; certificate will be used on next start"
    fi
}

# does any bundled/installed app declare services needing external PKI certs?
certs_has_pki() {
    local app
    for app in $(apps_available); do
        app_load_manifest "$SC2_ROOT/apps/$app" 2>/dev/null || continue
        [ -n "${APP_PKI:-}" ] && return 0
    done
    return 1
}

# plain-language, novice-proof instructions for finishing certificate setup.
# Everything SC2 could do automatically is done; this covers only the part
# that needs the site's PKI office.
certs_guide() {
    local fqdn app svc dir any=0
    fqdn="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo this-server)"
    printf '%s\n' \
        "WHAT IS ALREADY DONE (automatic):" \
        "  $GL_OK Encrypted connections BETWEEN the app's containers are set up." \
        "  $GL_OK Each part of the app got its own certificate from SC2's local CA." \
        "     (CA certificate, if other tools need to trust it: $CERTS_PKI_DIR/ca.crt)" \
        ""
    for app in $(apps_available); do
        app_load_manifest "$SC2_ROOT/apps/$app" 2>/dev/null || continue
        [ -n "${APP_PKI:-}" ] || continue
        for svc in $APP_PKI; do
            any=1
            dir="$SC2_INSTALL_DIR/apps/$APP_NAME/certs/$svc"
            if [ -f "$dir/.imported" ]; then
                printf '%s\n\n' "$GL_OK $APP_NAME: the official certificate is already installed. Nothing to do."
                continue
            fi
            printf '%s\n' \
                "WHAT YOU STILL NEED TO DO for '$APP_NAME':" \
                "  Right now it uses a temporary certificate, so browsers will show a" \
                "  security warning. To fix that, install an official certificate:" \
                "" \
                "  STEP 1 - Request a SERVER certificate from your PKI office (RA/LRA)." \
                "           Tell them it is for this server name:" \
                "               $fqdn" \
                "           Key type: RSA, 2048 bits or stronger." \
                "" \
                "  STEP 2 - They will give you ONE of these:" \
                "           a) one .p12 or .pfx file, plus a password" \
                "           b) separate files: certificate, private key, CA chain (.pem/.crt)" \
                "" \
                "  STEP 3 - Copy the file(s) onto this server (scp, or approved media)." \
                "           Example location: /home/$(logname 2>/dev/null || echo ec2-user)/" \
                "" \
                "  STEP 4 - Run the ONE command that matches what you received," \
                "           from the SC2 folder:" \
                "           a) sudo ./sc2 certs import $APP_NAME $svc /path/to/file.p12 --password 'PASSWORD'" \
                "           b) sudo ./sc2 certs import $APP_NAME $svc --cert cert.pem --key key.pem --chain chain.pem" \
                "           SC2 checks the files first - if something is wrong it says so" \
                "           and changes nothing." \
                "" \
                "  STEP 5 - Confirm it worked:" \
                "           sudo ./sc2 certs status     -> the '$svc' line says 'imported'" \
                "           Then open the app in a browser: no more warning." \
                ""
        done
    done
    if [ "$any" = 0 ]; then
        printf '%s\n\n' "Nothing else to do: no application in this bundle needs an official certificate."
    fi
    printf '%s\n' "(This guide is saved at $SC2_INSTALL_DIR/NEXT-STEPS.txt and can be" \
                  " reopened any time: menu > Certificate setup guide, or: sudo ./sc2 certs guide)"
    return 0
}

certs_write_next_steps() {
    [ -d "$SC2_INSTALL_DIR" ] || return 0
    certs_guide > "$SC2_INSTALL_DIR/NEXT-STEPS.txt" 2>/dev/null || true
}

# --- doctor: deterministic diagnosis of every known certificate failure ----

DOC_PROBLEMS=0
DOC_WARNINGS=0

_doc_ok()   { printf '  %s %s\n' "$GL_OK" "$1"; }
_doc_warn() { DOC_WARNINGS=$(( DOC_WARNINGS + 1 )); printf '  %s %s\n' "$GL_WARN" "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
_doc_bad()  { DOC_PROBLEMS=$(( DOC_PROBLEMS + 1 )); printf '  %s %s\n' "$GL_BAD" "$1"; [ -n "${2:-}" ] && printf '      FIX: %s\n' "$2"; }

_doc_cert_dates() {  # <cert> - expiry / not-yet-valid / clock checks
    local crt="$1" nb na now
    now="$(date +%s)"
    nb="$(date -d "$(openssl x509 -noout -startdate -in "$crt" | cut -d= -f2)" +%s 2>/dev/null || echo 0)"
    na="$(date -d "$(openssl x509 -noout -enddate   -in "$crt" | cut -d= -f2)" +%s 2>/dev/null || echo 0)"
    if [ "$na" -gt 0 ] && [ "$na" -lt "$now" ]; then
        _doc_bad "the certificate EXPIRED on $(openssl x509 -noout -enddate -in "$crt" | cut -d= -f2)" \
                 "request a new certificate from your PKI office"
    elif [ "$na" -gt 0 ] && [ "$na" -lt $(( now + 30 * 86400 )) ]; then
        _doc_warn "the certificate expires soon: $(openssl x509 -noout -enddate -in "$crt" | cut -d= -f2)" \
                  "start the renewal request with your PKI office now"
    else
        _doc_ok "validity dates are fine (expires $(openssl x509 -noout -enddate -in "$crt" | cut -d= -f2))"
    fi
    if [ "$nb" -gt $(( now + 300 )) ]; then
        _doc_bad "the certificate is not valid YET (starts $(openssl x509 -noout -startdate -in "$crt" | cut -d= -f2))" \
                 "check this server's clock ('date'); if the clock is right, the cert was issued with a future start date"
    fi
}

_doc_cert_strength() {  # <cert>
    local crt="$1" bits sig
    bits="$(openssl x509 -noout -text -in "$crt" 2>/dev/null | sed -n 's/.*Public-Key: (\([0-9]*\) bit.*/\1/p' | head -1)"
    if [ -n "$bits" ] && [ "$bits" -lt 2048 ]; then
        _doc_warn "the key is only $bits bits - too weak for FIPS mode and modern browsers" \
                  "request a new certificate with an RSA 2048+ key"
    fi
    sig="$(openssl x509 -noout -text -in "$crt" 2>/dev/null | sed -n 's/^ *Signature Algorithm: *//p' | head -1)"
    case "$sig" in
        *sha1*|*SHA1*|*md5*|*MD5*)
            _doc_warn "signed with $sig - rejected by modern browsers and FIPS mode" \
                      "request a new certificate signed with SHA-256" ;;
    esac
}

_doc_cert_san() {  # <cert>
    local crt="$1" fqdn sans
    fqdn="$(hostname -f 2>/dev/null || hostname)"
    sans="$(openssl x509 -noout -text -in "$crt" 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/^ *//')"
    if [ -z "$sans" ]; then
        _doc_warn "the certificate has no Subject Alternative Names" \
                  "modern browsers ignore the CN; ask for a cert with this server's name ($fqdn) as a SAN"
    elif printf '%s' "$sans" | grep -q "DNS:$fqdn"; then
        _doc_ok "the certificate names this server ($fqdn)"
    else
        _doc_warn "the certificate does NOT name this server ($fqdn); it names: $sans" \
                  "browsers reaching this server as '$fqdn' will warn; if that is how users connect, request a cert for that name"
    fi
}

_doctor_file() {  # <file> <password>
    local file="$1" pass="$2" tmp leaf="" c keypub nchain=0 has_key=0
    printf 'Checking %s\n' "$file"
    [ -r "$file" ] || { _doc_bad "cannot read $file" "check the path and permissions"; return; }
    tmp="$(mktemp -d)" || die "mktemp failed"
    chmod 0700 "$tmp"

    if grep -q -- "-----BEGIN" "$file" 2>/dev/null; then
        _doc_ok "file format: PEM (text)"
        cp "$file" "$tmp/certs.pem"
        if openssl pkey -in "$file" -out "$tmp/key.pem" >/dev/null 2>&1; then
            _doc_ok "a private key is included"
            has_key=1
        else
            _doc_warn "no private key in this file" \
                      "if you also received a .key file, import with: --cert THIS-FILE --key THE-KEY-FILE"
        fi
    else
        if _certs_pkcs12_extract "$file" "$pass" "$tmp"; then
            _doc_ok "file format: PKCS#12, and the password works"
            has_key=1
        else
            if [ -z "$pass" ]; then
                _doc_bad "this looks like a PKCS#12 (.p12/.pfx) file, which needs a password" \
                         "re-run with: --password 'THE-PASSWORD' (your PKI office provided it)"
            else
                _doc_bad "the password did not unlock the file (or the file is corrupted)" \
                         "double-check the password with your PKI office; re-transfer the file if it may be damaged"
            fi
            rm -rf "$tmp"; return
        fi
    fi

    awk -v dir="$tmp" '/-----BEGIN CERTIFICATE-----/{n++; f=dir"/part"n".pem"} f{print > f} /-----END CERTIFICATE-----/{f=""}' "$tmp/certs.pem"
    ls "$tmp"/part*.pem >/dev/null 2>&1 || { _doc_bad "no certificate found in the file" "this may be a key-only file; you also need the certificate"; rm -rf "$tmp"; return; }

    if [ "$has_key" = 1 ] && [ -s "$tmp/key.pem" ]; then
        keypub="$(openssl pkey -in "$tmp/key.pem" -pubout 2>/dev/null | sha256sum | cut -d' ' -f1)"
        for c in "$tmp"/part*.pem; do
            [ "$(openssl x509 -in "$c" -noout -pubkey 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$keypub" ] && { leaf="$c"; break; }
        done
        if [ -n "$leaf" ]; then
            _doc_ok "the private key matches the certificate"
        else
            _doc_bad "the private key does NOT match any certificate in the file" \
                     "you may have mixed files from two different requests; ask your PKI office to re-issue as one package"
            leaf="$tmp/part1.pem"
        fi
    else
        leaf="$tmp/part1.pem"
    fi

    printf '  %s subject: %s\n' "$GL_DOT" "$(openssl x509 -noout -subject -in "$leaf" | sed 's/^subject= *//')"
    _doc_cert_dates "$leaf"
    _doc_cert_strength "$leaf"
    _doc_cert_san "$leaf"

    for c in "$tmp"/part*.pem; do [ "$c" != "$leaf" ] && nchain=$(( nchain + 1 )); done
    if [ "$nchain" -eq 0 ]; then
        _doc_warn "no CA chain (intermediate certificates) included" \
                  "browsers may not trust the cert without it; ask your PKI office for the full chain"
    else
        : > "$tmp/chain.pem"
        for c in "$tmp"/part*.pem; do [ "$c" != "$leaf" ] && cat "$c" >> "$tmp/chain.pem"; done
        if openssl verify -CAfile "$tmp/chain.pem" "$leaf" >/dev/null 2>&1; then
            _doc_ok "the CA chain verifies ($nchain chain certificate(s))"
        else
            _doc_warn "$nchain chain certificate(s) included, but the chain does not fully verify here" \
                      "often fine (the root stays in the browser), but if browsers warn, ask for the complete chain"
        fi
    fi
    rm -rf "$tmp"

    if [ "$DOC_PROBLEMS" -eq 0 ]; then
        local app svc
        if [ "$has_key" = 1 ]; then
            printf '\n%s READY TO IMPORT. Run:\n' "$GL_OK"
        else
            printf '\n%s The certificate looks good, but the import also needs its private key.\n  When you have the key file, run:\n' "$GL_WARN"
        fi
        for app in $(apps_available); do
            app_load_manifest "$SC2_ROOT/apps/$app" 2>/dev/null || continue
            for svc in ${APP_PKI:-}; do
                if [ "$has_key" = 0 ]; then
                    printf '    sudo ./sc2 certs import %s %s --cert %s --key /path/to/key.pem\n' "$APP_NAME" "$svc" "$file"
                elif [ -n "$pass" ]; then
                    printf '    sudo ./sc2 certs import %s %s %s --password '\''...'\''\n' "$APP_NAME" "$svc" "$file"
                else
                    printf '    sudo ./sc2 certs import %s %s %s\n' "$APP_NAME" "$svc" "$file"
                fi
            done
        done
    fi
}

_doctor_installed() {
    printf 'Checking installed certificates\n'
    if [ ! -s "$CERTS_PKI_DIR/ca.crt" ]; then
        printf '  (no SC2 PKI on this system - no app declares TLS, or nothing is installed)\n'
        return
    fi
    if openssl x509 -checkend $(( 90 * 86400 )) -noout -in "$CERTS_PKI_DIR/ca.crt" >/dev/null 2>&1; then
        _doc_ok "SC2 local CA is valid ($(openssl x509 -noout -enddate -in "$CERTS_PKI_DIR/ca.crt" | cut -d= -f2))"
    else
        _doc_warn "SC2 local CA expires within 90 days" "run: sudo ./sc2 certs rotate (after the CA renews itself on the next install/upgrade)"
    fi

    local app dst svc dir keypub certpub port served filefp
    for app in $(apps_installed); do
        dst="$SC2_INSTALL_DIR/apps/$app"
        [ -d "$dst/certs" ] || continue
        [ -f "$dst/manifest" ] && app_load_manifest "$dst"
        for dir in "$dst"/certs/*/; do
            [ -f "${dir}tls.crt" ] || continue
            svc="$(basename "$dir")"
            printf '\n%s / %s (%s):\n' "$app" "$svc" "$([ -f "${dir}.imported" ] && echo "imported certificate" || echo "SC2-issued certificate")"
            _doc_cert_dates "${dir}tls.crt"
            keypub="$(openssl pkey -in "${dir}tls.key" -pubout 2>/dev/null | sha256sum | cut -d' ' -f1)"
            certpub="$(openssl x509 -in "${dir}tls.crt" -noout -pubkey 2>/dev/null | sha256sum | cut -d' ' -f1)"
            if [ "$keypub" = "$certpub" ]; then
                _doc_ok "key and certificate match"
            else
                _doc_bad "key and certificate DO NOT match - the app cannot serve TLS with these" \
                         "re-import the correct pair, or run: sudo ./sc2 certs rotate"
            fi
            case " ${APP_PKI:-} " in
                *" $svc "*)
                    [ -f "${dir}.imported" ] || _doc_warn "still using the temporary SC2 certificate (browsers will warn)" \
                        "see: sudo ./sc2 certs guide"
                    _doc_cert_san "${dir}tls.crt"
                    # live check: is the app actually serving this certificate?
                    if [ -f "$dst/app.spec" ]; then
                        orch_load_spec "$dst" 2>/dev/null || true
                        port="$(orch_svcvar "$svc" PORTS | awk '{print $1}' | cut -d: -f1)"
                        if [ -n "$port" ]; then
                            served="$(echo | timeout 5 openssl s_client -connect "localhost:$port" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
                            filefp="$(openssl x509 -noout -fingerprint -sha256 -in "${dir}tls.crt" 2>/dev/null)"
                            if [ -z "$served" ]; then
                                _doc_bad "nothing is answering TLS on port $port" \
                                         "check the app: systemctl status sc2-${app}  (and: sudo ./sc2 status)"
                            elif [ "$served" = "$filefp" ]; then
                                _doc_ok "the app is live on port $port and serving this certificate"
                            else
                                _doc_warn "the app on port $port is serving a DIFFERENT certificate than the one on disk" \
                                          "restart it to pick up the new cert: sudo systemctl restart sc2-${app}"
                            fi
                        fi
                    fi
                    ;;
            esac
        done
    done
}

certs_doctor() {
    DOC_PROBLEMS=0
    DOC_WARNINGS=0
    local file="" pass=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --password) pass="${2:-}"; shift ;;
            -*) die "certs doctor: unknown option $1" ;;
            *) file="$1" ;;
        esac
        shift
    done
    if [ -n "$file" ]; then
        _doctor_file "$file" "$pass"
    else
        _doctor_installed
    fi
    printf '\n'
    if [ "$DOC_PROBLEMS" -gt 0 ]; then
        printf '%s %d problem(s) found - fixes are listed above.\n' "$GL_BAD" "$DOC_PROBLEMS"
        return 1
    elif [ "$DOC_WARNINGS" -gt 0 ]; then
        printf '%s No blocking problems; %d thing(s) worth knowing above.\n' "$GL_WARN" "$DOC_WARNINGS"
    else
        printf '%s Everything checks out.\n' "$GL_OK"
    fi
    return 0
}

certs_cli() {
    local sub="${1:-status}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        status) certs_status ;;
        rotate) certs_rotate ;;
        import) certs_import "$@" ;;
        guide)  certs_guide ;;
        doctor) certs_doctor "$@" ;;
        *) die "usage: sc2 certs [status | rotate | guide | doctor [file] | import <app> <svc> <file> ...]" ;;
    esac
}
