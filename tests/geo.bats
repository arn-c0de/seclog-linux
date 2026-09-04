#!/usr/bin/env bats
# Geo lookup: backend selection, mmdblookup output parsing, caching.

load test_helper

setup() {
    load_lib
    export COUNTER="$BATS_TEST_TMPDIR/calls"
    : > "$COUNTER"
}

mock_mmdb() {
    mock mmdblookup <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$COUNTER"
cat <<'OUT'

  {
    "geoname_id":
      2921044 <uint32>
    "is_in_european_union":
      true <boolean>
    "iso_code":
      "DE" <utf8_string>
    "names":
      {
        "de":
          "Deutschland" <utf8_string>
        "en":
          "Germany" <utf8_string>
      }
  }

OUT
EOF
}

mock_legacy() {
    mock geoiplookup <<'EOF'
#!/usr/bin/env bash
echo "legacy $*" >> "$COUNTER"
echo "GeoIP Country Edition: US, United States"
EOF
}

@test "mmdblookup output is reduced to 'ISO, Name'" {
    mock_mmdb
    touch "$BATS_TEST_TMPDIR/db.mmdb"
    GEOIP_DB="$BATS_TEST_TMPDIR/db.mmdb"
    [ "$(seclog_geo 203.0.113.9)" = "DE, Germany" ]
    grep -q -- "--file $GEOIP_DB --ip 203.0.113.9 country" "$COUNTER"
}

@test "without a readable database the legacy tool is used" {
    mock_mmdb
    mock_legacy
    GEOIP_DB="$BATS_TEST_TMPDIR/missing.mmdb"
    [ "$(seclog_geo 203.0.113.9)" = "US, United States" ]
    grep -q "^legacy 203.0.113.9" "$COUNTER"
}

@test "private addresses are labelled [LAN] without any lookup" {
    mock_mmdb
    touch "$BATS_TEST_TMPDIR/db.mmdb"
    GEOIP_DB="$BATS_TEST_TMPDIR/db.mmdb"
    [ "$(seclog_geo 192.168.1.5)" = "[LAN]" ]
    [ "$(seclog_geo '[::ffff:10.0.0.1]')" = "[LAN]" ]
    [ ! -s "$COUNTER" ]
}

@test "lookups are cached per process" {
    mock_mmdb
    touch "$BATS_TEST_TMPDIR/db.mmdb"
    GEOIP_DB="$BATS_TEST_TMPDIR/db.mmdb"
    for _ in 1 2 3 4 5; do seclog_geo_lookup 203.0.113.9; done
    seclog_geo_lookup 198.51.100.7
    [ "$(wc -l < "$COUNTER")" -eq 2 ]
    [ "$SECLOG_GEO" = "DE, Germany" ]
}

@test "values that are not IP literals are never handed to the lookup tool" {
    mock_mmdb
    touch "$BATS_TEST_TMPDIR/db.mmdb"
    GEOIP_DB="$BATS_TEST_TMPDIR/db.mmdb"
    [ -z "$(seclog_geo '--file=/etc/passwd')" ]
    [ -z "$(seclog_geo 'evil.example')" ]
    [ ! -s "$COUNTER" ]
}

@test "unknown results render as (unknown)" {
    GEOIP_DB="$BATS_TEST_TMPDIR/missing.mmdb"
    mock mmdblookup <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    [ "$(seclog_geo_or_unknown 203.0.113.9)" = "(unknown)" ]
}
