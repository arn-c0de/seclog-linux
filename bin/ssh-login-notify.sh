#!/bin/bash
# Runs from .bashrc on SSH login. Shows status (active sessions, last logins,
# failed attempts) and sends a rich push notification to ntfy.

[ -z "$SSH_CONNECTION" ] && return 0 2>/dev/null

CONFIG="${SSH_NOTIFY_CONFIG:-$HOME/.config/seclog-linux/config}"
[ -f "$CONFIG" ] && . "$CONFIG"

: "${NTFY_URL:?NTFY_URL not set — configure $CONFIG}"
FAIL_LOOKBACK="${FAIL_LOOKBACK:-24 hours ago}"
LOGIN_JOURNAL_TIMEOUT="${LOGIN_JOURNAL_TIMEOUT:-2}"
PUSH_METADATA_LEVEL="${PUSH_METADATA_LEVEL:-full}"

journalctl_ssh() {
    timeout "$LOGIN_JOURNAL_TIMEOUT" journalctl --no-pager "$@" 2>/dev/null
}

journal_access_may_be_limited() {
    [ "$(id -u)" -ne 0 ] && ! id -nG 2>/dev/null | grep -qw systemd-journal
}

read -r CIP CPORT SIP SPORT <<< "$SSH_CONNECTION"

CHOST=$(timeout 1 getent hosts "$CIP" 2>/dev/null | awk '{print $2; exit}')
[ -z "$CHOST" ] && CHOST="(no rDNS)"

AUTH_LINE=$(journalctl_ssh -r _COMM=sshd-session | \
    grep -m1 "Accepted .* for $USER from $CIP")
AUTH_METHOD=$(echo "$AUTH_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="Accepted") print $(i+1)}')
KEY_FP=$(echo "$AUTH_LINE" | grep -oE 'SHA256:[A-Za-z0-9+/=]+' | head -1)
KEY_TYPE=$(echo "$AUTH_LINE" | grep -oE 'ED25519|RSA|ECDSA|DSA' | head -1)

GROUPS_LIST=$(id -nG 2>/dev/null | tr ' ' ',')
UID_NUM=$(id -u)
SUDO_HINT=""
id -nG 2>/dev/null | grep -qw sudo && SUDO_HINT=" (sudo)"
TTY_NAME="${SSH_TTY:-$(tty 2>/dev/null)}"
TTY_NAME="${TTY_NAME:-none}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_OFF=$'\033[0m'; C_BLD=$'\033[1m'

# ── 1) Active SSH connections (network-level via ss) ──
SSH_PORT=$(awk '/^Port / {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
[ -z "$SSH_PORT" ] && SSH_PORT=22

ACTIVE_LINES=$(ss -tn state established "( sport = :$SSH_PORT )" 2>/dev/null | \
    awk 'NR>1 {print $4}' | awk -F: '{port=$NF; $NF=""; ip=$0; sub(/:$/,"",ip); print ip, port}')

ACTIVE_COUNT=$(echo -n "$ACTIVE_LINES" | grep -c . )
ACTIVE_IPS=$(echo "$ACTIVE_LINES" | awk '{print $1}' | sort -u | paste -sd "," -)

echo "$C_BLD$C_BLU── Currently active SSH connections ($ACTIVE_COUNT) ──$C_OFF"
if [ -n "$ACTIVE_LINES" ]; then
    while read -r ip port; do
        [ -z "$ip" ] && continue
        whoinfo=$(who 2>/dev/null | grep -F "($ip)" | head -1)
        u=$(echo "$whoinfo" | awk '{print $1}')
        t=$(echo "$whoinfo" | awk '{for(i=2;i<=NF-1;i++) printf "%s ", $i}')
        [ -z "$u" ] && u="?"
        printf '  %-16s  %-6s  %-10s  %s\n' "$ip" "$port" "$u" "$t"
    done <<< "$ACTIVE_LINES"
else
    echo "  (none)"
fi
echo

# ── 2) Last 5 successful logins (distinct IPs) ──
echo "$C_BLD$C_GRN── Last 5 successful logins (distinct IPs) ──$C_OFF"
LAST_LOGINS=$(journalctl_ssh -r _COMM=sshd-session | awk '
    /Accepted/ {
        for (i=1; i<=NF; i++) if ($i=="from") {
            ip=$(i+1); user=$(i-1); date=$1" "$2" "$3
            if (!seen[ip]++) {
                printf "  %-16s  %-12s  %s\n", date, user, ip
                n++; if (n>=5) exit
            }
        }
    }')
if [ -n "$LAST_LOGINS" ]; then
    printf '%s\n' "$LAST_LOGINS"
elif journal_access_may_be_limited; then
    echo "  (journal access unavailable; add user to systemd-journal)"
else
    echo "  (none)"
fi
echo

# ── 3) Failed attempts in lookback window ──
FAIL_SUMMARY=$(journalctl_ssh --since "$FAIL_LOOKBACK" _COMM=sshd-session _COMM=sshd | \
    awk '
    /Failed password for|Invalid user|authentication failure/ {
        ip=""; user=""
        for (i=1;i<=NF;i++) {
            if ($i=="from") ip=$(i+1)
            if ($i=="for") user=$(i+1)
            if (user=="invalid" && $i=="user") user=$(i+1)
        }
        if (ip=="") next
        key=ip"|"user
        count[key]++
        last[key]=$1" "$2" "$3
    }
    END {
        for (k in count) printf "%d|%s|%s\n", count[k], last[k], k
    }' | sort -t"|" -k1 -nr | head -10)

TOTAL_FAILS=0; FAIL_LINES=0
if [ -n "$FAIL_SUMMARY" ]; then
    FAIL_LINES=$(echo "$FAIL_SUMMARY" | wc -l)
    TOTAL_FAILS=$(echo "$FAIL_SUMMARY" | awk -F'|' '{s+=$1} END{print s}')
    echo "$C_BLD$C_RED── ⚠ Failed SSH attempts ($FAIL_LOOKBACK): $TOTAL_FAILS from $FAIL_LINES IP(s) ──$C_OFF"
    echo "$FAIL_SUMMARY" | awk -F'|' '{printf "  %3dx  %-16s  %-20s  user=%s\n", $1, $2, $3, $4}'
elif journal_access_may_be_limited; then
    echo "$C_BLD$C_YEL── Failed SSH attempts ($FAIL_LOOKBACK): unavailable (needs journal access) ──$C_OFF"
else
    echo "$C_BLD$C_YEL── Failed SSH attempts ($FAIL_LOOKBACK): none ──$C_OFF"
fi
echo

# ── Push body ──
if [ "$PUSH_METADATA_LEVEL" = "minimal" ]; then
    BODY=$(printf 'User:   %s%s\nFrom:   %s:%s\nAuth:   %s %s\n\nActive sessions: %s (%s)\nFailed 24h: %s from %s IP(s)\n\nTime:   %s' \
        "$USER" "$SUDO_HINT" \
        "$CIP" "$CPORT" \
        "${AUTH_METHOD:-unknown}" "${KEY_TYPE}" \
        "$ACTIVE_COUNT" "${ACTIVE_IPS:-none}" \
        "$TOTAL_FAILS" "$FAIL_LINES" \
        "$TIMESTAMP")
else
    BODY=$(printf 'User:   %s (uid=%s)%s\nFrom:   %s:%s\nHost:   %s\nAuth:   %s %s\nKey:    %s\nTTY:    %s\nGroups: %s\n\nActive sessions: %s (%s)\nFailed 24h: %s from %s IP(s)\n\nTime:   %s' \
        "$USER" "$UID_NUM" "$SUDO_HINT" \
        "$CIP" "$CPORT" \
        "$CHOST" \
        "${AUTH_METHOD:-unknown}" "${KEY_TYPE}" \
        "${KEY_FP:-n/a}" \
        "$TTY_NAME" \
        "$GROUPS_LIST" \
        "$ACTIVE_COUNT" "${ACTIVE_IPS:-none}" \
        "$TOTAL_FAILS" "$FAIL_LINES" \
        "$TIMESTAMP")
fi

curl -fsS -m 3 \
    -H "Title: SSH login: $USER@$(hostname) from $CIP" \
    -H "Tags: warning,key" \
    -H "Priority: high" \
    ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} \
    -d "$BODY" \
    "$NTFY_URL" >/dev/null 2>&1 &
