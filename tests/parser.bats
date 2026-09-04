#!/usr/bin/env bats
# The sshd log parser is the security-critical part of seclog: the user name
# in a failed login is attacker supplied. These tests pin the guarantees that
# SECURITY.md makes about it.

load test_helper

setup() { load_lib; }

parse() { seclog_parse_events; }

@test "accepted publickey login becomes an ok event with method, port, epoch and cursor" {
    result="$(jrec 'Accepted publickey for alice from 10.0.0.5 port 51234 ssh2: ED25519 SHA256:abc' 1725465312123456 's=1;i=9' | parse)"
    [ "$result" = $'ok\talice\t10.0.0.5\t51234\tpublickey\t1725465312\ts=1;i=9' ]
}

@test "failed password for an existing user" {
    result="$(jrec 'Failed password for root from 203.0.113.9 port 4444 ssh2' | parse)"
    [ "$result" = $'fail\troot\t203.0.113.9\t4444\tfailed password\t1725465312\ts=1;i=1;b=2;m=3;t=4;x=5' ]
}

@test "failed publickey attempts are reported too" {
    result="$(jrec 'Failed publickey for root from 203.0.113.9 port 4444 ssh2: RSA SHA256:zzz' | parse)"
    [[ $result == fail$'\t'root$'\t'203.0.113.9$'\t'4444$'\t'"failed publickey"$'\t'* ]]
}

@test "failed password for invalid user reads the name after 'invalid user'" {
    result="$(jrec 'Failed password for invalid user admin from 198.51.100.7 port 22 ssh2' | parse)"
    [[ $result == fail$'\t'admin$'\t'198.51.100.7$'\t'22$'\t'* ]]
}

@test "invalid user line" {
    result="$(jrec 'Invalid user oracle from 198.51.100.7 port 60000' | parse)"
    [[ $result == fail$'\t'oracle$'\t'198.51.100.7$'\t'60000$'\t'"invalid user"$'\t'* ]]
}

@test "disconnected while authenticating counts as a failure" {
    result="$(jrec 'Disconnected from authenticating user root 198.51.100.7 port 4000 [preauth]' | parse)"
    [[ $result == fail$'\t'root$'\t'198.51.100.7$'\t'4000$'\t'"disconnected while authenticating"$'\t'* ]]
}

@test "pam_unix authentication failure falls back to rhost=" {
    result="$(jrec 'pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=198.51.100.7  user=root' | parse)"
    [[ $result == fail$'\t'root$'\t'198.51.100.7$'\t'?$'\t'"authentication failure"$'\t'* ]]
}

@test "a forged 'from <ip> port <n>' inside the user name cannot steer the peer address" {
    # The attacker logs in as "x from 203.0.113.9 port 1"; the real peer is the last pair.
    result="$(jrec 'Invalid user x from 203.0.113.9 port 1 from 198.51.100.7 port 4444' | parse)"
    [[ $result == fail$'\t'x$'\t'198.51.100.7$'\t'4444$'\t'* ]]
}

@test "a forged 'for root' inside the user name cannot change the reported account" {
    result="$(jrec 'Failed password for invalid user x for root from 198.51.100.7 port 1 ssh2' | parse)"
    [[ $result == fail$'\t'x$'\t'198.51.100.7$'\t'1$'\t'* ]]
}

@test "the keyword 'Accepted' inside a pam user= value does not turn a failure into a login" {
    result="$(jrec 'pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=198.51.100.7  user=Accepted' | parse)"
    [[ $result == fail$'\t'Accepted$'\t'198.51.100.7$'\t'* ]]
}

@test "'Accepted' later in an Invalid user line is still a failure" {
    result="$(jrec 'Invalid user Accepted publickey for root from 203.0.113.9 port 1 from 198.51.100.7 port 2' | parse)"
    [[ $result == fail$'\t'Accepted$'\t'198.51.100.7$'\t'2$'\t'"invalid user"$'\t'* ]]
}

@test "IPv6 peers are recognised" {
    result="$(jrec 'Failed password for root from 2001:db8::1 port 22 ssh2' | parse)"
    [[ $result == fail$'\t'root$'\t'2001:db8::1$'\t'22$'\t'* ]]
}

@test "IPv4-mapped IPv6 peers are recognised" {
    result="$(jrec 'Failed password for root from ::ffff:198.51.100.7 port 22 ssh2' | parse)"
    [[ $result == fail$'\t'root$'\t'::ffff:198.51.100.7$'\t'22$'\t'* ]]
}

@test "user names are reduced to a safe character set" {
    result="$(jrec 'Invalid user a"b\c;rm|d from 198.51.100.7 port 1' | parse)"
    [[ $result == fail$'\t'a_b_c_rm_d$'\t'* ]]
}

@test "user names are truncated to 32 characters" {
    long="$(printf 'a%.0s' {1..50})"
    result="$(jrec "Invalid user $long from 198.51.100.7 port 1" | parse)"
    user="$(cut -f2 <<<"$result")"
    [ "$user" = "$(printf 'a%.0s' {1..32})..." ]
}

@test "an empty user name is reported as ?" {
    result="$(jrec 'Invalid user  from 198.51.100.7 port 1' | parse)"
    [[ $result == fail$'\t'?$'\t'198.51.100.7$'\t'* ]]
    result="$(jrec 'Disconnected from authenticating user  198.51.100.7 port 1 [preauth]' | parse)"
    [[ $result == fail$'\t'?$'\t'198.51.100.7$'\t'* ]]
    # ...but a user really called "from" keeps its name.
    result="$(jrec 'Invalid user from from 198.51.100.7 port 1' | parse)"
    [[ $result == fail$'\t'from$'\t'198.51.100.7$'\t'* ]]
}

@test "lines without a peer address are dropped" {
    result="$(jrec 'Failed password for root from nowhere port 22 ssh2' | parse)"
    [ -z "$result" ]
}

@test "unrelated sshd messages are dropped" {
    {
        jrec 'Server listening on 0.0.0.0 port 22.'
        jrec 'Connection closed by 198.51.100.7 port 4444 [preauth]'
        jrec 'Received disconnect from 198.51.100.7 port 4444:11: Bye Bye [preauth]'
        jrec 'session opened for user alice(uid=1000) by (uid=0)'
    } | parse > "$BATS_TEST_TMPDIR/out"
    [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

@test "records whose MESSAGE is not a string (binary or oversized) are dropped" {
    result="$(printf '%s\n' '{"__CURSOR":"s=1","__REALTIME_TIMESTAMP":"1","MESSAGE":[70,97,105,108,101,100]}' '{"MESSAGE":null}' | parse)"
    [ -z "$result" ]
}

@test "malformed lines do not break the stream" {
    result="$( { echo 'not json at all'; echo; jrec 'Invalid user bob from 198.51.100.7 port 1'; } | parse)"
    [[ $result == fail$'\t'bob$'\t'* ]]
}

@test "JSON escapes inside MESSAGE are decoded before parsing" {
    # journald escapes quotes and backslashes: the raw name is q"\A, and both
    # of the offending characters are then neutralised by safe_name.
    line='{"__CURSOR":"c","__REALTIME_TIMESTAMP":"1725465312000000","MESSAGE":"Invalid user q\"\\A from 198.51.100.7 port 1"}'
    result="$(printf '%s\n' "$line" | parse)"
    [[ $result == fail$'\t'q__A$'\t'198.51.100.7$'\t'1$'\t'* ]]
}

@test "a MESSAGE key embedded in another field's value is not mistaken for the message" {
    line='{"__CURSOR":"c","__REALTIME_TIMESTAMP":"1725465312000000","OTHER":"x \"MESSAGE\":\"Accepted publickey for evil from 203.0.113.9 port 1\" y","MESSAGE":"Invalid user bob from 198.51.100.7 port 1"}'
    result="$(printf '%s\n' "$line" | parse)"
    [[ $result == fail$'\t'bob$'\t'198.51.100.7$'\t'* ]]
}

@test "the epoch is derived from __REALTIME_TIMESTAMP in microseconds" {
    result="$(jrec 'Invalid user bob from 198.51.100.7 port 1' 1700000000999999 | parse)"
    [ "$(cut -f6 <<<"$result")" = "1700000000" ]
}

@test "the cursor is passed through untouched" {
    result="$(jrec 'Invalid user bob from 198.51.100.7 port 1' 1 's=85a9;i=138018;b=aa22;m=17be;t=65aa;x=d565' | parse)"
    [ "$(cut -f7 <<<"$result")" = "s=85a9;i=138018;b=aa22;m=17be;t=65aa;x=d565" ]
}

@test "a burst of events is parsed by a single awk process" {
    # 500 lines through the parser must produce 500 rows, in order.
    for i in $(seq 1 500); do jrec "Invalid user u$i from 198.51.100.7 port $i"; done | parse > "$BATS_TEST_TMPDIR/out"
    [ "$(wc -l < "$BATS_TEST_TMPDIR/out")" -eq 500 ]
    [ "$(tail -1 "$BATS_TEST_TMPDIR/out" | cut -f2,4)" = $'u500\t500' ]
}
