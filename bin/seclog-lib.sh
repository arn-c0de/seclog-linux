#!/usr/bin/env bash
# seclog-lib.sh — shared library for all seclog-linux commands.
#
# Sourced by: seclog, seclog-login, seclog-monitor, seclog-diagnose, seclog-update.
# Everything here is namespaced with `seclog_` / `SECLOG_` so that sourcing the
# library never collides with the caller's own names.

# shellcheck disable=SC2034  # consumed by the commands that source this file
SECLOG_VERSION="1.1.0"

SECLOG_CONFIG="${SECLOG_CONFIG:-${SSH_NOTIFY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/seclog-linux/config}}"
SECLOG_NTFY_PLACEHOLDER="http://YOUR_NTFY_HOST:2586/YOUR_TOPIC"
SECLOG_LOGGER="$(command -v logger 2>/dev/null || true)"

# journalctl matchers for the sshd daemon. Modern OpenSSH splits the per-session
# work into `sshd-session`, older releases log everything as `sshd`.
SECLOG_SSHD_MATCH=(_COMM=sshd-session _COMM=sshd)

# ────────────────────────────────────────────────────────────── logging ──

# Local audit trail, primarily journald via logger(1). The journal is not
# writable by the account being monitored, so someone who takes over that
# account can stop future notifications but cannot quietly erase the record
# that earlier ones were sent — or that a send failed.
# Levels: info | notice | warning | err
seclog_log() {
    local level="$1"; shift
    [[ -n $SECLOG_LOGGER ]] && "$SECLOG_LOGGER" -t seclog-linux -p "auth.$level" -- "$*" 2>/dev/null
    # The journal is the durable record, but anything the operator has to act
    # on has to reach them where they are — a monitoring tool that fails
    # quietly is worse than no monitoring tool.
    case "$level" in
        err|warning) printf 'seclog-linux[%s]: %s\n' "$level" "$*" >&2 ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────── config ──

# True when `path` is owned by us (or root) and not writable by anyone else.
seclog_path_is_trusted() {
    local path="$1" owner mode
    owner="$(stat -Lc '%u' "$path" 2>/dev/null)" || return 1
    [[ $owner == "$(id -u)" || $owner == 0 ]] || return 1
    mode="$(stat -Lc '%a' "$path" 2>/dev/null)" || return 1
    (( 8#$mode & 8#022 )) && return 1
    return 0
}

# Echo $1 when it is a plain non-negative integer, otherwise the fallback $2.
# Several of these values end up in an arithmetic context, where bash evaluates
# what it finds rather than merely reading it.
seclog_uint() {
    [[ ${1:-} =~ ^[0-9]+$ ]] && { printf '%s' "$1"; return 0; }
    printf '%s' "$2"
}

# Load the user config and fill in defaults. Idempotent.
#
# The config is sourced, so it is executed as shell code by every seclog
# command — and it also carries the update trust settings (expected git origin,
# repository path, expected signer). Anyone able to write it, or the directory
# holding it, therefore has code execution as this user. Refuse rather than
# warn.
seclog_load_config() {
    local dir
    if [[ -e $SECLOG_CONFIG ]]; then
        dir="$(dirname -- "$SECLOG_CONFIG")"
        if ! seclog_path_is_trusted "$dir"; then
            seclog_log err "refusing to read $SECLOG_CONFIG: $dir is foreign-owned or writable by group/others — fix with: chmod 700 '$dir'"
            exit 1
        fi
        if ! seclog_path_is_trusted "$SECLOG_CONFIG"; then
            seclog_log err "refusing to source $SECLOG_CONFIG: not owned by you, or group/world writable — fix with: chmod 600 '$SECLOG_CONFIG'"
            exit 1
        fi
        # shellcheck disable=SC1090
        . "$SECLOG_CONFIG"
    fi

    NTFY_URL="${NTFY_URL:-}"
    NTFY_TOKEN="${NTFY_TOKEN:-}"
    NTFY_TIMEOUT="$(seclog_uint "${NTFY_TIMEOUT:-}" 5)"
    # Plaintext HTTP to anything outside the local network needs an explicit
    # opt-in; see seclog_transport_ok.
    NTFY_ALLOW_PLAINTEXT="${NTFY_ALLOW_PLAINTEXT:-0}"
    FAIL_LOOKBACK="${FAIL_LOOKBACK:-24 hours ago}"
    FAIL_RATELIMIT_WINDOW="$(seclog_uint "${FAIL_RATELIMIT_WINDOW:-}" 300)"
    # Successful logins are reported by the monitor by default: it sees every
    # login (scp, sftp, rsync, `ssh host cmd`, any shell), while the .bashrc
    # banner only ever sees interactive bash. monitor | banner | both
    LOGIN_PUSH_SOURCE="${LOGIN_PUSH_SOURCE:-monitor}"
    LOGIN_DEDUP_WINDOW="$(seclog_uint "${LOGIN_DEDUP_WINDOW:-}" 60)"
    # `full` adds uid, groups, rDNS, SSH key fingerprint and TTY to the push.
    PUSH_METADATA_LEVEL="${PUSH_METADATA_LEVEL:-minimal}"
    STATE_TTL_DAYS="$(seclog_uint "${STATE_TTL_DAYS:-}" 7)"
    # 0 disables the timeout. LOGIN_JOURNAL_TIMEOUT is the pre-1.1 name.
    JOURNAL_TIMEOUT="$(seclog_uint "${JOURNAL_TIMEOUT:-${LOGIN_JOURNAL_TIMEOUT:-}}" 2)"
}

# True when NTFY_URL points somewhere other than the shipped placeholder.
seclog_ntfy_configured() {
    [[ -n ${NTFY_URL:-} && $NTFY_URL != "$SECLOG_NTFY_PLACEHOLDER" ]]
}

# ─────────────────────────────────────────────────────────────── output ──

# Define C_* colour variables, empty when stdout is not a terminal or the
# caller opted out via NO_COLOR.
seclog_init_colors() {
    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
        C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
        C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
    else
        C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_OFF=''
    fi
}

seclog_heading() {
    local color="$1" text="$2"
    printf '%s── %s ──%s\n' "${C_BLD}${color}" "$text" "${C_OFF}"
}

# ─────────────────────────────────────────────────────────── addresses ──

# True for a syntactically plausible IPv4 or IPv6 literal. Used before values
# taken from logs or `ss` are handed to another program as an argument.
seclog_valid_ip() {
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
    [[ $1 =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f.:]+$ ]] && return 0
    return 1
}

# Strip brackets and the IPv4-mapped IPv6 prefix: [::ffff:1.2.3.4] -> 1.2.3.4
seclog_normalize_ip() {
    local ip="$1"
    ip="${ip#\[}"; ip="${ip%\]}"
    ip="${ip#::ffff:}"; ip="${ip#::FFFF:}"
    printf '%s' "$ip"
}

# RFC1918 + loopback + link-local + CGNAT + IPv6 ULA.
seclog_is_private_ip() {
    case "$1" in
        10.*|127.*|169.254.*|192.168.*)            return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*)     return 0 ;;
        100.6[4-9].*|100.[789][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        ::1|fe80:*|fc*:*|fd*:*)                    return 0 ;;
    esac
    return 1
}

# Host part of a URL, including bracketed IPv6 literals.
seclog_url_host() {
    local host="${1#*://}"
    host="${host%%/*}"
    host="${host%%\?*}"
    host="${host##*@}"
    if [[ $host == \[*\]* ]]; then
        host="${host#\[}"; host="${host%%\]*}"
    else
        host="${host%%:*}"
    fi
    printf '%s' "$host"
}

# Country name for an IP, "[LAN]" for private ranges, empty when unknown.
# Geo data needs: apt install geoip-bin geoip-database
seclog_geo() {
    local ip
    ip="$(seclog_normalize_ip "$1")"
    [[ -z $ip ]] && return 0
    # Never hand an unvalidated string to geoiplookup: a value starting with
    # "-" would be parsed as an option.
    seclog_valid_ip "$ip" || return 0

    if seclog_is_private_ip "$ip"; then
        printf '[LAN]'
        return 0
    fi

    # The legacy GeoIP databases are split: geoiplookup is IPv4-only.
    local tool="geoiplookup"
    [[ $ip == *:* ]] && tool="geoiplookup6"
    command -v "$tool" >/dev/null 2>&1 || return 0

    "$tool" "$ip" 2>/dev/null |
        awk -F': ' '/Country Edition/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }'
}

# Render an address as "ip:port", bracketing IPv6 so the colons stay readable.
seclog_format_endpoint() {
    if [[ $1 == *:* ]]; then
        printf '[%s]:%s' "$1" "$2"
    else
        printf '%s:%s' "$1" "$2"
    fi
}

# Same as seclog_geo but never returns an empty string.
seclog_geo_or_unknown() {
    local geo
    geo="$(seclog_geo "$1")"
    printf '%s' "${geo:-(unknown)}"
}

# ─────────────────────────────────────────────────────────────── ntfy ────

# Emit one curl --config line with a properly escaped value.
seclog_curl_option() {
    local value="$2"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s = "%s"\n' "$1" "$value"
}

# The push body is a complete reconnaissance profile of the host — account,
# uid, group membership, client address, SSH key fingerprint, every active peer
# — and the bearer token travels in the same request. Refuse plaintext HTTP
# unless the target is on the local network or the user accepted the risk.
seclog_transport_ok() {
    case "${NTFY_URL:-}" in
        https://*) return 0 ;;
        http://*)  ;;
        *)         return 1 ;;
    esac
    [[ ${NTFY_ALLOW_PLAINTEXT:-0} == 1 ]] && return 0

    local host
    host="$(seclog_url_host "$NTFY_URL")"
    [[ $host == localhost ]] && return 0
    seclog_is_private_ip "$(seclog_normalize_ip "$host")"
}

# seclog_push <title> <tags> <priority> <body>
# Returns non-zero when ntfy is unconfigured, the transport is unsafe, or the
# request fails. Every outcome is recorded through seclog_log.
seclog_push() {
    local title="$1" tags="$2" priority="$3" body="$4" proto err rc=0

    if ! seclog_ntfy_configured; then
        seclog_log warning "push skipped, NTFY_URL is not configured: $title"
        return 1
    fi
    if ! seclog_transport_ok; then
        seclog_log err "push REFUSED, $NTFY_URL would send credentials and host metadata over plaintext HTTP to a non-local address; use https:// or set NTFY_ALLOW_PLAINTEXT=1 to accept the risk"
        return 1
    fi

    proto="=https"
    [[ $NTFY_URL == http://* ]] && proto="=http,https"

    # URL, title, body and token all travel out of band: curl's argv is world
    # readable via /proc/<pid>/cmdline for every other local account.
    err="$(curl \
        --config <(
            seclog_curl_option url "$NTFY_URL"
            seclog_curl_option header "Title: $title"
            seclog_curl_option header "Tags: $tags"
            seclog_curl_option header "Priority: $priority"
            if [[ -n ${NTFY_TOKEN:-} ]]; then
                seclog_curl_option header "Authorization: Bearer $NTFY_TOKEN"
            fi
        ) \
        --fail --silent --show-error \
        --max-time "$NTFY_TIMEOUT" \
        --proto "$proto" --proto-redir "$proto" \
        --data-binary @- <<<"$body" 2>&1 >/dev/null)" || rc=$?

    if (( rc == 0 )); then
        seclog_log info "push sent: $title"
    else
        seclog_log err "push FAILED (curl exit $rc): $title${err:+ — $err}"
    fi
    return "$rc"
}

# ────────────────────────────────────────────────────────────── journal ──

# journalctl wrapper that honours JOURNAL_TIMEOUT and never leaks stderr.
seclog_journal() {
    if [[ ${JOURNAL_TIMEOUT:-0} =~ ^[0-9]+$ && ${JOURNAL_TIMEOUT:-0} -gt 0 ]]; then
        timeout "$JOURNAL_TIMEOUT" journalctl --no-pager "$@" 2>/dev/null
    else
        journalctl --no-pager "$@" 2>/dev/null
    fi
}

# True when this user probably cannot read sshd's journal entries, which makes
# an empty result ambiguous ("nothing happened" vs. "not allowed to look").
seclog_journal_restricted() {
    (( EUID != 0 )) && ! id -nG 2>/dev/null | grep -qw systemd-journal
}

# ─────────────────────────────────────────────────── sshd log line parser ──

# Awk helpers shared by the live monitor and the journal aggregation below.
#
# Parsing sshd log lines is security relevant. The user name in a failed login
# is entirely attacker supplied and OpenSSH only escapes control characters
# when logging it (strnvis with VIS_SAFE), so spaces and every other printable
# character survive. A login attempt as `x from 203.0.113.9 port 1 for root`
# lets an attacker forge any field that is read by scanning left to right —
# both misattributing the alert and, worse, pinning the rate-limit state on an
# IP of their choosing so that a single push silences everything that follows.
#
# sshd always writes the real peer as the *last* "<ip> port <n>" pair on the
# line and only appends its own trailer after it ("ssh2", "[preauth]", a key
# fingerprint), so scanning backwards from the end cannot be steered.
SECLOG_AWK_LIB='
function ip_ok(s) {
    if (s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)        return 1
    if (s ~ /^[0-9A-Fa-f:]*:[0-9A-Fa-f.:]+$/)            return 1
    return 0
}

# First token following the bare word `name`.
function after(name,   i) {
    for (i = 1; i < NF; i++) if ($i == name) return $(i + 1)
    return ""
}

# Value of the first "key=value" token, as used by the pam_unix log format.
function kv(key,   m) {
    if (!match($0, "(^|[ \t])" key "=[^ \t]+")) return ""
    m = substr($0, RSTART, RLENGTH)
    sub(/^[ \t]/, "", m)
    sub(/^[^=]*=/, "", m)
    return m
}

# Index of the last "<ip> port <n>" triple on the line, 0 when there is none.
function peer_at(   i) {
    for (i = NF - 1; i >= 2; i--)
        if ($i == "port" && $(i + 1) ~ /^[0-9]+$/ && ip_ok($(i - 1)))
            return i
    return 0
}

function peer_ip(   i, r) {
    i = peer_at()
    if (i > 0) return $(i - 1)
    r = kv("rhost")
    return ip_ok(r) ? r : ""
}

function peer_port(   i) {
    i = peer_at()
    return (i > 0) ? $(i + 1) : "?"
}

# Reduce an attacker controlled name to something that cannot forge extra
# fields in a notification body or a terminal table.
function safe_name(s) {
    if (s == "") return "?"
    gsub(/[^A-Za-z0-9._@-]/, "_", s)
    return (length(s) > 32) ? substr(s, 1, 32) "..." : s
}

# Index of the token that opens the sshd message, 0 when unrecognised. The
# journal prefix and sshd`s own keyword both come before the user name, so the
# first match cannot be supplied by the attacker.
function msg_start(   i) {
    for (i = 1; i <= NF; i++)
        if ($i == "Accepted" || $i == "Failed" || $i == "Invalid" || $i == "Disconnected")
            return i
    return 0
}

# The account a login referred to. Read positionally from the known grammar --
# searching the line for "for" or "user" lets a name like `x for root` pick the
# reported account.
function login_user(   i, u) {
    i = msg_start()
    if (i > 0) {
        if      ($i == "Invalid"      && $(i + 1) == "user") u = $(i + 2)
        else if ($i == "Accepted"     && $(i + 2) == "for")  u = $(i + 3)
        else if ($i == "Disconnected" && $(i + 3) == "user") u = $(i + 4)
        else if ($i == "Failed"       && $(i + 2) == "for") {
            if ($(i + 3) == "invalid" && $(i + 4) == "user") u = $(i + 5)
            else                                            u = $(i + 3)
        }
    }
    if (u == "") u = kv("user")
    return safe_name(u)
}

# The authentication method of an "Accepted <method> for ..." line.
function auth_method(   i) {
    i = msg_start()
    if (i > 0 && $i == "Accepted") return safe_name($(i + 1))
    return "unknown"
}
'

# ─────────────────────────────────────────────── established connections ──

# Collect established TCP connections from `ss` and export:
#   SECLOG_CONN_ROWS   tab-separated: direction, peer-ip, port, process, count
#   SECLOG_CONN_TOTAL  number of established sockets
#   SECLOG_CONN_PEERS  comma-separated list of distinct inbound peer IPs
seclog_collect_connections() {
    local sockets listeners
    sockets="$(ss -tnp 2>/dev/null)"
    # Real listening ports, so the direction of a connection is a fact rather
    # than a guess. Without this a backdoor listening on a high port, reached
    # from a low source port, is reported as an outbound connection.
    listeners="$(ss -ltn 2>/dev/null |
        awk '$1 == "LISTEN" { p = $4; sub(/.*:/, "", p); print p + 0 }' |
        sort -un | paste -sd, -)"

    SECLOG_CONN_TOTAL="$(awk '$1 == "ESTAB" { n++ } END { print n + 0 }' <<<"$sockets")"

    SECLOG_CONN_ROWS="$(awk -v listen_ports="$listeners" '
        function port(addr,   p) { p = addr; sub(/.*:/, "", p); return p + 0 }
        function host(addr,   h) { h = addr; sub(/:[^:]*$/, "", h); gsub(/^\[|\]$/, "", h); return h }

        BEGIN {
            OFS = "\t"
            n = split(listen_ports, lp, ",")
            for (i = 1; i <= n; i++) if (lp[i] != "") { listening[lp[i] + 0] = 1; known = 1 }
        }
        $1 != "ESTAB" { next }
        {
            # The process column is quoted, e.g. users:(("sshd",pid=1,fd=2)).
            process = "-"; rest = ""
            for (i = 6; i <= NF; i++) rest = rest $i
            if (match(rest, /"[^"]+"/)) process = substr(rest, RSTART + 1, RLENGTH - 2)

            local_port = port($4); peer_port = port($5)
            if (known) {
                l = (local_port in listening); p = (peer_port in listening)
                if (l && !p)      inbound = 1
                else if (!l && p) inbound = 0
                else              inbound = (local_port <= peer_port)
            } else {
                inbound = (local_port <= peer_port)
            }

            if (inbound) key = "IN"  OFS host($5) OFS local_port OFS process
            else         key = "OUT" OFS host($5) OFS peer_port  OFS process
            seen[key]++
        }
        END { for (k in seen) print k, seen[k] }
    ' <<<"$sockets" | sort -t$'\t' -k1,1 -k2,2)"

    # shellcheck disable=SC2034  # read by seclog-login for the push body
    SECLOG_CONN_PEERS="$(awk -F'\t' '$1 == "IN" { print $2 }' <<<"$SECLOG_CONN_ROWS" |
        sort -u | paste -sd, -)"
}

# Render the connection block collected by seclog_collect_connections.
seclog_print_connections() {
    seclog_heading "$C_BLU" "All active connections (${SECLOG_CONN_TOTAL:-0})"

    if [[ -z ${SECLOG_CONN_ROWS:-} ]]; then
        printf '  (none)\n\n'
        return 0
    fi

    local dir peer port process count geo users repeat
    while IFS=$'\t' read -r dir peer port process count; do
        [[ -z $dir ]] && continue
        geo="$(seclog_geo_or_unknown "$peer")"
        repeat=""; (( count > 1 )) && repeat="  |  ${count}x"

        if [[ $dir == IN ]]; then
            users="$(who 2>/dev/null | grep -F "($peer)" | awk '{ print $1 }' | sort -u | paste -sd, -)"
            printf '  [IN ]  %s -> :%s\n' "$peer" "$port"
            printf '         app: %s  |  %s%s%s\n\n' \
                "$process" "$geo" "${users:+  |  $users}" "$repeat"
        else
            printf '  [OUT]  %s\n' "$(seclog_format_endpoint "$peer" "$port")"
            printf '         app: %s  |  %s%s\n\n' "$process" "$geo" "$repeat"
        fi
    done <<<"$SECLOG_CONN_ROWS"

    # `ss` only reveals the owning process for our own sockets, so say so
    # rather than letting "app: -" read as "no process".
    (( EUID != 0 )) && printf '  (app names are only visible for your own processes; run as root to see all)\n\n'
    return 0
}

# ──────────────────────────────────────────────────── successful logins ──

# Print the most recent successful SSH logins, one per distinct source IP.
seclog_print_logins() {
    local limit="${1:-5}" rows date user ip

    seclog_heading "$C_GRN" "Last $limit successful logins (distinct IPs)"

    rows="$(seclog_journal -r "${SECLOG_SSHD_MATCH[@]}" |
        awk -v limit="$limit" "$SECLOG_AWK_LIB"'
        BEGIN { OFS = "|" }
        /Accepted / {
            ip = peer_ip()
            if (ip == "" || seen[ip]++) next
            print $1 " " $2 " " $3, login_user(), ip
            if (++shown >= limit) exit
        }')"

    if [[ -n $rows ]]; then
        while IFS='|' read -r date user ip; do
            printf '  %-16s  %-12s  %-18s  %s\n' \
                "$date" "$user" "$ip" "$(seclog_geo_or_unknown "$ip")"
        done <<<"$rows"
    elif seclog_journal_restricted; then
        printf '  (journal access unavailable; add this user to the systemd-journal group)\n'
    else
        printf '  (none)\n'
    fi
    printf '\n'
}

# ─────────────────────────────────────────────────────── failed attempts ──

# Aggregate failed SSH logins over FAIL_LOOKBACK and export:
#   SECLOG_FAIL_ROWS   pipe-separated: count, last-seen, ip, user (top 10)
#   SECLOG_FAIL_TOTAL  total number of failed attempts
#   SECLOG_FAIL_IPS    number of distinct source IPs
seclog_collect_failures() {
    SECLOG_FAIL_ROWS="$(seclog_journal --since "$FAIL_LOOKBACK" "${SECLOG_SSHD_MATCH[@]}" |
        awk "$SECLOG_AWK_LIB"'
        /Failed password for|Invalid user|authentication failure/ {
            ip = peer_ip()
            if (ip == "") next
            key = ip "|" login_user()
            count[key]++
            last[key] = $1 " " $2 " " $3
        }
        END { for (k in count) printf "%d|%s|%s\n", count[k], last[k], k }
    ' | sort -t'|' -k1,1nr | head -10)"

    SECLOG_FAIL_TOTAL=0
    SECLOG_FAIL_IPS=0
    if [[ -n $SECLOG_FAIL_ROWS ]]; then
        SECLOG_FAIL_IPS="$(wc -l <<<"$SECLOG_FAIL_ROWS")"
        SECLOG_FAIL_TOTAL="$(awk -F'|' '{ total += $1 } END { print total + 0 }' <<<"$SECLOG_FAIL_ROWS")"
    fi
}

# Render the failure block collected by seclog_collect_failures.
seclog_print_failures() {
    if [[ -n ${SECLOG_FAIL_ROWS:-} ]]; then
        seclog_heading "$C_RED" \
            "⚠ Failed SSH attempts ($FAIL_LOOKBACK): $SECLOG_FAIL_TOTAL from $SECLOG_FAIL_IPS IP(s)"
        awk -F'|' '{ printf "  %3dx  %-16s  %-20s  user=%s\n", $1, $2, $3, $4 }' <<<"$SECLOG_FAIL_ROWS"
    elif seclog_journal_restricted; then
        seclog_heading "$C_YEL" "Failed SSH attempts ($FAIL_LOOKBACK): unavailable (needs journal access)"
    else
        seclog_heading "$C_YEL" "Failed SSH attempts ($FAIL_LOOKBACK): none"
    fi
}

# ──────────────────────────────────────────────────────────── full report ──

# The complete terminal report shared by `seclog` and the login banner.
seclog_print_report() {
    seclog_collect_connections
    seclog_print_connections
    seclog_print_logins 5
    seclog_collect_failures
    seclog_print_failures
}
