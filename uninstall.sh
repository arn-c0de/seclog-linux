#!/bin/bash
# Uninstall seclog-linux. Removes scripts, systemd unit, and .bashrc hook.
# Does NOT remove your config (edit or delete manually if you want).

set -e

BIN="$HOME/.local/bin"
SYSD_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now seclog-linux-fail-monitor.service >/dev/null 2>&1 || true
rm -f "$SYSD_DIR/seclog-linux-fail-monitor.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true

rm -f "$BIN/ssh-login-notify.sh" "$BIN/ssh-failed-monitor.sh" "$BIN/seclog" "$BIN/seclog-update" "$BIN/seclog-restart"

# Remove .bashrc hook
if grep -q "seclog-linux:" "$HOME/.bashrc" 2>/dev/null; then
    tmp="$(mktemp)"
    awk '/# seclog-linux:/{skip=2} skip>0{skip--; next} {print}' "$HOME/.bashrc" > "$tmp"
    mv "$tmp" "$HOME/.bashrc"
    echo "✓ .bashrc hook removed"
fi

echo "✓ seclog-linux uninstalled."
echo "  Config kept at: $HOME/.config/seclog-linux/  (remove manually if unwanted)"
echo "  State cache:    $HOME/.cache/ssh-fail/         (remove manually if unwanted)"
