#!/usr/bin/env bats
# Address helpers, transport policy, curl config escaping, JSON output.

load test_helper

setup() { load_lib; }

# ── private ranges ───────────────────────────────────────────────────────

@test "RFC1918, loopback, link-local, CGNAT and ULA are private" {
    for ip in 10.1.2.3 172.16.0.1 172.31.255.255 192.168.0.1 127.0.0.1 169.254.1.1 100.64.0.1 100.127.255.255 ::1 fe80::1 fd12:3456::1 fc00::1; do
        seclog_is_private_ip "$ip" || { echo "should be private: $ip"; return 1; }
    done
}

@test "public addresses are not private" {
    for ip in 8.8.8.8 172.32.0.1 172.15.0.1 100.128.0.1 100.63.255.255 203.0.113.9 2001:db8::1 fe00::1; do
        ! seclog_is_private_ip "$ip" || { echo "should be public: $ip"; return 1; }
    done
}

@test "IPv4-mapped and bracketed addresses are normalised" {
    [ "$(seclog_normalize_ip '[::ffff:192.168.1.5]')" = 192.168.1.5 ]
    [ "$(seclog_normalize_ip '::FFFF:10.0.0.1')" = 10.0.0.1 ]
    [ "$(seclog_normalize_ip '[2001:db8::1]')" = 2001:db8::1 ]
}

@test "seclog_valid_ip rejects option-looking and garbage values" {
    seclog_valid_ip 1.2.3.4
    seclog_valid_ip 2001:db8::1
    ! seclog_valid_ip -v
    ! seclog_valid_ip '--file=/etc/passwd'
    ! seclog_valid_ip 'example.com'
    ! seclog_valid_ip ''
}

# ── URLs ─────────────────────────────────────────────────────────────────

@test "seclog_url_host extracts hosts with ports, paths, userinfo and IPv6 literals" {
    [ "$(seclog_url_host https://ntfy.example.com/topic)" = ntfy.example.com ]
    [ "$(seclog_url_host http://192.168.1.10:2586/topic)" = 192.168.1.10 ]
    [ "$(seclog_url_host 'http://user:pw@host:80/t?x=1')" = host ]
    [ "$(seclog_url_host 'http://[fd00::1]:2586/t')" = fd00::1 ]
    [ "$(seclog_url_host 'https://host/t?q=a/b')" = host ]
}

@test "seclog_mask_url hides the topic and userinfo but keeps scheme, host and port" {
    [ "$(seclog_mask_url https://ntfy.example.com/very-secret)" = 'https://ntfy.example.com/<topic hidden>' ]
    [ "$(seclog_mask_url 'http://u:p@10.0.0.1:2586/secret')" = 'http://10.0.0.1:2586/<topic hidden>' ]
    [ "$(seclog_mask_url 'not a url')" = 'not a url' ]
}

# ── transport policy ─────────────────────────────────────────────────────

@test "https is always accepted" {
    NTFY_URL=https://ntfy.example.com/t NTFY_ALLOW_PLAINTEXT=0 seclog_transport_ok
}

@test "plaintext http to a LAN address or localhost is accepted" {
    NTFY_URL=http://192.168.1.10:2586/t NTFY_ALLOW_PLAINTEXT=0 seclog_transport_ok
    NTFY_URL=http://localhost:2586/t     NTFY_ALLOW_PLAINTEXT=0 seclog_transport_ok
    NTFY_URL='http://[fd00::5]:2586/t'   NTFY_ALLOW_PLAINTEXT=0 seclog_transport_ok
    NTFY_URL='http://[::ffff:10.0.0.2]/t' NTFY_ALLOW_PLAINTEXT=0 seclog_transport_ok
}

@test "plaintext http to a public address is refused unless opted in" {
    ! NTFY_URL=http://ntfy.example.com/t NTFY_ALLOW_PLAINTEXT=0 seclog_transport_ok
    ! NTFY_URL=http://203.0.113.9/t       NTFY_ALLOW_PLAINTEXT=0 seclog_transport_ok
    NTFY_URL=http://ntfy.example.com/t   NTFY_ALLOW_PLAINTEXT=1 seclog_transport_ok
}

@test "other schemes and empty URLs are refused" {
    ! NTFY_URL=ftp://x/t seclog_transport_ok
    ! NTFY_URL= seclog_transport_ok
}

@test "seclog_push refuses plaintext to a public host without contacting it" {
    mock curl <<'EOF'
#!/usr/bin/env bash
echo "curl must not run" >&2; exit 99
EOF
    NTFY_URL=http://ntfy.example.com/t NTFY_ALLOW_PLAINTEXT=0
    run seclog_push t tags low body
    [ "$status" -eq 1 ]
    [[ $output == *REFUSED* ]]
    [[ $output != *"curl must not run"* ]]
    [[ $output != *"/t "* ]]   # the topic is masked in the log line
}

@test "seclog_push keeps url, token and body out of curl's argv" {
    mock curl <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_OUT/argv"
# --config <(...) hands us a /dev/fd path; keep what it says
for ((i = 1; i <= $#; i++)); do
    [[ ${!i} == --config ]] && { j=$((i + 1)); cat "${!j}" > "$MOCK_OUT/config"; }
done
cat > "$MOCK_OUT/body"
EOF
    export MOCK_OUT="$BATS_TEST_TMPDIR"
    NTFY_URL=https://ntfy.example.com/topic NTFY_TOKEN=tk_secret NTFY_TIMEOUT=5
    seclog_push 'Title "quoted"' tags high 'the body'
    ! grep -q tk_secret "$BATS_TEST_TMPDIR/argv"
    ! grep -q ntfy.example.com "$BATS_TEST_TMPDIR/argv"
    grep -q -- '--proto' "$BATS_TEST_TMPDIR/argv"
    grep -qx 'url = "https://ntfy.example.com/topic"' "$BATS_TEST_TMPDIR/config"
    grep -qx 'header = "Authorization: Bearer tk_secret"' "$BATS_TEST_TMPDIR/config"
    grep -qxF 'header = "Title: Title \"quoted\""' "$BATS_TEST_TMPDIR/config"
    [ "$(cat "$BATS_TEST_TMPDIR/body")" = "the body" ]
}

# ── curl config escaping ─────────────────────────────────────────────────

@test "seclog_curl_option escapes backslashes and quotes" {
    [ "$(seclog_curl_option header 'Title: a"b\c')" = 'header = "Title: a\"b\\c"' ]
    [ "$(seclog_curl_option url 'https://h/t')" = 'url = "https://h/t"' ]
}

# ── misc helpers ─────────────────────────────────────────────────────────

@test "seclog_uint accepts only plain non-negative integers" {
    [ "$(seclog_uint 42 5)" = 42 ]
    [ "$(seclog_uint 0 5)" = 0 ]
    [ "$(seclog_uint -1 5)" = 5 ]
    [ "$(seclog_uint 'a[$(x)]' 5)" = 5 ]
    [ "$(seclog_uint '' 5)" = 5 ]
}

@test "seclog_json_str escapes what JSON needs escaped" {
    [ "$(seclog_json_str 'plain')" = '"plain"' ]
    [ "$(seclog_json_str 'a"b\c')" = '"a\"b\\c"' ]
    [ "$(seclog_json_str $'line1\nline2\ttab')" = '"line1\nline2\ttab"' ]
    [ "$(seclog_json_str $'bell\a')" = '"bell"' ]
}

@test "seclog_format_endpoint brackets IPv6" {
    [ "$(seclog_format_endpoint 1.2.3.4 22)" = 1.2.3.4:22 ]
    [ "$(seclog_format_endpoint 2001:db8::1 22)" = '[2001:db8::1]:22' ]
}

@test "time formatting uses the given epoch" {
    export TZ=UTC
    [ "$(seclog_fmt_iso 0)" = 1970-01-01T00:00:00+0000 ]
    [ "$(seclog_fmt_time 86400)" = '1970-01-02 00:00:00 UTC' ]
}
