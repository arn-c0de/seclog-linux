#!/usr/bin/env bash
# Installer for seclog-linux — per-user, no sudo required, safe to re-run.
#
# Installs into:
#   ~/.local/bin/seclog{,-lib.sh,-login,-monitor,-diagnose,-restart,-update}
#   ~/.local/share/bash-completion/completions/seclog{,-update,-diagnose}
#   ~/.config/seclog-linux/config
#   ~/.config/systemd/user/seclog-monitor.service
# and appends a one-line hook to ~/.bashrc.

set -euo pipefail

SRC="$(cd -- "$(dirname -- "$0")" && pwd -P)"
BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/seclog-linux"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/seclog-linux"
COMPLETION_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
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

# Commands that get the shared completion file installed under their name.
COMPLETED=(seclog seclog-update seclog-diagnose)

step() { printf '  %s %s\n' "$1" "${*:2}"; }
ok()   { step "✓" "$@"; }
note() { step "⚠" "$@"; }

echo "── seclog-linux installer ──"

if (( BASH_VERSINFO[0] < 5 )); then
    printf '  ✗ bash %s is too old — seclog needs bash 5 or newer\n' "$BASH_VERSION" >&2
    exit 1
fi

# ── Directories ──────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$CFG_DIR" "$UNIT_DIR" "$CACHE_DIR" "$COMPLETION_DIR"

# ── Commands ─────────────────────────────────────────────────────────────
for entry in "${COMMANDS[@]}"; do
    install -m "${entry##*:}" "$SRC/bin/${entry%%:*}" "$BIN_DIR/${entry%%:*}"
done
ok "installed ${#COMMANDS[@]} files to $BIN_DIR"

for name in "${COMPLETED[@]}"; do
    install -m 0644 "$SRC/completions/seclog.bash" "$COMPLETION_DIR/$name"
done
ok "installed bash completion to $COMPLETION_DIR"

# ── Config (never overwritten) ───────────────────────────────────────────
chmod 0700 "$CFG_DIR"
if [[ -f $CFG_DIR/config ]]; then
    ok "config kept at $CFG_DIR/config"
    # The config holds the ntfy token and the update trust settings, so write
    # access to it steers what code this user ends up running. seclog refuses
    # to start on a loose one; tighten it here instead of failing later.
    mode="$(stat -Lc '%a' "$CFG_DIR/config" 2>/dev/null || echo 600)"
    if (( 8#$mode & 8#077 )); then
        chmod 0600 "$CFG_DIR/config"
        note "tightened $CFG_DIR/config from mode $mode to 600"
    fi
else
    install -m 0600 "$SRC/config/config.example" "$CFG_DIR/config"
    ok "wrote $CFG_DIR/config — EDIT IT and set NTFY_URL"
fi

# From here on the freshly installed library does the checking. Since 1.0.3 the
# config is parsed rather than sourced; an older config that relied on shell
# expansion is reported line by line right here.
# shellcheck source=bin/seclog-lib.sh
. "$BIN_DIR/seclog-lib.sh"
seclog_load_config

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
# One line, because the remover above skips exactly one line after the marker.
#   $-                    only interactive shells: bash also reads .bashrc for
#                         `ssh host cmd`, and a banner inside an scp or rsync
#                         stream corrupts the transfer
#   SECLOG_BANNER_SHOWN   once per SSH session, not for every tmux pane or
#                         subshell that inherits SSH_CONNECTION
{
    echo ""
    echo "$HOOK_MARKER"
    # shellcheck disable=SC2016  # must stay literal in .bashrc
    echo 'if [ -n "$SSH_CONNECTION" ] && [ -z "$SECLOG_BANNER_SHOWN" ] && [ -x "$HOME/.local/bin/seclog-login" ]; then case $- in *i*) export SECLOG_BANNER_SHOWN=1; "$HOME/.local/bin/seclog-login";; esac; fi'
} >>"$BASHRC"
ok ".bashrc hook installed"

# ── Environment checks ───────────────────────────────────────────────────
case ":$PATH:" in
    *":$BIN_DIR:"*) ok "$BIN_DIR is in PATH" ;;
    *) note "$BIN_DIR is NOT in PATH — add to ~/.profile:"
       # shellcheck disable=SC2016  # literal advice for the user to copy
       printf '      export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac

if seclog_journal_restricted; then
    note "$USER cannot read the system journal — SSH log reads come back empty and the monitor sees nothing"
    printf '      sudo usermod -aG systemd-journal %s   (then log out and back in)\n' "$USER"
fi

# ── Service ──────────────────────────────────────────────────────────────
if ! systemctl --user daemon-reload 2>/dev/null; then
    note "no systemd user session reachable (is XDG_RUNTIME_DIR set?) — the monitor was not started"
    printf '      log in through a regular session, or run: sudo loginctl enable-linger %s\n' "$USER"
    printf '      then: systemctl --user enable --now %s\n' "$SERVICE"
elif systemctl --user enable --now "$SERVICE" >/dev/null 2>&1; then
    ok "$SERVICE is $(systemctl --user is-active "$SERVICE")"
else
    printf '  ✗ %s failed to start — check: systemctl --user status %s\n' "$SERVICE" "$SERVICE" >&2
    exit 1
fi

# ── Verify the ntfy target, if it is configured ──────────────────────────
if seclog_ntfy_configured; then
    if seclog_push "seclog-linux installed on $HOSTNAME" "white_check_mark" "low" \
        "Installer test push at $(seclog_now)"; then
        ok "ntfy reachable — test push sent"
    else
        note "ntfy unreachable or auth rejected: $(seclog_mask_url "$NTFY_URL")"
        printf '      Check NTFY_URL and NTFY_TOKEN in %s\n' "$CFG_DIR/config"
    fi
fi

cat <<EOT

── Done ──
1. Edit your config:   $CFG_DIR/config      (NTFY_URL, optional NTFY_TOKEN)
2. Check the report:   seclog
3. Verify the setup:   seclog diagnose
4. Keep the monitor running after logout:
     sudo loginctl enable-linger $USER
5. Update later:       seclog update
EOT
