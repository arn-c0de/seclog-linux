#!/usr/bin/env bash
# Installer for seclog-linux — per-user, no sudo required, safe to re-run.
#
# Installs into:
#   ~/.local/bin/seclog{,-lib.sh,-login,-monitor,-diagnose,-restart,-update}
#   ~/.config/seclog-linux/config
#   ~/.config/systemd/user/seclog-monitor.service
# and appends a one-line hook to ~/.bashrc.

set -euo pipefail

SRC="$(cd -- "$(dirname -- "$0")" && pwd -P)"
BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/seclog-linux"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/seclog-linux"
SERVICE="seclog-monitor.service"
BASHRC="$HOME/.bashrc"
HOOK_MARKER="# seclog-linux: SSH login banner + push notification"

# Everything that lands in ~/.local/bin, as "name:mode".
COMMANDS=(
    "seclog:0755"
    "seclog-login:0755"
    "seclog-monitor:0755"
    "seclog-diagnose:0755"
    "seclog-restart:0755"
    "seclog-update:0755"
    "seclog-lib.sh:0644"
)

# Files and units from releases before the seclog-* rename.
LEGACY_COMMANDS=(ssh-login-notify.sh ssh-failed-monitor.sh)
LEGACY_SERVICE="seclog-linux-fail-monitor.service"

step() { printf '  %s %s\n' "$1" "${*:2}"; }
ok()   { step "✓" "$@"; }
note() { step "⚠" "$@"; }

echo "── seclog-linux installer ──"

# ── Directories ──────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$CFG_DIR" "$UNIT_DIR" "$CACHE_DIR"

# ── Migrate away from the pre-rename layout ──────────────────────────────
if [[ -f $UNIT_DIR/$LEGACY_SERVICE ]]; then
    systemctl --user disable --now "$LEGACY_SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$LEGACY_SERVICE"
    ok "removed legacy unit $LEGACY_SERVICE"
fi
for legacy in "${LEGACY_COMMANDS[@]}"; do
    [[ -e $BIN_DIR/$legacy ]] && rm -f "$BIN_DIR/$legacy" && ok "removed legacy $legacy"
done

# ── Commands ─────────────────────────────────────────────────────────────
for entry in "${COMMANDS[@]}"; do
    install -m "${entry##*:}" "$SRC/bin/${entry%%:*}" "$BIN_DIR/${entry%%:*}"
done
ok "installed ${#COMMANDS[@]} files to $BIN_DIR"

# ── Config (never overwritten) ───────────────────────────────────────────
if [[ -f $CFG_DIR/config ]]; then
    ok "config kept at $CFG_DIR/config"
else
    install -m 0600 "$SRC/config/config.example" "$CFG_DIR/config"
    ok "wrote $CFG_DIR/config — EDIT IT and set NTFY_URL"
fi

# ── systemd user unit ────────────────────────────────────────────────────
install -m 0644 "$SRC/systemd/$SERVICE" "$UNIT_DIR/$SERVICE"
ok "installed $UNIT_DIR/$SERVICE"

# ── .bashrc hook (idempotent, replaces any earlier seclog block) ─────────
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
    cat "$tmp" >"$BASHRC"
    rm -f "$tmp"
fi
{
    echo ""
    echo "$HOOK_MARKER"
    # shellcheck disable=SC2016  # must stay literal in .bashrc
    echo '[ -n "$SSH_CONNECTION" ] && [ -x "$HOME/.local/bin/seclog-login" ] && "$HOME/.local/bin/seclog-login"'
} >>"$BASHRC"
ok ".bashrc hook installed"

# ── Environment checks ───────────────────────────────────────────────────
case ":$PATH:" in
    *":$BIN_DIR:"*) ok "$BIN_DIR is in PATH" ;;
    *) note "$BIN_DIR is NOT in PATH — add to ~/.profile:"
       # shellcheck disable=SC2016  # literal advice for the user to copy
       printf '      export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac

if (( EUID != 0 )) && ! id -nG 2>/dev/null | grep -qw systemd-journal; then
    note "$USER is not in the systemd-journal group — SSH log reads may come back empty"
    printf '      sudo usermod -aG systemd-journal %s   (then log out and back in)\n' "$USER"
fi

# ── Service ──────────────────────────────────────────────────────────────
systemctl --user daemon-reload
if systemctl --user enable --now "$SERVICE" >/dev/null 2>&1; then
    ok "$SERVICE is $(systemctl --user is-active "$SERVICE")"
else
    printf '  ✗ %s failed to start — check: systemctl --user status %s\n' "$SERVICE" "$SERVICE" >&2
    exit 1
fi

# ── Verify the ntfy target, if it is configured ──────────────────────────
# shellcheck source=bin/seclog-lib.sh
. "$BIN_DIR/seclog-lib.sh"
seclog_load_config
if seclog_ntfy_configured; then
    if seclog_push "seclog-linux installed on $(hostname)" "white_check_mark" "low" \
        "Installer test push at $(date '+%Y-%m-%d %H:%M:%S %Z')"; then
        ok "ntfy reachable — test push sent"
    else
        note "ntfy unreachable or auth rejected: $NTFY_URL"
        printf '      Check NTFY_URL and NTFY_TOKEN in %s\n' "$CFG_DIR/config"
    fi
fi

cat <<EOT

── Done ──
1. Edit your config:   $CFG_DIR/config      (NTFY_URL, optional NTFY_TOKEN)
2. Check the report:   seclog
3. Verify the setup:   seclog-diagnose
4. Keep the monitor running after logout:
     sudo loginctl enable-linger $USER
5. Update later:       seclog-update
EOT
