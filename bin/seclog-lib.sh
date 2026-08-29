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

# journalctl matchers for the sshd daemon. Modern OpenSSH splits the per-session
# work into `sshd-session`, older releases log everything as `sshd`.
SECLOG_SSHD_MATCH=(_COMM=sshd-session _COMM=sshd)

# ─────────────────────────────────────────────────────────────── config ──

# Load the user config and fill in defaults. Idempotent.
seclog_load_config() {
    if [[ -f $SECLOG_CONFIG ]]; then
        # shellcheck disable=SC1090
        . "$SECLOG_CONFIG"
    fi

    NTFY_URL="${NTFY_URL:-}"
    NTFY_TOKEN="${NTFY_TOKEN:-}"
    NTFY_TIMEOUT="${NTFY_TIMEOUT:-5}"
    FAIL_LOOKBACK="${FAIL_LOOKBACK:-24 hours ago}"
    FAIL_RATELIMIT_WINDOW="${FAIL_RATELIMIT_WINDOW:-300}"
    PUSH_METADATA_LEVEL="${PUSH_METADATA_LEVEL:-full}"
    # 0 disables the timeout. LOGIN_JOURNAL_TIMEOUT is the pre-1.1 name.
    JOURNAL_TIMEOUT="${JOURNAL_TIMEOUT:-${LOGIN_JOURNAL_TIMEOUT:-2}}"
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

# ─────────────────────────────────────────────────────────────── ntfy ────

# seclog_push <title> <tags> <priority> <body>
# Returns non-zero when ntfy is unconfigured or the request fails.
seclog_push() {
    local title="$1" tags="$2" priority="$3" body="$4"
    seclog_ntfy_configured || return 1

    local -a curl_args=(
        --fail --silent --show-error --max-time "$NTFY_TIMEOUT"
        -H "Title: $title"
        -H "Tags: $tags"
        -H "Priority: $priority"
    )
    [[ -n ${NTFY_TOKEN:-} ]] && curl_args+=(-H "Authorization: Bearer $NTFY_TOKEN")

    curl "${curl_args[@]}" --data-binary "$body" "$NTFY_URL" >/dev/null 2>&1
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

# ──────────────────────────────────────────────────────── ip / geo-lookup ──

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

# Country name for an IP, "[LAN]" for private ranges, empty when unknown.
# Geo data needs: apt install geoip-bin geoip-database
seclog_geo() {
    local ip
    ip="$(seclog_normalize_ip "$1")"
    [[ -z $ip ]] && return 0

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

# ─────────────────────────────────────────────── established connections ──

# Collect established TCP connections from a single `ss` call and export:
#   SECLOG_CONN_ROWS   tab-separated: direction, peer-ip, port, process, count
#   SECLOG_CONN_TOTAL  number of established sockets
#   SECLOG_CONN_PEERS  comma-separated list of distinct inbound peer IPs
seclog_collect_connections() {
    local sockets
    sockets="$(ss -tnp 2>/dev/null)"

    SECLOG_CONN_TOTAL="$(awk '$1 == "ESTAB" { n++ } END { print n + 0 }' <<<"$sockets")"

    SECLOG_CONN_ROWS="$(awk '
        function port(addr,   p) { p = addr; sub(/.*:/, "", p); return p + 0 }
        function host(addr,   h) { h = addr; sub(/:[^:]*$/, "", h); gsub(/^\[|\]$/, "", h); return h }

        BEGIN { OFS = "\t" }
        $1 != "ESTAB" { next }
        {
            # The process column is quoted, e.g. users:(("sshd",pid=1,fd=2)).
            process = "-"; rest = ""
            for (i = 6; i <= NF; i++) rest = rest $i
            if (match(rest, /"[^"]+"/)) process = substr(rest, RSTART + 1, RLENGTH - 2)

            local_port = port($4); peer_port = port($5)
            # The lower port is the listening side, so a low local port means
            # somebody connected to us.
            if (local_port <= peer_port)
                key = "IN"  OFS host($5) OFS local_port OFS process
            else
                key = "OUT" OFS host($5) OFS peer_port  OFS process
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
}

# ──────────────────────────────────────────────────── successful logins ──

# Print the most recent successful SSH logins, one per distinct source IP.
seclog_print_logins() {
    local limit="${1:-5}" rows date user ip

    seclog_heading "$C_GRN" "Last $limit successful logins (distinct IPs)"

    rows="$(seclog_journal -r "${SECLOG_SSHD_MATCH[@]}" | awk -v limit="$limit" '
        BEGIN { OFS = "|" }
        /Accepted/ {
            for (i = 1; i <= NF; i++)
                if ($i == "from" && !seen[$(i + 1)]++) {
                    print $1 " " $2 " " $3, $(i - 1), $(i + 1)
                    if (++shown >= limit) exit
                }
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
    SECLOG_FAIL_ROWS="$(seclog_journal --since "$FAIL_LOOKBACK" "${SECLOG_SSHD_MATCH[@]}" | awk '
        /Failed password for|Invalid user|authentication failure/ {
            ip = ""; user = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "from")                  ip   = $(i + 1)
                if ($i == "for")                   user = $(i + 1)
                if (user == "invalid" && $i == "user") user = $(i + 1)
            }
            if (ip == "") next
            key = ip "|" (user == "" ? "?" : user)
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
