#!/usr/bin/env bats
# The config file is parsed, never executed.

load test_helper

setup() { load_lib; }

@test "plain, double-quoted and single-quoted values are read" {
    write_config <<'EOF'
NTFY_TIMEOUT=9
NTFY_URL="https://ntfy.example.com/topic"
FAIL_LOOKBACK='2 hours ago'
EOF
    seclog_load_config
    [ "$NTFY_TIMEOUT" = 9 ]
    [ "$NTFY_URL" = "https://ntfy.example.com/topic" ]
    [ "$FAIL_LOOKBACK" = "2 hours ago" ]
}

@test "comments, blank lines, whitespace and export prefixes are tolerated" {
    write_config <<'EOF'
# leading comment

   export NTFY_TIMEOUT = 7   # trailing comment
NTFY_URL="https://ntfy.example.com/t"  # comment after a quoted value
EOF
    seclog_load_config
    [ "$NTFY_TIMEOUT" = 7 ]
    [ "$NTFY_URL" = "https://ntfy.example.com/t" ]
}

@test "command substitution and variables are taken literally, never run" {
    marker="$BATS_TEST_TMPDIR/executed"
    write_config <<EOF
NTFY_URL="\$(touch $marker)"
NTFY_TOKEN=\`touch $marker\`
FAIL_LOOKBACK="\$HOME"
EOF
    run bash -c ". '$REPO_ROOT/bin/seclog-lib.sh'; SECLOG_LOGGER=''; seclog_load_config; printf '%s|%s|%s' \"\$NTFY_URL\" \"\$NTFY_TOKEN\" \"\$FAIL_LOOKBACK\""
    [ ! -e "$marker" ]
    [[ $output == *"\$(touch $marker)|\`touch $marker\`|\$HOME" ]]
    [[ $output == *"taken literally"* ]]
}

@test "unknown keys are ignored with a warning" {
    write_config <<'EOF'
PATH=/evil
BASH_ENV=/evil
TOTALLY_UNKNOWN=1
NTFY_TIMEOUT=3
EOF
    run bash -c ". '$REPO_ROOT/bin/seclog-lib.sh'; SECLOG_LOGGER=''; seclog_load_config; echo \"timeout=\$NTFY_TIMEOUT\"; echo \"path=\$PATH\"; echo \"unknown=\${TOTALLY_UNKNOWN:-unset}\""
    [ "$status" -eq 0 ]
    [[ $output == *"unknown setting PATH ignored"* ]]
    [[ $output == *"unknown setting BASH_ENV ignored"* ]]
    [[ $output == *"timeout=3"* ]]
    [[ $output != *"path=/evil"* ]]
    [[ $output == *"unknown=unset"* ]]
}

@test "malformed lines are skipped and reported" {
    write_config <<'EOF'
this is not a setting
NTFY_TIMEOUT="unbalanced
FAIL_RATELIMIT_WINDOW=42
EOF
    run bash -c ". '$REPO_ROOT/bin/seclog-lib.sh'; SECLOG_LOGGER=''; seclog_load_config; echo \"w=\$FAIL_RATELIMIT_WINDOW t=\$NTFY_TIMEOUT\""
    [[ $output == *"config:1: not a KEY=value line"* ]]
    [[ $output == *"config:2: unbalanced quotes"* ]]
    [[ $output == *"w=42 t=5"* ]]
}

@test "numeric settings fall back to their defaults when not a plain integer" {
    write_config <<'EOF'
NTFY_TIMEOUT=a[$(reboot)]
FAIL_RATELIMIT_WINDOW=-1
LOGIN_DEDUP_WINDOW=
EOF
    seclog_load_config 2>/dev/null
    [ "$NTFY_TIMEOUT" = 5 ]
    [ "$FAIL_RATELIMIT_WINDOW" = 300 ]
    [ "$LOGIN_DEDUP_WINDOW" = 60 ]
}

@test "defaults are applied when the config is missing" {
    export SECLOG_CONFIG="$BATS_TEST_TMPDIR/does-not-exist"
    seclog_load_config
    [ "$LOGIN_PUSH_SOURCE" = monitor ]
    [ "$PUSH_METADATA_LEVEL" = minimal ]
    [ "$UPDATE_CHANNEL" = release ]
    [ "$REPLAY_MAX_AGE" = 3600 ]
    [ "$JOURNAL_TIMEOUT" = 2 ]
}

@test "a group-writable config is refused" {
    write_config <<'EOF'
NTFY_TIMEOUT=1
EOF
    chmod 660 "$SECLOG_CONFIG"
    run bash -c ". '$REPO_ROOT/bin/seclog-lib.sh'; SECLOG_LOGGER=''; seclog_load_config"
    [ "$status" -eq 1 ]
    [[ $output == *"refusing to read"* ]]
}

@test "a config in a world-writable directory is refused" {
    write_config <<'EOF'
NTFY_TIMEOUT=1
EOF
    chmod 777 "$(dirname "$SECLOG_CONFIG")"
    run bash -c ". '$REPO_ROOT/bin/seclog-lib.sh'; SECLOG_LOGGER=''; seclog_load_config"
    [ "$status" -eq 1 ]
    [[ $output == *"writable by group/others"* ]]
}

@test "the shipped config.example parses without warnings" {
    write_config < "$REPO_ROOT/config/config.example"
    run bash -c ". '$REPO_ROOT/bin/seclog-lib.sh'; SECLOG_LOGGER=''; seclog_load_config; echo ok"
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "every key in config.example is on the whitelist" {
    while IFS= read -r key; do
        seclog_config_key_allowed "$key" || { echo "not whitelisted: $key"; return 1; }
    done < <(grep -oE '^#?[A-Z_]+=' "$REPO_ROOT/config/config.example" | tr -d '#=' | sort -u)
}
