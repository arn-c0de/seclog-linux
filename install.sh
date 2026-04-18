#!/bin/bash
# Installer for seclog-linux — per-user, no sudo required.
#
# Installs:
#   ~/.local/bin/ssh-login-notify.sh   (sourced from .bashrc on SSH login)
#   ~/.local/bin/ssh-failed-monitor.sh (systemd user service)
#   ~/.local/bin/seclog                (interactive CLI)
#   ~/.local/bin/seclog-update         (git update helper)
#   ~/.local/bin/seclog-restart        (service restart helper)
#   ~/.config/seclog-linux/config    (your NTFY_URL + token)
#   ~/.config/systemd/user/seclog-linux-fail-monitor.service
#
# Idempotent — safe to re-run.

set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
CFG_DIR="$HOME/.config/seclog-linux"
SYSD_DIR="$HOME/.config/systemd/user"

echo "── seclog-linux installer ──"

mkdir -p "$BIN" "$CFG_DIR" "$SYSD_DIR" "$HOME/.cache/ssh-fail"

install -m 0755 "$SRC/bin/ssh-login-notify.sh"    "$BIN/ssh-login-notify.sh"
install -m 0755 "$SRC/bin/ssh-failed-monitor.sh"  "$BIN/ssh-failed-monitor.sh"
install -m 0755 "$SRC/bin/seclog"                 "$BIN/seclog"
install -m 0755 "$SRC/bin/seclog-update"          "$BIN/seclog-update"
install -m 0755 "$SRC/bin/seclog-restart"         "$BIN/seclog-restart"
echo "✓ scripts installed to $BIN"

# Config: copy example if user has no config yet
if [ ! -f "$CFG_DIR/config" ]; then
    install -m 0600 "$SRC/config/config.example" "$CFG_DIR/config"
    echo "✓ wrote default config to $CFG_DIR/config — EDIT IT (NTFY_URL, token)"
else
    echo "✓ config already exists at $CFG_DIR/config (not overwritten)"
fi

# systemd user unit
UNIT_SRC="$SRC/systemd/seclog-linux-fail-monitor.service"
UNIT_DST="$SYSD_DIR/seclog-linux-fail-monitor.service"
# Rewrite to use ~/.local/bin (template %h works) — use literal path for user unit
sed "s|%h/.local/bin/ssh-failed-monitor.sh|$HOME/.local/bin/ssh-failed-monitor.sh|; \
     s|%h/.cache/ssh-fail|$HOME/.cache/ssh-fail|; \
     s|%h/.config/seclog-linux|$HOME/.config/seclog-linux|; \
     /^User=/d" "$UNIT_SRC" > "$UNIT_DST"
echo "✓ systemd user unit at $UNIT_DST"

# Wire .bashrc (idempotent)
MARKER="# seclog-linux: show SSH security status + push on login"
if ! grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ""
        echo "$MARKER"
        echo '[ -n "$SSH_CONNECTION" ] && [ -f "$HOME/.local/bin/ssh-login-notify.sh" ] && . "$HOME/.local/bin/ssh-login-notify.sh"'
    } >> "$HOME/.bashrc"
    echo "✓ .bashrc hooked"
else
    echo "✓ .bashrc already hooked"
fi

# PATH check
case ":$PATH:" in
    *":$HOME/.local/bin:"*) echo "✓ $HOME/.local/bin is in PATH" ;;
    *) echo "⚠ $HOME/.local/bin is NOT in PATH — add this to .profile or .bashrc:"
       echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

if [ "$(id -u)" -ne 0 ] && ! id -nG 2>/dev/null | grep -qw systemd-journal; then
    echo "⚠ $USER is not in group systemd-journal — SSH log reads may fail on this distro"
    echo "    If login history or failed-login monitoring stay empty, run once:"
    echo "    sudo usermod -aG systemd-journal \$USER"
    echo "    Then log out and back in."
fi

# Enable & start the failed-monitor service
systemctl --user daemon-reload
systemctl --user enable --now seclog-linux-fail-monitor.service >/dev/null 2>&1 || true
if systemctl --user is-active seclog-linux-fail-monitor.service >/dev/null 2>&1; then
    echo "✓ seclog-linux-fail-monitor.service running"
else
    echo "⚠ seclog-linux-fail-monitor.service not running — check: systemctl --user status seclog-linux-fail-monitor"
fi

cat << EOF

── Done. Next steps ──
1. Edit your config:  $CFG_DIR/config
   Set NTFY_URL and (optionally) NTFY_TOKEN.

2. Update later from a git checkout with:
     SECLOG_REPO_DIR="$SRC" seclog-update

3. For persistent fail-monitor (survives logout), run ONCE as root:
     sudo loginctl enable-linger \$USER

4. Test with:  seclog
   Re-login via SSH to see the banner + receive a push.

EOF
