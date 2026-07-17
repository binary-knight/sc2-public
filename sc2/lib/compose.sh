# shellcheck shell=bash
# compose.sh - converts a docker-compose.yml (supported subset) into a flat,
# bash-sourceable app.spec that the SC2 orchestrator executes. Pure awk, so
# conversion happens on the target host with no python/yaml dependency.
#
# Supported compose subset (anything else fails loudly, never silently):
#   services.<name>.image                 (required)
#   services.<name>.command               string, block list, or inline array
#   services.<name>.entrypoint            single value only
#   services.<name>.ports                 list of "HOST:CTR[/proto]"
#   services.<name>.volumes               list; named vol, absolute bind, or ./rel bind
#   services.<name>.environment           list (KEY=VAL) or map (KEY: VAL)
#   services.<name>.depends_on            list or map (conditions ignored with a warning)
#   services.<name>.restart / user / privileged
#   services.<name>.expose                accepted and ignored (ports are explicit)
#   volumes:                              named volumes, no driver options
#
# Explicitly rejected: custom networks (SC2 creates one isolated network per
# app), container_name (conflicts with SC2 naming), healthcheck, and any
# unrecognized key.

read -r -d '' _COMPOSE_AWK <<'COMPOSE_AWK' || true
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }

function die(msg) {
    printf "line %d: %s\n", NR, msg > "/dev/stderr"
    exit 2
}

function warn(msg) { printf "line %d: %s\n", NR, msg > "/dev/stderr" }

function shq(s) { gsub(/'/, "'\\''", s); return "'" s "'" }

function unq(s,   c) {
    s = trim(s)
    if (length(s) >= 2) {
        c = substr(s, 1, 1)
        if ((c == "\"" || c == "'") && substr(s, length(s), 1) == c)
            s = substr(s, 2, length(s) - 2)
    }
    return s
}

# cut a trailing " # comment" that is not inside quotes
function strip_comment(s,   i, ch, inq, qc) {
    inq = 0
    for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (inq) { if (ch == qc) inq = 0 }
        else if (ch == "\"" || ch == "'") { inq = 1; qc = ch }
        else if (ch == "#" && (i == 1 || substr(s, i-1, 1) ~ /[ \t]/))
            return substr(s, 1, i - 1)
    }
    return s
}

# parse inline array [a, "b", 'c'] into out[]; returns count
function parse_array(s, out,   i, ch, cur, inq, qc, n, seen) {
    sub(/^\[/, "", s); sub(/\][ \t\r]*$/, "", s)
    n = 0; cur = ""; inq = 0; seen = 0
    for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (inq) {
            if (ch == qc) inq = 0
            else cur = cur ch
        } else if (ch == "\"" || ch == "'") { inq = 1; qc = ch; seen = 1 }
        else if (ch == ",") { out[++n] = trim(cur); cur = ""; seen = 0 }
        else cur = cur ch
    }
    if (inq) die("unterminated quote in inline array")
    cur = trim(cur)
    if (cur != "" || seen) out[++n] = cur
    return n
}

# split a scalar command string into words, honoring quotes
function parse_words(s, out,   i, ch, cur, inq, qc, n) {
    n = 0; cur = ""; inq = 0
    for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (inq) {
            if (ch == qc) inq = 0
            else cur = cur ch
        } else if (ch == "\"" || ch == "'") { inq = 1; qc = ch }
        else if (ch == " " || ch == "\t") { if (cur != "") { out[++n] = cur; cur = "" } }
        else cur = cur ch
    }
    if (inq) die("unterminated quote in command string")
    if (cur != "") out[++n] = cur
    return n
}

function quote_join(arr, n,   i, q) {
    q = ""
    for (i = 1; i <= n; i++) q = q (i > 1 ? " " : "") shq(arr[i])
    return q
}

function additem(svc, k, item) {
    if (k == "ports" || k == "volumes" || k == "depends_on") {
        if (item ~ /[ \t]/) die(k " entry may not contain spaces: " item)
        I[svc, k] = I[svc, k] (I[svc, k] == "" ? "" : " ") item
    } else if (k == "environment") {
        I[svc, k] = I[svc, k] (I[svc, k] == "" ? "" : " ") shq(item)
    }
}

BEGIN { mode = ""; svc = ""; key = ""; nsvc = 0; nvol = 0; L1 = 0; L2 = 0; L3 = 0 }

{
    raw = $0
    sub(/\r$/, "", raw)
    if (raw ~ /^[ \t]*$/) next
    if (raw ~ /^[ \t]*#/) next
    if (raw ~ /^[ ]*\t/) die("tab indentation is not supported")
    match(raw, /^ */); ind = RLENGTH
    s = trim(strip_comment(substr(raw, ind + 1)))
    if (s == "") next

    if (ind == 0) {
        key = ""; svc = ""
        if (s == "services:")      { mode = "services"; next }
        if (s == "volumes:")       { mode = "volumes";  next }
        if (s ~ /^version:/)       { mode = "skip";     next }
        if (s ~ /^name:/)          { mode = "skip";     next }
        if (s ~ /^x-/)             { mode = "skip";     next }
        if (s ~ /^networks:/)
            die("custom networks are not supported - SC2 creates one isolated network per app")
        die("unsupported top-level key: " s)
    }

    if (mode == "skip") next

    if (mode == "volumes") {
        if (L1 == 0) L1 = ind
        if (ind == L1) {
            if (s !~ /:/) die("expected volume name")
            vname = s; sub(/:.*$/, "", vname); vname = unq(vname)
            rest = s; sub(/^[^:]*:/, "", rest); rest = trim(rest)
            if (rest != "" && rest != "{}")
                die("volume driver options are not supported: " s)
            vollist[++nvol] = vname
            next
        }
        die("volume driver options are not supported: " s)
    }

    if (mode == "services") {
        if (L1 == 0) L1 = ind
        if (ind == L1) {
            if (s !~ /:[ \t]*$/) die("expected 'servicename:' but got: " s)
            svc = s; sub(/:[ \t]*$/, "", svc); svc = unq(svc)
            if (svc ~ /[ \t]/) die("bad service name: " svc)
            svclist[++nsvc] = svc; key = ""
            next
        }
        if (svc == "") die("content before first service: " s)
        if (L2 == 0 && ind > L1) L2 = ind

        if (ind == L2) {
            pos = index(s, ":")
            if (pos == 0) die("expected 'key: value' but got: " s)
            k = trim(substr(s, 1, pos - 1)); v = trim(substr(s, pos + 1))
            key = k
            if (k == "image" || k == "restart" || k == "user" || k == "privileged") {
                if (v == "") die(k " needs a value")
                P[svc, k] = unq(v); next
            }
            if (k == "entrypoint") {
                if (v ~ /^\[/) {
                    n = parse_array(v, arr)
                    if (n != 1) die("multi-element entrypoint is not supported; fold extra args into command")
                    P[svc, k] = arr[1]
                } else if (v != "") P[svc, k] = unq(v)
                else die("block-list entrypoint is not supported; use a single value")
                next
            }
            if (k == "command") {
                if (v ~ /^\[/)      { n = parse_array(v, arr); P[svc, k] = quote_join(arr, n) }
                else if (v != "")   { n = parse_words(v, arr);  P[svc, k] = quote_join(arr, n) }
                next
            }
            if (k == "ports" || k == "volumes" || k == "environment" || k == "depends_on") {
                if (v ~ /^\[/) {
                    n = parse_array(v, arr)
                    for (i = 1; i <= n; i++) additem(svc, k, arr[i])
                } else if (v != "") die(k " must be a list")
                next
            }
            if (k == "expose") { key = "ignore"; next }
            if (k == "container_name")
                die("container_name is not supported - SC2 names containers sc2-<app>-<service>-1")
            if (k == "healthcheck")
                die("healthcheck is not supported by the SC2 orchestrator")
            die("unsupported compose key for service '" svc "': " k)
        }

        if (L3 == 0 && ind > L2) L3 = ind

        if (ind == L3) {
            if (key == "ignore") next
            if (s ~ /^- /) {
                item = unq(trim(substr(s, 3)))
                if (key == "command")
                    P[svc, key] = P[svc, key] (P[svc, key] == "" ? "" : " ") shq(item)
                else if (key == "ports" || key == "volumes" || key == "environment" || key == "depends_on")
                    additem(svc, key, item)
                else die("unexpected list item under '" key "'")
                next
            }
            pos = index(s, ":")
            if (pos > 0 && key == "environment") {
                ek = trim(substr(s, 1, pos - 1)); ev = unq(trim(substr(s, pos + 1)))
                additem(svc, "environment", unq(ek) "=" ev)
                next
            }
            if (pos > 0 && key == "depends_on") {
                additem(svc, "depends_on", unq(trim(substr(s, 1, pos - 1))))
                next
            }
            die("unsupported syntax under '" key "': " s)
        }

        if (ind > L3 && key == "depends_on") {
            if (s ~ /^condition:[ \t]*service_started/) next
            if (s ~ /^condition:/) { warn("depends_on condition ignored: " s); next }
            die("unsupported depends_on option: " s)
        }
        if (key == "ignore") next
        die("unsupported nesting: " s)
    }

    die("content outside services/volumes: " s)
}

END {
    if (nsvc == 0) die("no services defined")
    all = ""
    for (i = 1; i <= nsvc; i++) all = all (i > 1 ? " " : "") svclist[i]
    printf "SPEC_SERVICES=%s\n", shq(all)
    all = ""
    for (i = 1; i <= nvol; i++) all = all (i > 1 ? " " : "") vollist[i]
    printf "SPEC_VOLUMES=%s\n", shq(all)
    for (i = 1; i <= nsvc; i++) {
        svc = svclist[i]
        if (P[svc, "image"] == "") die("service '" svc "' has no image")
        san = svc; gsub(/[^A-Za-z0-9_]/, "_", san)
        printf "SVC_%s_IMAGE=%s\n",      san, shq(P[svc, "image"])
        printf "SVC_%s_COMMAND=%s\n",    san, shq(P[svc, "command"])
        printf "SVC_%s_ENTRYPOINT=%s\n", san, shq(P[svc, "entrypoint"])
        printf "SVC_%s_PORTS=%s\n",      san, shq(I[svc, "ports"])
        printf "SVC_%s_VOLUMES=%s\n",    san, shq(I[svc, "volumes"])
        printf "SVC_%s_ENV=%s\n",        san, shq(I[svc, "environment"])
        printf "SVC_%s_DEPENDS=%s\n",    san, shq(I[svc, "depends_on"])
        printf "SVC_%s_RESTART=%s\n",    san, shq(P[svc, "restart"])
        printf "SVC_%s_USER=%s\n",       san, shq(P[svc, "user"])
        printf "SVC_%s_PRIVILEGED=%s\n", san, shq(P[svc, "privileged"])
    }
}
COMPOSE_AWK

compose_to_spec() {  # <docker-compose.yml> <out.spec>
    local in="$1" out="$2" tmp
    tmp="$(mktemp)" || die "mktemp failed"
    if awk "$_COMPOSE_AWK" "$in" > "$tmp" 2> "$tmp.err"; then
        [ -s "$tmp.err" ] && ui_warn "compose converter ($in): $(tr '\n' ' ' < "$tmp.err")"
        mv "$tmp" "$out"
        rm -f "$tmp.err"
    else
        local msg
        msg="$(tr '\n' ' ' < "$tmp.err")"
        rm -f "$tmp" "$tmp.err"
        die "unsupported docker-compose.yml in $(dirname "$in"): $msg"
    fi
}

compose_validate() {  # <docker-compose.yml> - dry run, no output
    local in="$1" errf
    errf="$(mktemp)" || die "mktemp failed"
    if ! awk "$_COMPOSE_AWK" "$in" > /dev/null 2> "$errf"; then
        local msg
        msg="$(tr '\n' ' ' < "$errf")"
        rm -f "$errf"
        die "unsupported docker-compose.yml in $(dirname "$in"): $msg"
    fi
    rm -f "$errf"
}
