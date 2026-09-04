# Changelog

All notable changes to seclog-linux. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are
[semver](https://semver.org/) and every release is a signed, annotated git tag
`vX.Y.Z` (see "Releasing" at the end).

## [1.0.3] — unreleased

Contains breaking changes. Read "Upgrading from 1.0.2 or earlier" in the
README before updating.

### Changed — breaking
- **The config file is parsed, not sourced.** Lines are `KEY=value` with
  optional quotes and `#` comments. Nothing in the file is executed any more:
  no `$VAR`, no `$(...)`, no escapes. Unknown keys are reported and ignored.
  A 1.0.2 config that relied on shell expansion needs the values written out.
- **`seclog-update` follows signed release tags by default.** `UPDATE_CHANNEL`
  is `release` (newest `vX.Y.Z` tag reachable from the branch, verified with
  `git verify-tag`) or `branch` (the old behaviour, signed tip of the branch).
- **Requires bash 5** for `$EPOCHSECONDS` and `printf %(...)T`.
- Removed the pre-1.1 compatibility names `SSH_NOTIFY_CONFIG` and
  `LOGIN_JOURNAL_TIMEOUT`, and the installer's migration of the pre-rename
  files (`ssh-login-notify.sh`, `ssh-failed-monitor.sh`,
  `seclog-linux-fail-monitor.service`). `uninstall.sh` still removes them.
- The hard-coded "Admin commands" block in the login banner is gone. Put your
  own text into a file and point `BANNER_EXTRA_FILE` at it.
- The version string is now `1.0.3` and matches the branch; 1.0.2 reported
  itself as `1.1.0`.

### Added
- `seclog` is a single entry point with subcommands: `status` (default),
  `diagnose`, `update`, `restart`, `test-push`, `version`, `help`. The
  `seclog-*` commands keep working.
- `seclog status --json`: the whole report as one JSON document.
- Bash completion for `seclog`, `seclog-update` and `seclog-diagnose`,
  installed to `~/.local/share/bash-completion/completions/`.
- **The monitor resumes where it stopped.** The journal cursor of the last
  handled event is persisted after every event; after a reboot, an update or
  a crash the monitor replays what it missed. Events older than
  `REPLAY_MAX_AGE` (default one hour) are counted but not pushed, so a long
  outage does not end in a notification burst.
- GeoLite2 support through `mmdblookup` (libmaxminddb) with auto-detection in
  `/var/lib/GeoIP` and `/usr/share/GeoIP`, or `GEOIP_DB`. The legacy
  `geoiplookup` remains as fallback. Lookups are cached per process.
- `seclog-diagnose --no-push` runs every check without sending a test push.
- `seclog-update --channel`, `--help`, and a clear message when a release tag
  is a lightweight tag rather than a signed one.
- `BANNER_EXTRA_FILE`, `REPLAY_MAX_AGE`, `GEOIP_DB`, `UPDATE_CHANNEL` and
  `SECLOG_REPO_DIR` as config keys.
- A bats-core test suite under `tests/` covering the sshd parser (including
  forged user names), the config parser, transport policy, curl config
  escaping, geo lookups, the report renderers and the monitor end to end.

### Changed
- The monitor is one long-lived `journalctl -o json | awk | bash` pipeline. A
  brute-force burst used to fork awk, `date`, `hostname` and the geo tool per
  line; now parsing costs one process for the lifetime of the monitor and the
  time and host names come from bash builtins.
- The journal is read as JSON. The parser works on the bare `MESSAGE` field
  and anchors on the first token, so a keyword such as `Accepted` inside an
  attacker-chosen user name can no longer influence the classification.
  Timestamps come from `__REALTIME_TIMESTAMP` and pushes carry the event time
  rather than the processing time.
- `Failed <method> for ...` lines are reported for every method, not only
  `password`.
- The `.bashrc` hook only runs in interactive shells and only once per SSH
  session (`SECLOG_BANNER_SHOWN`). Previously a `.bashrc` without the usual
  interactivity guard printed the banner into `scp` and `rsync` streams, and
  every tmux pane or subshell repeated it. `seclog-login` additionally refuses
  to run when stdout is not a terminal.
- Journal readability is probed (`journalctl --system`) instead of derived
  from membership in `systemd-journal`. Debian and Ubuntu grant access via
  `adm`, which used to trigger a false warning.
- `seclog-login` looks up the session's `Accepted` line with the same
  `sshd`/`sshd-session` matcher as everything else; on older OpenSSH the auth
  method and key fingerprint were always empty.
- `seclog-diagnose` masks the topic in `NTFY_URL` (on a public ntfy server
  the topic is the secret) and reports the geo backend, bash version, update
  channel and cursor state.
- `seclog-update` accepts `origin` URLs with or without a trailing `.git`.
- The installer no longer aborts when there is no systemd user session; it
  explains how to start the service later. It fails early on bash < 5.
- README, SETUP and SECURITY rewritten for 1.0.3; the config reference lives in
  `config/config.example` only.

## [1.0.2] — 2026-08-29

Reported itself as `1.1.0`.

- Security: mandatory commit signature verification with signer pinning
  (`UPDATE_SIGNER`), refusal of plaintext HTTP to non-local ntfy hosts, curl
  options passed via a config file instead of argv, defensive parsing of
  attacker-controlled sshd log fields, config permission checks.
- Refactor: `seclog-*` command layout, shared `seclog-lib.sh`, XDG paths,
  `seclog-diagnose`.
- Login pushes moved to the monitor (`LOGIN_PUSH_SOURCE`), so non-interactive
  logins are announced too.

## [1.0.1] — 2026-05-07
- Install hardening, shared library, `seclog-diagnose`.

## [1.0.0] — 2026-04-18
- Initial release: login banner with active connections and geo lookup,
  failed-login monitor with per-IP rate limiting, ntfy push, `seclog-update`
  and `seclog-restart`.

## Releasing

```bash
# bump SECLOG_VERSION in bin/seclog-lib.sh and this file, commit, then:
git tag -s v1.0.3 -m "seclog-linux 1.0.3"
git push origin 1.0.3 v1.0.3
```

`seclog-update` in its default `release` channel picks up the newest
`vX.Y.Z` tag reachable from the installed branch and verifies the tag's
signature; a lightweight tag is rejected.
