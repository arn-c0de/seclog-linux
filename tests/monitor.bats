#!/usr/bin/env bats
# seclog-monitor end to end against a mocked journalctl and curl: rate limit,
# dedup, cursor persistence, replay cut-off.

load test_helper

setup() {
    export STATE="$BATS_TEST_TMPDIR/state"
    export SECLOG_STATE_DIR="$STATE"
    export FEED="$BATS_TEST_TMPDIR/feed"
    export PUSHES="$BATS_TEST_TMPDIR/pushes"
    export JOURNALCTL_ARGS="$BATS_TEST_TMPDIR/journalctl-args"
    mkdir -p "$STATE"
    : > "$PUSHES"
    write_config <<'EOF'
NTFY_URL="https://ntfy.example.com/topic"
FAIL_RATELIMIT_WINDOW=300
LOGIN_DEDUP_WINDOW=60
REPLAY_MAX_AGE=3600
EOF
    mock journalctl <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JOURNALCTL_ARGS"
case " $* " in
    *" --system "*) exit 0 ;;
    *" --after-cursor=bad-cursor "*) echo "Failed to seek to cursor" >&2; exit 1 ;;
    *" -f "*) cat "$FEED" ;;            # emit the feed, then end the stream
    *) exit 0 ;;
esac
EOF
    mock curl <<'EOF'
#!/usr/bin/env bash
title=""
for ((i = 1; i <= $#; i++)); do
    [[ ${!i} == --config ]] && { j=$((i + 1)); title="$(grep '^header = "Title: ' "${!j}" | sed 's/^header = "Title: //; s/"$//')"; }
done
body="$(cat)"
printf '%s || %s\n' "$title" "${body//$'\n'/ | }" >> "$PUSHES"
EOF
    export JOURNAL_LOG="$BATS_TEST_TMPDIR/journal-log"
    : > "$JOURNAL_LOG"
    mock logger <<'EOF'
#!/usr/bin/env bash
# logger -t tag -p prio -- message
printf '%s\n' "${@: -1}" >> "$JOURNAL_LOG"
EOF
}

# The monitor exits 1 when the stream ends; that is the expected outcome here.
run_monitor() {
    run bash "$REPO_ROOT/bin/seclog-monitor"
    [ "$status" -eq 1 ]
}

now_us() { printf '%s000000' "$EPOCHSECONDS"; }

@test "one push per source IP per window, suppressed attempts are counted" {
    ts="$(now_us)"
    {
        for i in 1 2 3 4 5; do jrec "Failed password for root from 203.0.113.9 port $i ssh2" "$ts" "c$i"; done
        jrec 'Invalid user admin from 198.51.100.7 port 9' "$ts" c9
    } > "$FEED"
    run_monitor
    [ "$(wc -l < "$PUSHES")" -eq 2 ]
    grep -q '^SSH FAILED: root from 203.0.113.9 ||' "$PUSHES"
    grep -q '^SSH FAILED: admin from 198.51.100.7 ||' "$PUSHES"
    # 4 attempts were swallowed by the window and wait in the state file.
    read -r _ suppressed < "$STATE/fail-203.0.113.9"
    [ "$suppressed" -eq 4 ]
}

@test "the suppressed count is reported in the next push after the window" {
    printf '%s 4\n' "$(( EPOCHSECONDS - 400 ))" > "$STATE/fail-203.0.113.9"
    jrec 'Failed password for root from 203.0.113.9 port 1 ssh2' "$(now_us)" c1 > "$FEED"
    run_monitor
    grep -q 'Suppressed since last push: 4' "$PUSHES"
}

@test "successful logins are pushed once per user and address within the dedup window" {
    ts="$(now_us)"
    {
        jrec 'Accepted publickey for alice from 10.0.0.5 port 1 ssh2: ED25519 SHA256:a' "$ts" c1
        jrec 'Accepted publickey for alice from 10.0.0.5 port 2 ssh2: ED25519 SHA256:a' "$ts" c2
        jrec 'Accepted password for bob from 10.0.0.5 port 3 ssh2' "$ts" c3
    } > "$FEED"
    run_monitor
    [ "$(grep -c '^SSH login' "$PUSHES")" -eq 2 ]
    grep -q '^SSH login: alice from 10.0.0.5 || User:   alice | From:   10.0.0.5:1 | Auth:   publickey | Origin: \[LAN\]' "$PUSHES"
    grep -q '^SSH login: bob from 10.0.0.5' "$PUSHES"
}

@test "LOGIN_PUSH_SOURCE=banner silences login pushes from the monitor" {
    write_config <<'EOF'
NTFY_URL="https://ntfy.example.com/topic"
LOGIN_PUSH_SOURCE="banner"
EOF
    jrec 'Accepted publickey for alice from 10.0.0.5 port 1 ssh2' "$(now_us)" c1 > "$FEED"
    run_monitor
    [ ! -s "$PUSHES" ]
}

@test "the journal cursor of the last handled event is persisted" {
    ts="$(now_us)"
    {
        jrec 'Failed password for root from 203.0.113.9 port 1 ssh2' "$ts" 'c=first'
        jrec 'Failed password for root from 203.0.113.9 port 2 ssh2' "$ts" 'c=last'
    } > "$FEED"
    run_monitor
    [ "$(cat "$STATE/journal.cursor")" = "c=last" ]
}

@test "a saved cursor is validated and then used to resume" {
    echo 'c=saved' > "$STATE/journal.cursor"
    : > "$FEED"
    run_monitor
    grep -q -- '-q -n 0 --after-cursor=c=saved' "$JOURNALCTL_ARGS"
    grep -q -- '-f --no-pager -o json --after-cursor=c=saved' "$JOURNALCTL_ARGS"
}

@test "an unusable saved cursor is discarded and the monitor starts from now" {
    echo 'bad-cursor' > "$STATE/journal.cursor"
    : > "$FEED"
    run_monitor
    [[ $output == *"saved journal cursor is unusable"* ]]
    grep -q -- '-f --no-pager -o json -n 0' "$JOURNALCTL_ARGS"
    [ ! -e "$STATE/journal.cursor" ]
}

@test "events older than REPLAY_MAX_AGE are counted but not pushed" {
    old="$(( EPOCHSECONDS - 7200 ))000000"
    {
        jrec 'Failed password for root from 203.0.113.9 port 1 ssh2' "$old" c1
        jrec 'Accepted publickey for alice from 10.0.0.5 port 1 ssh2' "$old" c2
        jrec 'Failed password for root from 203.0.113.9 port 2 ssh2' "$(now_us)" c3
    } > "$FEED"
    run_monitor
    [ "$(wc -l < "$PUSHES")" -eq 1 ]
    grep -q 'Suppressed since last push: 1' "$PUSHES"
    grep -q 'skipped 2 event(s) older than 3600s' "$JOURNAL_LOG"
    [ "$(cat "$STATE/journal.cursor")" = "c3" ]
}

@test "the push carries the event time, not the processing time" {
    ts=$(( EPOCHSECONDS - 120 ))
    jrec 'Failed password for root from 203.0.113.9 port 1 ssh2' "${ts}000000" c1 > "$FEED"
    run_monitor
    grep -qF "Time:   $(printf '%(%Y-%m-%d %H:%M:%S %Z)T' "$ts")" "$PUSHES"
}

@test "a placeholder NTFY_URL exits with EX_CONFIG so systemd does not restart-loop" {
    write_config <<'EOF'
NTFY_URL="http://YOUR_NTFY_HOST:2586/YOUR_TOPIC"
EOF
    run bash "$REPO_ROOT/bin/seclog-monitor"
    [ "$status" -eq 78 ]
}
