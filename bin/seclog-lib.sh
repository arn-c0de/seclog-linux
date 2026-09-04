#!/usr/bin/env bash
# seclog-lib.sh — shared library for all seclog-linux commands.
#
# Sourced by: seclog, seclog-login, seclog-monitor, seclog-diagnose, seclog-update.
# Everything here is namespaced with `seclog_` / `SECLOG_` so that sourcing the
# library never collides with the caller's own names. Sourcing it has no side
# effects beyond defining functions and constants.

# shellcheck disable=SC2034  # consumed by the commands that source this file
SECLOG_VERSION="1.0.3"

SECLOG_CONFIG="${SECLOG_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/seclog-linux/config}"
# systemd exports CACHE_DIRECTORY when the unit declares CacheDirectory=.
SECLOG_STATE_DIR="${SECLOG_STATE_DIR:-${CACHE_DIRECTORY:-${XDG_CACHE_HOME:-$HOME/.cache}/seclog-linux}}"
SECLOG_NTFY_PLACEHOLDER="http://YOUR_NTFY_HOST:2586/YOUR_TOPIC"
SECLOG_LOGGER="$(command -v logger 2>/dev/null || true)"

# journalctl matchers for the sshd daemon. Modern OpenSSH splits the per-session
# work into `sshd-session`, older releases log everything as `sshd`.
SECLOG_SSHD_MATCH=(_COMM=sshd-session _COMM=sshd)

# Every setting the config file may define. Anything else is ignored with a
# warning, and nothing in the file is ever executed.
SECLOG_CONFIG_KEYS=(
    NTFY_URL NTFY_TOKEN NTFY_ALLOW_PLAINTEXT NTFY_TIMEOUT PUSH_METADATA_LEVEL
    LOGIN_PUSH_SOURCE LOGIN_DEDUP_WINDOW BANNER_EXTRA_FILE
    FAIL_LOOKBACK JOURNAL_TIMEOUT FAIL_RATELIMIT_WINDOW STATE_TTL_DAYS REPLAY_MAX_AGE
    GEOIP_DB
    SECLOG_REPO_DIR ALLOW_CUSTOM_REPO_DIR EXPECTED_UPDATE_ORIGIN EXPECTED_UPDATE_ORIGIN_ALT
    UPDATE_SIGNER UPDATE_CHANNEL
)

# ────────────────────────────────────────────────────────────── logging ──

# Local audit trail, primarily journald via logger(1). The journal is not
# writable by the account being monitored, so someone who takes over that
# account can stop future notifications but cannot quietly erase the record
# that earlier ones were sent — or that a send failed.
# Levels: info | notice | warning | err
seclog_log() {
    local level="$1"; shift
    [[ -n $SECLOG_LOGGER ]] && "$SECLOG_LOGGER" -t seclog-linux -p "auth.$level" -- "$*" 2>/dev/null
    # The journal is the durable record, but anything the operator has to act
    # on has to reach them where they are — a monitoring tool that fails
    # quietly is worse than no monitoring tool.
    case "$level" in
        err|warning) printf 'seclog-linux[%s]: %s\n' "$level" "$*" >&2 ;;
    esac
    return 0
}

# ──────────────────────────────────────────────────────────────── time ──

# Bash 5 formats time itself; no fork per event.
seclog_now()        { printf '%(%Y-%m-%d %H:%M:%S %Z)T' -1; }
seclog_fmt_time()   { printf '%(%Y-%m-%d %H:%M:%S %Z)T' "$1"; }   # <epoch>
seclog_fmt_short()  { printf '%(%b %d %H:%M:%S)T' "$1"; }         # <epoch>
seclog_fmt_iso()    { printf '%(%Y-%m-%dT%H:%M:%S%z)T' "$1"; }    # <epoch>

# ─────────────────────────────────────────────────────────────── config ──

# True when `path` is owned by us (or root) and not writable by anyone else.
seclog_path_is_trusted() {
    local path="$1" owner mode
    owner="$(stat -Lc '%u' "$path" 2>/dev/null)" || return 1
    [[ $owner == "$(id -u)" || $owner == 0 ]] || return 1
    mode="$(stat -Lc '%a' "$path" 2>/dev/null)" || return 1
    (( 8#$mode & 8#022 )) && return 1
    return 0
}

# Echo $1 when it is a plain non-negative integer, otherwise the fallback $2.
# Several of these values end up in an arithmetic context, where bash evaluates
# what it finds rather than merely reading it.
seclog_uint() {
    [[ ${1:-} =~ ^[0-9]+$ ]] && { printf '%s' "$1"; return 0; }
    printf '%s' "$2"
}

seclog_config_key_allowed() {
    local key
    for key in "${SECLOG_CONFIG_KEYS[@]}"; do
        [[ $key == "$1" ]] && return 0
    done
    return 1
}

# Read a KEY=value file without executing any of it.
#
# Accepted per line: blank, `# comment`, `KEY=value`, `KEY="value"`,
# `KEY='value'`, an optional leading `export`, and a trailing `# comment`
# after an unquoted or quoted value. Values are taken literally: no variable
# expansion, no command substitution, no escape processing. Unknown keys and
# malformed lines are reported and skipped, never applied.
seclog_parse_config() {
    local file="$1" lineno=0 line key rest value
    local re_line='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$'
    local re_dq='^"([^"]*)"[[:space:]]*(#.*)?$'
    local re_sq="^'([^']*)'[[:space:]]*(#.*)?\$"

    while IFS= read -r line || [[ -n $line ]]; do
        (( ++lineno ))
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z $line || $line == \#* ]] && continue

        if [[ ! $line =~ $re_line ]]; then
            seclog_log warning "$file:$lineno: not a KEY=value line, ignored"
            continue
        fi
        key="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        rest="${rest#"${rest%%[![:space:]]*}"}"

        if [[ $rest =~ $re_dq || $rest =~ $re_sq ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ $rest == \"* || $rest == \'* ]]; then
            seclog_log warning "$file:$lineno: unbalanced quotes in $key, ignored"
            continue
        else
            value="${rest%%[[:space:]]#*}"
            value="${value%"${value##*[![:space:]]}"}"
        fi

        if ! seclog_config_key_allowed "$key"; then
            seclog_log warning "$file:$lineno: unknown setting $key ignored"
            continue
        fi
        if [[ $value == *[\$\`]* ]]; then
            seclog_log warning "$file:$lineno: $key is taken literally, the config is not shell code"
        fi
        printf -v "$key" '%s' "$value"
    done <"$file"
}

# Load the user config and fill in defaults. Idempotent.
#
# The file is parsed, not sourced, so a writer cannot run code through it
# directly. It still carries the ntfy token and the update trust settings
# (expected origin, repository path, expected signer), and steering those is
# code execution one step removed — so a loosely permissioned config is
# refused rather than warned about.
seclog_load_config() {
    local dir
    if [[ -e $SECLOG_CONFIG ]]; then
        dir="$(dirname -- "$SECLOG_CONFIG")"
        if ! seclog_path_is_trusted "$dir"; then
            seclog_log err "refusing to read $SECLOG_CONFIG: $dir is foreign-owned or writable by group/others — fix with: chmod 700 '$dir'"
            exit 1
        fi
        if ! seclog_path_is_trusted "$SECLOG_CONFIG"; then
            seclog_log err "refusing to read $SECLOG_CONFIG: not owned by you, or group/world writable — fix with: chmod 600 '$SECLOG_CONFIG'"
            exit 1
        fi
        seclog_parse_config "$SECLOG_CONFIG"
    fi

    NTFY_URL="${NTFY_URL:-}"
    NTFY_TOKEN="${NTFY_TOKEN:-}"
    NTFY_TIMEOUT="$(seclog_uint "${NTFY_TIMEOUT:-}" 5)"
    # Plaintext HTTP to anything outside the local network needs an explicit
    # opt-in; see seclog_transport_ok.
    NTFY_ALLOW_PLAINTEXT="${NTFY_ALLOW_PLAINTEXT:-0}"
    FAIL_LOOKBACK="${FAIL_LOOKBACK:-24 hours ago}"
    FAIL_RATELIMIT_WINDOW="$(seclog_uint "${FAIL_RATELIMIT_WINDOW:-}" 300)"
    # Successful logins are reported by the monitor by default: it sees every
    # login (scp, sftp, rsync, `ssh host cmd`, any shell), while the .bashrc
    # banner only ever sees interactive bash. monitor | banner | both
    LOGIN_PUSH_SOURCE="${LOGIN_PUSH_SOURCE:-monitor}"
    LOGIN_DEDUP_WINDOW="$(seclog_uint "${LOGIN_DEDUP_WINDOW:-}" 60)"
    # Optional text file appended to the login banner (site-specific hints).
    BANNER_EXTRA_FILE="${BANNER_EXTRA_FILE:-}"
    # `full` adds uid, groups, rDNS, SSH key fingerprint and TTY to the push.
    PUSH_METADATA_LEVEL="${PUSH_METADATA_LEVEL:-minimal}"
    STATE_TTL_DAYS="$(seclog_uint "${STATE_TTL_DAYS:-}" 7)"
    # 0 disables the timeout.
    JOURNAL_TIMEOUT="$(seclog_uint "${JOURNAL_TIMEOUT:-}" 2)"
    # Events older than this are counted but not pushed when the monitor
    # catches up after downtime.
    REPLAY_MAX_AGE="$(seclog_uint "${REPLAY_MAX_AGE:-}" 3600)"
    # Explicit GeoLite2 database path; auto-detected when empty.
    GEOIP_DB="${GEOIP_DB:-}"
    # release = newest signed semver tag, branch = signed tip of the branch.
    UPDATE_CHANNEL="${UPDATE_CHANNEL:-release}"
}

# True when NTFY_URL points somewhere other than the shipped placeholder.
seclog_ntfy_configured() {
    [[ -n ${NTFY_URL:-} && $NTFY_URL != "$SECLOG_NTFY_PLACEHOLDER" ]]
}

# ─────────────────────────────────────────────────────────────── output ──

# Define C_* colour variables, empty when stdout is not a terminal or the
# caller opted out via NO_COLOR.
seclog_init_colors() {
    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
        C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
        C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
    else
        C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_OFF=''
    fi
}

seclog_heading() {
    local color="$1" text="$2"
    printf '%s── %s ──%s\n' "${C_BLD}${color}" "$text" "${C_OFF}"
}

# Quote a string as a JSON string literal.
seclog_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//[[:cntrl:]]/}"
    printf '"%s"' "$s"
}

# ─────────────────────────────────────────────────────────── addresses ──

# True for a syntactically plausible IPv4 or IPv6 literal. Used before values
# taken from logs or `ss` are handed to another program as an argument.
seclog_valid_ip() {
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
    [[ $1 =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f.:]+$ ]] && return 0
    return 1
}

# Strip brackets and the IPv4-mapped IPv6 prefix: [::ffff:1.2.3.4] -> 1.2.3.4
seclog_normalize_ip() {
    local ip="$1"
    ip="${ip#\[}"; ip="${ip%\]}"
    ip="${ip#::ffff:}"; ip="${ip#::FFFF:}"
    printf '%s' "$ip"
}

# RFC1918 + loopback + link-local + CGNAT + IPv6 ULA.
seclog_is_private_ip() {
    case "$1" in
        10.*|127.*|169.254.*|192.168.*)            return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*)     return 0 ;;
        100.6[4-9].*|100.[789][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        ::1|fe80:*|fc*:*|fd*:*)                    return 0 ;;
    esac
    return 1
}

# Host part of a URL, including bracketed IPv6 literals.
seclog_url_host() {
    local host="${1#*://}"
    host="${host%%/*}"
    host="${host%%\?*}"
    host="${host##*@}"
    if [[ $host == \[*\]* ]]; then
        host="${host#\[}"; host="${host%%\]*}"
    else
        host="${host%%:*}"
    fi
    printf '%s' "$host"
}

# scheme://host:port/<topic hidden> — the topic is the only secret on a public
# ntfy server, so it never goes into diagnostics output.
seclog_mask_url() {
    local url="$1" scheme rest
    [[ $url == *://* ]] || { printf '%s' "$url"; return 0; }
    scheme="${url%%://*}"
    rest="${url#*://}"
    rest="${rest##*@}"
    printf '%s://%s/<topic hidden>' "$scheme" "${rest%%/*}"
}

# Render an address as "ip:port", bracketing IPv6 so the colons stay readable.
seclog_format_endpoint() {
    if [[ $1 == *:* ]]; then
        printf '[%s]:%s' "$1" "$2"
    else
        printf '%s:%s' "$1" "$2"
    fi
}

# ────────────────────────────────────────────────────────────────── geo ──

# Country for an IP. Backends, in order of preference:
#   mmdb    libmaxminddb's mmdblookup with a GeoLite2 Country or City database
#   legacy  geoiplookup / geoiplookup6 with the unmaintained GeoIP databases
# Results are cached per process: the banner would otherwise fork one lookup
# per connection row.
declare -gA SECLOG_GEO_CACHE=()

SECLOG_GEO_DB_CANDIDATES=(
    /var/lib/GeoIP/GeoLite2-Country.mmdb
    /var/lib/GeoIP/GeoLite2-City.mmdb
    /usr/share/GeoIP/GeoLite2-Country.mmdb
    /usr/share/GeoIP/GeoLite2-City.mmdb
)

# Sets SECLOG_GEO_BACKEND to mmdb | legacy | none (and SECLOG_GEO_DB for mmdb).
seclog_geo_backend() {
    [[ -n ${SECLOG_GEO_BACKEND:-} ]] && return 0
    SECLOG_GEO_BACKEND=none
    SECLOG_GEO_DB=""
    local db
    if command -v mmdblookup >/dev/null 2>&1; then
        for db in "${GEOIP_DB:-}" "${SECLOG_GEO_DB_CANDIDATES[@]}"; do
            [[ -n $db && -r $db ]] || continue
            SECLOG_GEO_BACKEND=mmdb
            SECLOG_GEO_DB="$db"
            return 0
        done
    fi
    command -v geoiplookup >/dev/null 2>&1 && SECLOG_GEO_BACKEND=legacy
    return 0
}

# "DE, Germany" from the country map mmdblookup prints.
seclog_geo_mmdb() {
    mmdblookup --file "$SECLOG_GEO_DB" --ip "$1" country 2>/dev/null |
        awk '
            /"iso_code":/ { want = "iso"; next }
            /"en":/       { want = "en";  next }
            want != "" {
                if (match($0, /"[^"]*"/)) v[want] = substr($0, RSTART + 1, RLENGTH - 2)
                want = ""
            }
            END {
                if (v["iso"] != "" && v["en"] != "") print v["iso"] ", " v["en"]
                else if (v["en"] != "")               print v["en"]
                else if (v["iso"] != "")              print v["iso"]
            }'
}

seclog_geo_legacy() {
    # The legacy GeoIP databases are split: geoiplookup is IPv4-only.
    local tool="geoiplookup"
    [[ $1 == *:* ]] && tool="geoiplookup6"
    command -v "$tool" >/dev/null 2>&1 || return 0
    "$tool" "$1" 2>/dev/null |
        awk -F': ' '/Country Edition/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }'
}

# Resolve $1 into SECLOG_GEO: country, "[LAN]" for private ranges, "" when
# unknown. Sets a variable instead of printing so the cache survives — a
# `$(...)` call would run in a subshell and forget it.
seclog_geo_lookup() {
    local ip
    ip="$(seclog_normalize_ip "$1")"
    SECLOG_GEO=""
    [[ -z $ip ]] && return 0
    # Never hand an unvalidated string to a lookup tool: a value starting with
    # "-" would be parsed as an option.
    seclog_valid_ip "$ip" || return 0

    if [[ -n ${SECLOG_GEO_CACHE[$ip]+set} ]]; then
        SECLOG_GEO="${SECLOG_GEO_CACHE[$ip]}"
        return 0
    fi

    if seclog_is_private_ip "$ip"; then
        SECLOG_GEO="[LAN]"
    else
        seclog_geo_backend
        case "$SECLOG_GEO_BACKEND" in
            mmdb)   SECLOG_GEO="$(seclog_geo_mmdb "$ip")" ;;
            legacy) SECLOG_GEO="$(seclog_geo_legacy "$ip")" ;;
        esac
    fi
    SECLOG_GEO_CACHE[$ip]="$SECLOG_GEO"
    return 0
}

seclog_geo() {
    seclog_geo_lookup "$1"
    printf '%s' "$SECLOG_GEO"
}

# Same as seclog_geo but never returns an empty string.
seclog_geo_or_unknown() {
    seclog_geo_lookup "$1"
    printf '%s' "${SECLOG_GEO:-(unknown)}"
}

# ─────────────────────────────────────────────────────────────── ntfy ────

# Emit one curl --config line with a properly escaped value.
seclog_curl_option() {
    local value="$2"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s = "%s"\n' "$1" "$value"
}

# The push body is a complete reconnaissance profile of the host — account,
# uid, group membership, client address, SSH key fingerprint, every active peer
# — and the bearer token travels in the same request. Refuse plaintext HTTP
# unless the target is on the local network or the user accepted the risk.
seclog_transport_ok() {
    case "${NTFY_URL:-}" in
        https://*) return 0 ;;
        http://*)  ;;
        *)         return 1 ;;
    esac
    [[ ${NTFY_ALLOW_PLAINTEXT:-0} == 1 ]] && return 0

    local host
    host="$(seclog_url_host "$NTFY_URL")"
    [[ $host == localhost ]] && return 0
    seclog_is_private_ip "$(seclog_normalize_ip "$host")"
}

# seclog_push <title> <tags> <priority> <body>
# Returns non-zero when ntfy is unconfigured, the transport is unsafe, or the
# request fails. Every outcome is recorded through seclog_log.
seclog_push() {
    local title="$1" tags="$2" priority="$3" body="$4" proto err rc=0

    if ! seclog_ntfy_configured; then
        seclog_log warning "push skipped, NTFY_URL is not configured: $title"
        return 1
    fi
    if ! seclog_transport_ok; then
        seclog_log err "push REFUSED, $(seclog_mask_url "$NTFY_URL") would send credentials and host metadata over plaintext HTTP to a non-local address; use https:// or set NTFY_ALLOW_PLAINTEXT=1 to accept the risk"
        return 1
    fi

    proto="=https"
    [[ $NTFY_URL == http://* ]] && proto="=http,https"

    # URL, title, body and token all travel out of band: curl's argv is world
    # readable via /proc/<pid>/cmdline for every other local account.
    err="$(curl \
        --config <(
            seclog_curl_option url "$NTFY_URL"
            seclog_curl_option header "Title: $title"
            seclog_curl_option header "Tags: $tags"
            seclog_curl_option header "Priority: $priority"
            if [[ -n ${NTFY_TOKEN:-} ]]; then
                seclog_curl_option header "Authorization: Bearer $NTFY_TOKEN"
            fi
        ) \
        --fail --silent --show-error \
        --max-time "$NTFY_TIMEOUT" \
        --proto "$proto" --proto-redir "$proto" \
        --data-binary @- <<<"$body" 2>&1 >/dev/null)" || rc=$?

    if (( rc == 0 )); then
        seclog_log info "push sent: $title"
    else
        seclog_log err "push FAILED (curl exit $rc): $title${err:+ — $err}"
    fi
    return "$rc"
}

# ────────────────────────────────────────────────────────────── journal ──

# journalctl wrapper: JSON output, honours JOURNAL_TIMEOUT, never leaks stderr.
# One JSON object per line; the awk helpers below pick the fields out.
seclog_journal() {
    if [[ ${JOURNAL_TIMEOUT:-0} =~ ^[0-9]+$ && ${JOURNAL_TIMEOUT:-0} -gt 0 ]]; then
        timeout "$JOURNAL_TIMEOUT" journalctl --no-pager -o json "$@" 2>/dev/null
    else
        journalctl --no-pager -o json "$@" 2>/dev/null
    fi
}

# True when this user cannot read the system journal, which makes an empty
# result ambiguous ("nothing happened" vs. "not allowed to look"). Probes
# journald instead of guessing from group names: Debian grants access through
# `adm`, others through `systemd-journal` or `wheel`. Cached per process.
seclog_journal_restricted() {
    if [[ -z ${SECLOG_JOURNAL_RESTRICTED:-} ]]; then
        local err rc=0
        if (( EUID == 0 )); then
            SECLOG_JOURNAL_RESTRICTED=0
        else
            err="$(journalctl --system -q -n 0 2>&1 >/dev/null)" || rc=$?
            if (( rc != 0 )) || [[ $err == *"insufficient permissions"* || $err == *"No journal files were opened"* ]]; then
                SECLOG_JOURNAL_RESTRICTED=1
            else
                SECLOG_JOURNAL_RESTRICTED=0
            fi
        fi
    fi
    (( SECLOG_JOURNAL_RESTRICTED ))
}

# ─────────────────────────────────────────────── sshd log line parser ──

# Awk helpers shared by the live monitor, the report and the tests.
#
# Input is `journalctl -o json`, one record per line. use_message() lifts the
# bare sshd message into $0, so the parser never sees a timestamp or syslog
# prefix and can anchor on the first token — a line whose first word is not
# one of sshd's own keywords is not an sshd event, whatever it contains.
#
# Parsing sshd log lines is security relevant. The user name in a failed login
# is entirely attacker supplied and OpenSSH only escapes control characters
# when logging it (strnvis with VIS_SAFE), so spaces and every other printable
# character survive. A login attempt as `x from 203.0.113.9 port 1 for root`
# lets an attacker forge any field that is read by scanning left to right —
# both misattributing the alert and, worse, pinning the rate-limit state on an
# IP of their choosing so that a single push silences everything that follows.
#
# sshd always writes the real peer as the *last* "<ip> port <n>" pair on the
# line and only appends its own trailer after it ("ssh2", "[preauth]", a key
# fingerprint), so scanning backwards from the end cannot be steered.
SECLOG_AWK_LIB='
# String field `key` of the JSON object in $0, "" when missing or not a string
# (journald emits non-UTF-8 and oversized fields as arrays or null). The
# serializer escapes every quote inside a value, so a literal "KEY":" can only
# be the key itself, never attacker text.
function json_str(key,   s, i, n, c, out) {
    i = index($0, "\"" key "\":\"")
    if (i == 0) return ""
    s = substr($0, i + length(key) + 4)
    i = index(s, "\"")
    if (i == 0) return ""
    if (index(substr(s, 1, i - 1), "\\") == 0) return substr(s, 1, i - 1)
    out = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") {
            i++; c = substr(s, i, 1)
            if      (c == "n") c = "\n"
            else if (c == "t") c = "\t"
            else if (c == "r") c = "\r"
            else if (c == "u") { c = "?"; i += 4 }
            out = out c
        } else if (c == "\"") {
            break
        } else {
            out = out c
        }
    }
    return out
}

# Load the sshd message of the current record into $0 and remember the
# record`s EPOCH (seconds) and CURSOR. Returns 0 when there is no message.
function use_message(   m, ts) {
    m = json_str("MESSAGE")
    if (m == "") return 0
    ts = json_str("__REALTIME_TIMESTAMP")
    EPOCH = (length(ts) > 6) ? substr(ts, 1, length(ts) - 6) + 0 : 0
    CURSOR = json_str("__CURSOR")
    $0 = m
    return 1
}

function ip_ok(s) {
    if (s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)        return 1
    if (s ~ /^[0-9A-Fa-f:]*:[0-9A-Fa-f.:]+$/)            return 1
    return 0
}

# Value of the first "key=value" token, as used by the pam_unix log format.
function kv(key,   m) {
    if (!match($0, "(^|[ \t])" key "=[^ \t]+")) return ""
    m = substr($0, RSTART, RLENGTH)
    sub(/^[ \t]/, "", m)
    sub(/^[^=]*=/, "", m)
    return m
}

# Index of the last "<ip> port <n>" triple on the line, 0 when there is none.
function peer_at(   i) {
    for (i = NF - 1; i >= 2; i--)
        if ($i == "port" && $(i + 1) ~ /^[0-9]+$/ && ip_ok($(i - 1)))
            return i
    return 0
}

function peer_ip(   i, r) {
    i = peer_at()
    if (i > 0) return $(i - 1)
    r = kv("rhost")
    return ip_ok(r) ? r : ""
}

function peer_port(   i) {
    i = peer_at()
    return (i > 0) ? $(i + 1) : "?"
}

# Reduce an attacker controlled name to something that cannot forge extra
# fields in a notification body or a terminal table.
function safe_name(s) {
    if (s == "") return "?"
    gsub(/[^A-Za-z0-9._@-]/, "_", s)
    return (length(s) > 32) ? substr(s, 1, 32) "..." : s
}

# 1 when the message opens with one of sshd`s own keywords. Because $0 is the
# bare message, the keyword is the first token or the line is not that event.
function msg_start() {
    if ($1 == "Accepted" || $1 == "Failed" || $1 == "Invalid" || $1 == "Disconnected") return 1
    return 0
}

function is_pam_failure() {
    return ($1 == "pam_unix(sshd:auth):" && $2 == "authentication" && $3 == "failure;")
}

# The account a login referred to. Read positionally from the known grammar --
# searching the line for "for" or "user" lets a name like `x for root` pick the
# reported account.
function login_user(   u, i) {
    if (msg_start()) {
        if      ($1 == "Invalid"      && $2 == "user") i = 3
        else if ($1 == "Accepted"     && $3 == "for")  i = 4
        else if ($1 == "Disconnected" && $4 == "user") i = 5
        else if ($1 == "Failed"       && $3 == "for") {
            if ($4 == "invalid" && $5 == "user") i = 6
            else                                 i = 4
        }
        if (i > 0) {
            u = $i
            # An empty name leaves "from <ip> port" (or "<ip> port") in the
            # slot, because awk collapses the double space sshd wrote.
            if ((u == "from" && ip_ok($(i + 1)) && $(i + 2) == "port") ||
                (ip_ok(u) && $(i + 1) == "port"))
                u = ""
        }
    }
    if (u == "") u = kv("user")
    return safe_name(u)
}

# The authentication method of an "Accepted <method> for ..." line.
function auth_method() {
    if ($1 == "Accepted") return safe_name($2)
    return "unknown"
}

# Classify the message: sets KIND to "ok" or "fail" and REASON, returns 0 for
# anything that is not a login event.
function classify() {
    KIND = ""; REASON = ""
    if (msg_start()) {
        if      ($1 == "Accepted" && $3 == "for") { KIND = "ok";   REASON = auth_method() }
        else if ($1 == "Failed"   && $3 == "for") { KIND = "fail"; REASON = "failed " safe_name($2) }
        else if ($1 == "Invalid"  && $2 == "user") { KIND = "fail"; REASON = "invalid user" }
        else if ($1 == "Disconnected" && $2 == "from" && $3 == "authenticating" && $4 == "user") {
            KIND = "fail"; REASON = "disconnected while authenticating"
        }
    } else if (is_pam_failure()) {
        KIND = "fail"; REASON = "authentication failure"
    }
    return KIND != ""
}
'

# Stream program for the monitor: journal JSON in, one tab-separated event out:
#   <kind> <user> <ip> <port> <reason> <epoch> <cursor>
# Runs as a single long-lived awk, so a brute-force burst costs one process,
# not one per line.
SECLOG_AWK_EVENTS='
BEGIN { OFS = "\t" }
{
    if (!use_message()) next
    if (!classify())    next
    ip = peer_ip()
    if (ip == "") next
    print KIND, login_user(), ip, peer_port(), REASON, EPOCH, CURSOR
    fflush()
}
'

# stdin: journalctl -o json lines. stdout: event rows as above.
seclog_parse_events() {
    awk "${SECLOG_AWK_LIB}${SECLOG_AWK_EVENTS}"
}

# ─────────────────────────────────────────────── established connections ──

# Collect established TCP connections from `ss` and export:
#   SECLOG_CONN_ROWS   tab-separated: direction, peer-ip, port, process, count
#   SECLOG_CONN_TOTAL  number of established sockets
#   SECLOG_CONN_PEERS  comma-separated list of distinct inbound peer IPs
seclog_collect_connections() {
    local sockets listeners
    sockets="$(ss -tnp 2>/dev/null)"
    # Real listening ports, so the direction of a connection is a fact rather
    # than a guess. Without this a backdoor listening on a high port, reached
    # from a low source port, is reported as an outbound connection.
    listeners="$(ss -ltn 2>/dev/null |
        awk '$1 == "LISTEN" { p = $4; sub(/.*:/, "", p); print p + 0 }' |
        sort -un | paste -sd, -)"

    SECLOG_CONN_TOTAL="$(awk '$1 == "ESTAB" { n++ } END { print n + 0 }' <<<"$sockets")"

    SECLOG_CONN_ROWS="$(awk -v listen_ports="$listeners" '
        function port(addr,   p) { p = addr; sub(/.*:/, "", p); return p + 0 }
        function host(addr,   h) { h = addr; sub(/:[^:]*$/, "", h); gsub(/^\[|\]$/, "", h); return h }

        BEGIN {
            OFS = "\t"
            n = split(listen_ports, lp, ",")
            for (i = 1; i <= n; i++) if (lp[i] != "") { listening[lp[i] + 0] = 1; known = 1 }
        }
        $1 != "ESTAB" { next }
        {
            # The process column is quoted, e.g. users:(("sshd",pid=1,fd=2)).
            process = "-"; rest = ""
            for (i = 6; i <= NF; i++) rest = rest $i
            if (match(rest, /"[^"]+"/)) process = substr(rest, RSTART + 1, RLENGTH - 2)

            local_port = port($4); peer_port = port($5)
            if (known) {
                l = (local_port in listening); p = (peer_port in listening)
                if (l && !p)      inbound = 1
                else if (!l && p) inbound = 0
                else              inbound = (local_port <= peer_port)
            } else {
                inbound = (local_port <= peer_port)
            }

            if (inbound) key = "IN"  OFS host($5) OFS local_port OFS process
            else         key = "OUT" OFS host($5) OFS peer_port  OFS process
            seen[key]++
        }
        END { for (k in seen) print k, seen[k] }
    ' <<<"$sockets" | sort -t$'\t' -k1,1 -k2,2)"

    # shellcheck disable=SC2034  # read by seclog-login for the push body
    SECLOG_CONN_PEERS="$(awk -F'\t' '$1 == "IN" { print $2 }' <<<"$SECLOG_CONN_ROWS" |
        sort -u | paste -sd, -)"
}

# Logged-in users coming from $1, comma separated.
seclog_users_from() {
    who 2>/dev/null | grep -F "($1)" | awk '{ print $1 }' | sort -u | paste -sd, -
}

# Render the connection block collected by seclog_collect_connections.
seclog_print_connections() {
    seclog_heading "$C_BLU" "All active connections (${SECLOG_CONN_TOTAL:-0})"

    if [[ -z ${SECLOG_CONN_ROWS:-} ]]; then
        printf '  (none)\n\n'
        return 0
    fi

    local dir peer port process count users repeat
    while IFS=$'\t' read -r dir peer port process count; do
        [[ -z $dir ]] && continue
        seclog_geo_lookup "$peer"
        repeat=""; (( count > 1 )) && repeat="  |  ${count}x"

        if [[ $dir == IN ]]; then
            users="$(seclog_users_from "$peer")"
            printf '  [IN ]  %s -> :%s\n' "$peer" "$port"
            printf '         app: %s  |  %s%s%s\n\n' \
                "$process" "${SECLOG_GEO:-(unknown)}" "${users:+  |  $users}" "$repeat"
        else
            printf '  [OUT]  %s\n' "$(seclog_format_endpoint "$peer" "$port")"
            printf '         app: %s  |  %s%s\n\n' "$process" "${SECLOG_GEO:-(unknown)}" "$repeat"
        fi
    done <<<"$SECLOG_CONN_ROWS"

    # `ss` only reveals the owning process for our own sockets, so say so
    # rather than letting "app: -" read as "no process".
    (( EUID != 0 )) && printf '  (app names are only visible for your own processes; run as root to see all)\n\n'
    return 0
}

# ──────────────────────────────────────────────────── successful logins ──

# Collect the most recent successful SSH logins, one per distinct source IP:
#   SECLOG_LOGIN_ROWS  pipe-separated: epoch, user, ip
seclog_collect_logins() {
    local limit="${1:-5}"
    SECLOG_LOGIN_LIMIT="$limit"
    SECLOG_LOGIN_ROWS="$(seclog_journal -r "${SECLOG_SSHD_MATCH[@]}" |
        awk -v limit="$limit" "$SECLOG_AWK_LIB"'
        BEGIN { OFS = "|" }
        {
            if (!use_message()) next
            if (!($1 == "Accepted" && $3 == "for")) next
            ip = peer_ip()
            if (ip == "" || seen[ip]++) next
            print EPOCH, login_user(), ip
            if (++shown >= limit) exit
        }')"
}

seclog_print_logins() {
    local epoch user ip
    seclog_heading "$C_GRN" "Last ${SECLOG_LOGIN_LIMIT:-5} successful logins (distinct IPs)"

    if [[ -n ${SECLOG_LOGIN_ROWS:-} ]]; then
        while IFS='|' read -r epoch user ip; do
            [[ -n $ip ]] || continue
            seclog_geo_lookup "$ip"
            printf '  %-16s  %-12s  %-18s  %s\n' \
                "$(seclog_fmt_short "$epoch")" "$user" "$ip" "${SECLOG_GEO:-(unknown)}"
        done <<<"$SECLOG_LOGIN_ROWS"
    elif seclog_journal_restricted; then
        printf '  (journal access unavailable; add this user to the systemd-journal group)\n'
    else
        printf '  (none)\n'
    fi
    printf '\n'
}

# ─────────────────────────────────────────────────────── failed attempts ──

# Aggregate failed SSH logins over FAIL_LOOKBACK and export:
#   SECLOG_FAIL_ROWS   pipe-separated: count, last-seen epoch, ip, user (top 10)
#   SECLOG_FAIL_TOTAL  total number of failed attempts
#   SECLOG_FAIL_IPS    number of distinct source IPs
seclog_collect_failures() {
    SECLOG_FAIL_ROWS="$(seclog_journal --since "$FAIL_LOOKBACK" "${SECLOG_SSHD_MATCH[@]}" |
        awk "$SECLOG_AWK_LIB"'
        {
            if (!use_message()) next
            if (!classify() || KIND != "fail") next
            ip = peer_ip()
            if (ip == "") next
            key = ip "|" login_user()
            count[key]++
            last[key] = EPOCH
        }
        END { for (k in count) printf "%d|%s|%s\n", count[k], last[k], k }
    ' | sort -t'|' -k1,1nr | head -10)"

    SECLOG_FAIL_TOTAL=0
    SECLOG_FAIL_IPS=0
    if [[ -n $SECLOG_FAIL_ROWS ]]; then
        SECLOG_FAIL_IPS="$(wc -l <<<"$SECLOG_FAIL_ROWS")"
        SECLOG_FAIL_TOTAL="$(awk -F'|' '{ total += $1 } END { print total + 0 }' <<<"$SECLOG_FAIL_ROWS")"
    fi
}

# Render the failure block collected by seclog_collect_failures.
seclog_print_failures() {
    local count epoch ip user
    if [[ -n ${SECLOG_FAIL_ROWS:-} ]]; then
        seclog_heading "$C_RED" \
            "⚠ Failed SSH attempts ($FAIL_LOOKBACK): $SECLOG_FAIL_TOTAL from $SECLOG_FAIL_IPS IP(s)"
        while IFS='|' read -r count epoch ip user; do
            [[ -n $ip ]] || continue
            printf '  %3dx  %-16s  %-20s  user=%s\n' "$count" "$(seclog_fmt_short "$epoch")" "$ip" "$user"
        done <<<"$SECLOG_FAIL_ROWS"
    elif seclog_journal_restricted; then
        seclog_heading "$C_YEL" "Failed SSH attempts ($FAIL_LOOKBACK): unavailable (needs journal access)"
    else
        seclog_heading "$C_YEL" "Failed SSH attempts ($FAIL_LOOKBACK): none"
    fi
}

# ──────────────────────────────────────────────────────────── full report ──

seclog_collect_report() {
    seclog_collect_connections
    seclog_collect_logins 5
    seclog_collect_failures
}

# The complete terminal report shared by `seclog` and the login banner.
seclog_print_report() {
    seclog_collect_report
    seclog_print_connections
    seclog_print_logins
    seclog_print_failures
}

# The same report as one JSON document, for other tools.
seclog_print_report_json() {
    seclog_collect_report

    local sep dir peer port process count users epoch user ip readable=true
    seclog_journal_restricted && readable=false

    printf '{\n'
    printf '  "version": %s,\n' "$(seclog_json_str "$SECLOG_VERSION")"
    printf '  "host": %s,\n' "$(seclog_json_str "$HOSTNAME")"
    printf '  "generated": %s,\n' "$(seclog_json_str "$(seclog_fmt_iso -1)")"
    printf '  "journal_readable": %s,\n' "$readable"

    printf '  "connections": {\n    "total": %d,\n    "rows": [' "${SECLOG_CONN_TOTAL:-0}"
    sep=""
    while IFS=$'\t' read -r dir peer port process count; do
        [[ -n $dir ]] || continue
        seclog_geo_lookup "$peer"
        users=""
        [[ $dir == IN ]] && users="$(seclog_users_from "$peer")"
        printf '%s\n      {"direction": %s, "peer": %s, "port": %d, "process": %s, "count": %d, "geo": %s, "users": %s}' \
            "$sep" "$(seclog_json_str "${dir,,}")" "$(seclog_json_str "$peer")" "$port" \
            "$(seclog_json_str "$process")" "$count" "$(seclog_json_str "$SECLOG_GEO")" \
            "$(seclog_json_str "$users")"
        sep=","
    done <<<"${SECLOG_CONN_ROWS:-}"
    printf '\n    ]\n  },\n'

    printf '  "logins": ['
    sep=""
    while IFS='|' read -r epoch user ip; do
        [[ -n $ip ]] || continue
        seclog_geo_lookup "$ip"
        printf '%s\n    {"time": %s, "epoch": %d, "user": %s, "ip": %s, "geo": %s}' \
            "$sep" "$(seclog_json_str "$(seclog_fmt_iso "$epoch")")" "$epoch" \
            "$(seclog_json_str "$user")" "$(seclog_json_str "$ip")" "$(seclog_json_str "$SECLOG_GEO")"
        sep=","
    done <<<"${SECLOG_LOGIN_ROWS:-}"
    printf '\n  ],\n'

    printf '  "failures": {\n    "lookback": %s,\n    "total": %d,\n    "distinct_ips": %d,\n    "rows": [' \
        "$(seclog_json_str "$FAIL_LOOKBACK")" "${SECLOG_FAIL_TOTAL:-0}" "${SECLOG_FAIL_IPS:-0}"
    sep=""
    while IFS='|' read -r count epoch ip user; do
        [[ -n $ip ]] || continue
        seclog_geo_lookup "$ip"
        printf '%s\n      {"count": %d, "last": %s, "epoch": %d, "ip": %s, "user": %s, "geo": %s}' \
            "$sep" "$count" "$(seclog_json_str "$(seclog_fmt_iso "$epoch")")" "$epoch" \
            "$(seclog_json_str "$ip")" "$(seclog_json_str "$user")" "$(seclog_json_str "$SECLOG_GEO")"
        sep=","
    done <<<"${SECLOG_FAIL_ROWS:-}"
    printf '\n    ]\n  }\n}\n'
}
