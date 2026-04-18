#!/bin/bash
# Tails journalctl for failed SSH login events and pushes them to ntfy.
# Rate-limit: max 1 push per source-IP per WINDOW seconds (default 5 min)
# to avoid flooding during brute-force attempts.

CONFIG="${SSH_NOTIFY_CONFIG:-$HOME/.config/seclog-linux/config}"
[ -f "$CONFIG" ] && . "$CONFIG"

: "${NTFY_URL:?NTFY_URL not set — configure $CONFIG}"
STATE_DIR="${STATE_DIR:-$HOME/.cache/ssh-fail}"
WINDOW="${FAIL_RATELIMIT_WINDOW:-300}"
mkdir -p "$STATE_DIR"

journalctl -f -n 0 --no-pager _COMM=sshd-session _COMM=sshd 2>/dev/null | \
while IFS= read -r line; do
    case "$line" in
        *"Failed password for "*|*"Invalid user "*|*"authentication failure"*|*"Disconnected from authenticating user"*)
            user=$(echo "$line" | sed -E 's/.*for (invalid user )?([^ ]+) from.*/\2/;t;s/.*//')
            ip=$(echo "$line" | grep -oE 'from [0-9.]+' | awk '{print $2}' | head -1)
            port=$(echo "$line" | grep -oE 'port [0-9]+' | awk '{print $2}' | head -1)
            [ -z "$user" ] && user="?"
            [ -z "$ip" ] && continue

            reason=$(echo "$line" | grep -oE 'Failed password|Invalid user|authentication failure|Disconnected' | head -1)

            now=$(date +%s)
            state="$STATE_DIR/$ip"
            last=0; count=1
            [ -f "$state" ] && read -r last count < "$state"
            count=$((count + 1))
            if [ $((now - last)) -lt $WINDOW ]; then
                echo "$last $count" > "$state"
                continue
            fi
            echo "$now 0" > "$state"

            title="SSH FAILED: $user from $ip"
            body="Reason: $reason
IP:     $ip:${port:-?}
User:   $user
Attempts since last push: $count
Time:   $(date '+%Y-%m-%d %H:%M:%S %Z')"

            curl -fsS -m 3 \
                -H "Title: $title" \
                -H "Tags: skull,warning" \
                -H "Priority: high" \
                ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} \
                -d "$body" \
                "$NTFY_URL" >/dev/null 2>&1
            ;;
    esac
done
