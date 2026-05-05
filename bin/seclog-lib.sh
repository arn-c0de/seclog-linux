#!/bin/bash
# Shared helpers sourced by seclog and ssh-login-notify.sh.

C_RED=$'\033[31m'
C_GRN=$'\033[32m'
C_YEL=$'\033[33m'
C_BLU=$'\033[34m'
C_OFF=$'\033[0m'
C_BLD=$'\033[1m'

# Returns country string for an IP, or [LAN] for private ranges.
# Requires: geoip-bin + geoip-database (apt install geoip-bin geoip-database)
geo_lookup() {
    local ip="$1" second
    # Strip IPv6-mapped IPv4: [::ffff:1.2.3.4] -> 1.2.3.4
    ip="${ip#\[}"; ip="${ip%\]}"; ip="${ip#::ffff:}"; ip="${ip#::FFFF:}"
    case "$ip" in
        127.*|10.*|169.254.*|::1|fe80*) echo "[LAN]"; return ;;
        192.168.*)                       echo "[LAN]"; return ;;
        172.*)
            second=$(printf '%s' "$ip" | cut -d. -f2)
            { [ "$second" -ge 16 ] && [ "$second" -le 31 ]; } 2>/dev/null && { echo "[LAN]"; return; }
            ;;
    esac
    command -v geoiplookup >/dev/null 2>&1 || return
    geoiplookup "$ip" 2>/dev/null \
        | awk -F': ' '/Country Edition/ { sub(/^[[:space:]]+/,"",$2); print $2; exit }'
}

# Prints grouped all-active-connections block to stdout.
# Requires: ss, who, geo_lookup
show_active_connections() {
    local _CONNS_RAW ACTIVE_COUNT

    _CONNS_RAW=$(ss -tnp 2>/dev/null | awk '
    $1 == "ESTAB" {
        local = $4; peer = $5
        pname = "-"
        rest = ""; for (i = 6; i <= NF; i++) rest = rest $i
        if (match(rest, /"[^"]+"/)) pname = substr(rest, RSTART+1, RLENGTH-2)
        nl = split(local, la, ":"); lport = la[nl]+0
        np = split(peer,  pa, ":"); pport = pa[np]+0
        dir = (lport <= pport) ? "IN" : "OUT"
        if (dir == "IN") {
            peer_ip = peer; sub(/:[^:]+$/, "", peer_ip)
            key = dir "|" peer_ip "|" lport "|" pname
        } else {
            key = dir "|" peer "|" pname
        }
        count[key]++
    }
    END { for (k in count) printf "%s|%d\n", k, count[k] }' \
    | sort -t'|' -k1,1r -k2,2)

    ACTIVE_COUNT=$(ss -tnp 2>/dev/null | grep -c ESTAB)

    printf '%s\n' "${C_BLD}${C_BLU}── All active connections ($ACTIVE_COUNT) ──${C_OFF}"
    if [ -n "$_CONNS_RAW" ]; then
        while IFS='|' read -r dir a b c cnt; do
            [ -z "$dir" ] && continue
            if [ "$dir" = "IN" ]; then
                geo=$(geo_lookup "$a")
                users=$(who 2>/dev/null | grep -F "($a)" | awk '{print $1}' | sort -u | paste -sd',' -)
                echo "  [IN ]  $a -> :$b"
                echo "         app: $c  |  ${geo:-(unknown)}${users:+  |  $users}"
            else
                geo=$(geo_lookup "${a%%:*}")
                n="${c:-1}"
                echo "  [OUT]  $a"
                printf '         app: %s  |  %s%s\n' "$b" "${geo:-(unknown)}" \
                    "$([ "${n}" -gt 1 ] 2>/dev/null && echo " (${n}x)")"
            fi
            echo
        done <<< "$_CONNS_RAW"
    else
        echo "  (none)"
        echo
    fi
}
