#!/usr/bin/env bats
# The text and JSON report, built from mocked ss / who / journalctl output.

load test_helper

setup() {
    load_lib
    export FIXTURES="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$FIXTURES"

    # Two established sockets: an inbound ssh session and an outbound https.
    cat >"$FIXTURES/ss-tnp" <<'EOF'
State  Recv-Q Send-Q Local Address:Port    Peer Address:Port  Process
ESTAB  0      0      192.168.1.20:22       192.168.1.100:51000 users:(("sshd-session",pid=1,fd=4))
ESTAB  0      0      192.168.1.20:40000    203.0.113.55:443   users:(("curl",pid=2,fd=3))
ESTAB  0      0      192.168.1.20:40001    203.0.113.55:443   users:(("curl",pid=3,fd=3))
EOF
    cat >"$FIXTURES/ss-ltn" <<'EOF'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0      128    0.0.0.0:22         0.0.0.0:*
EOF
    {
        jrec 'Accepted publickey for alice from 192.168.1.100 port 51000 ssh2: ED25519 SHA256:x' 1725465312000000
        jrec 'Failed password for root from 203.0.113.9 port 1 ssh2' 1725465000000000
        jrec 'Failed password for root from 203.0.113.9 port 2 ssh2' 1725465100000000
        jrec 'Invalid user admin from 198.51.100.7 port 3' 1725465200000000
        jrec 'Accepted password for bob from 203.0.113.55 port 4 ssh2' 1725465250000000
    } >"$FIXTURES/journal"

    mock ss <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *-tnp*) cat "$FIXTURES/ss-tnp" ;;
    *-ltn*) cat "$FIXTURES/ss-ltn" ;;
esac
EOF
    mock who <<'EOF'
#!/usr/bin/env bash
echo "alice    pts/0        2026-09-04 17:00 (192.168.1.100)"
EOF
    mock journalctl <<'EOF'
#!/usr/bin/env bash
# The library always asks for -o json; -r reverses the order like the real thing.
case " $* " in
    *" --system "*) exit 0 ;;
    *" -r "*) tac "$FIXTURES/journal" ;;
    *)        cat "$FIXTURES/journal" ;;
esac
EOF
    seclog_load_config
    C_RED='' C_GRN='' C_YEL='' C_BLU='' C_BLD='' C_OFF=''
}

@test "connections are grouped, directed and counted" {
    seclog_collect_connections
    [ "$SECLOG_CONN_TOTAL" -eq 3 ]
    [[ $SECLOG_CONN_ROWS == *$'IN\t192.168.1.100\t22\tsshd-session\t1'* ]]
    [[ $SECLOG_CONN_ROWS == *$'OUT\t203.0.113.55\t443\tcurl\t2'* ]]
    [ "$SECLOG_CONN_PEERS" = 192.168.1.100 ]
}

@test "logins are one per distinct IP, newest first" {
    seclog_collect_logins 5
    [ "$(wc -l <<<"$SECLOG_LOGIN_ROWS")" -eq 2 ]
    [ "$(head -1 <<<"$SECLOG_LOGIN_ROWS")" = "1725465250|bob|203.0.113.55" ]
    [ "$(tail -1 <<<"$SECLOG_LOGIN_ROWS")" = "1725465312|alice|192.168.1.100" ]
}

@test "failures are aggregated per ip and user with the newest timestamp" {
    seclog_collect_failures
    [ "$SECLOG_FAIL_TOTAL" -eq 3 ]
    [ "$SECLOG_FAIL_IPS" -eq 2 ]
    [ "$(head -1 <<<"$SECLOG_FAIL_ROWS")" = "2|1725465100|203.0.113.9|root" ]
}

@test "the text report renders all three blocks" {
    run seclog_print_report
    [ "$status" -eq 0 ]
    [[ $output == *"All active connections (3)"* ]]
    [[ $output == *"[IN ]  192.168.1.100 -> :22"* ]]
    [[ $output == *"app: sshd-session  |  [LAN]  |  alice"* ]]
    [[ $output == *"[OUT]  203.0.113.55:443"* ]]
    [[ $output == *"2x"* ]]
    [[ $output == *"Last 5 successful logins"* ]]
    [[ $output == *"alice"*"192.168.1.100"*"[LAN]"* ]]
    [[ $output == *"Failed SSH attempts (24 hours ago): 3 from 2 IP(s)"* ]]
    [[ $output == *"  2x"*"203.0.113.9"*"user=root"* ]]
}

@test "the JSON report is valid JSON with the expected structure" {
    command -v python3 >/dev/null || skip "python3 not available to validate JSON"
    seclog_print_report_json > "$BATS_TEST_TMPDIR/report.json"
    run python3 - "$BATS_TEST_TMPDIR/report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["version"], d
assert d["journal_readable"] is True
assert d["connections"]["total"] == 3
rows = {(r["direction"], r["peer"]): r for r in d["connections"]["rows"]}
assert rows[("in", "192.168.1.100")]["users"] == "alice"
assert rows[("in", "192.168.1.100")]["geo"] == "[LAN]"
assert rows[("out", "203.0.113.55")]["count"] == 2
assert [l["user"] for l in d["logins"]] == ["bob", "alice"]
assert d["logins"][1]["epoch"] == 1725465312
assert d["failures"]["total"] == 3 and d["failures"]["distinct_ips"] == 2
assert d["failures"]["rows"][0] == {**d["failures"]["rows"][0], "count": 2, "ip": "203.0.113.9", "user": "root"}
print("valid")
PY
    [ "$status" -eq 0 ]
    [ "$output" = valid ]
}

@test "seclog --json runs end to end" {
    command -v python3 >/dev/null || skip "python3 not available to validate JSON"
    run bash "$REPO_ROOT/bin/seclog" status --json "1 hour ago"
    [ "$status" -eq 0 ]
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["failures"]["lookback"]=="1 hour ago"' "$output"
}

@test "an empty journal renders (none) rather than an error" {
    : > "$FIXTURES/journal"
    run seclog_print_report
    [ "$status" -eq 0 ]
    [[ $output == *"successful logins (distinct IPs) ──"$'\n'"  (none)"* ]]
    [[ $output == *"Failed SSH attempts (24 hours ago): none"* ]]
}
