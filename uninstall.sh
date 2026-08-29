#!/usr/bin/env bash
# Uninstall seclog-linux: stops the service, removes the installed commands and
# the .bashrc hook. Config and cached state are kept — remove them by hand if
# you want them gone (the paths are printed at the end).

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/seclog-linux"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/seclog-linux"
BASHRC="$HOME/.bashrc"

SERVICES=(seclog-monitor.service seclog-linux-fail-monitor.service)
COMMANDS=(
    seclog seclog-login seclog-monitor seclog-diagnose seclog-restart
    seclog-update seclog-lib.sh
    ssh-login-notify.sh ssh-failed-monitor.sh   # pre-rename releases
)

for service in "${SERVICES[@]}"; do
    systemctl --user disable --now "$service" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$service"
done
systemctl --user daemon-reload >/dev/null 2>&1 || true
echo "✓ service stopped and unit removed"

for command in "${COMMANDS[@]}"; do
    rm -f "$BIN_DIR/$command"
done
echo "✓ commands removed from $BIN_DIR"

if [[ -f $BASHRC ]] && grep -q '# seclog-linux:' "$BASHRC"; then
    tmp="$(mktemp)"
    awk '
        /# seclog-linux:/ { skip = 2 }
        skip > 0          { skip--; next }
                          { line[++n] = $0 }
        END {
            while (n > 0 && line[n] ~ /^[[:space:]]*$/) n--
            for (i = 1; i <= n; i++) print line[i]
        }' "$BASHRC" >"$tmp"
    cat "$tmp" >"$BASHRC"          # truncate in place, keeping mode and owner
    rm -f "$tmp"
    echo "✓ .bashrc hook removed"
fi

cat <<EOT

✓ seclog-linux uninstalled.
  Config kept at:  $CFG_DIR
  State kept at:   $CACHE_DIR
  Old state dir:   $HOME/.cache/ssh-fail   (pre-rename releases)
EOT
