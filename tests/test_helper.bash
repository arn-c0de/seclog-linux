# Shared setup for the bats suite. Run with:  bats tests/
#
# Nothing here touches the real config, journal or network. Commands that the
# library shells out to (mmdblookup, geoiplookup, journalctl, ss, who) are
# replaced by mocks placed first in PATH where a test needs them.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

load_lib() {
    export SECLOG_CONFIG="${SECLOG_CONFIG:-$BATS_TEST_TMPDIR/no-such-config}"
    export SECLOG_STATE_DIR="$BATS_TEST_TMPDIR/state"
    # shellcheck source=../bin/seclog-lib.sh
    . "$REPO_ROOT/bin/seclog-lib.sh"
    # Keep test output out of the real journal.
    SECLOG_LOGGER=""
}

# Build one journalctl -o json record. jrec <message> [epoch-microseconds] [cursor]
jrec() {
    local msg="$1" ts="${2:-1725465312123456}" cur="${3:-s=1;i=1;b=2;m=3;t=4;x=5}"
    msg="${msg//\\/\\\\}"
    msg="${msg//\"/\\\"}"
    printf '{"__CURSOR":"%s","__REALTIME_TIMESTAMP":"%s","_COMM":"sshd-session","SYSLOG_IDENTIFIER":"sshd","MESSAGE":"%s"}\n' \
        "$cur" "$ts" "$msg"
}

# Put a mock executable first in PATH. mock <name> <<'EOF' ... EOF
mock() {
    local dir="$BATS_TEST_TMPDIR/mockbin"
    mkdir -p "$dir"
    cat >"$dir/$1"
    chmod +x "$dir/$1"
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) export PATH="$dir:$PATH" ;;
    esac
}

# Write a config file with safe permissions and point the library at it.
write_config() {
    local dir="$BATS_TEST_TMPDIR/cfg"
    mkdir -p "$dir"
    chmod 700 "$dir"
    cat >"$dir/config"
    chmod 600 "$dir/config"
    export SECLOG_CONFIG="$dir/config"
}
