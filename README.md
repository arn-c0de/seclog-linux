# seclog-linux

![Platform](https://img.shields.io/badge/platform-Linux-0f172a)
![Language](https://img.shields.io/badge/language-Bash%205-22c55e)
![Init](https://img.shields.io/badge/init-systemd%20user-2563eb)
![Architecture](https://img.shields.io/badge/architecture-x86__64%20%7C%20ARM64-7c3aed)
![License](https://img.shields.io/badge/license-MIT-f59e0b)

Lightweight SSH login observability for Linux servers. Sends a push
notification via [ntfy](https://ntfy.sh) on every SSH login and every failed
attempt, and shows a live security banner when you log in. Runs entirely as
your own user: no root, no agents, one systemd user service.

## What you get

On every interactive SSH login, a banner:

```
── All active connections (4) ──
  [IN ]  192.168.1.100 -> :2222
         app: sshd-session  |  [LAN]  |  alice

  [OUT]  203.0.113.55:443
         app: curl  |  US, United States  |  3x

── Last 5 successful logins (distinct IPs) ──
  Apr 18 19:46:12   alice        192.168.1.100     [LAN]
  Apr 18 18:22:01   alice        203.0.113.55      US, United States

── ⚠ Failed SSH attempts (24 hours ago): 37 from 4 IP(s) ──
   23x  Apr 18 03:14:00  45.134.26.12          user=root
    8x  Apr 17 22:01:15  91.200.12.3           user=admin
```

The connections block shows **all** established TCP connections, grouped by
app and remote target, with direction and country. Private ranges are
labelled `[LAN]` without a lookup.

On every login, a push:

```
SSH login: alice from 192.168.1.100
User:   alice
From:   192.168.1.100:51234
Auth:   publickey
Origin: [LAN]
Host:   myserver
Time:   2026-09-04 19:46:12 CEST
```

On failed attempts, a push per source IP, rate limited so a brute-force run
becomes a handful of notifications with a "suppressed since last push" count
instead of thousands.

## How it works

| Piece | Role |
|---|---|
| `seclog-monitor` | User service. Follows `journalctl -f -o json` for `sshd` / `sshd-session`, parses events in one long-lived awk, rate limits, pushes. Saves the journal cursor after every event, so a restart resumes where it stopped. |
| `seclog-login` | Started from `.bashrc` on interactive SSH logins. Prints the banner. Only sends the push if you tell it to (`LOGIN_PUSH_SOURCE`). |
| `seclog` | CLI: `status` (the banner, on demand, no push), `diagnose`, `update`, `restart`, `test-push`. |
| `seclog-lib.sh` | Shared library: config parser, journal access, sshd line parser, geo lookup, report renderers, ntfy push. |
| `seclog-monitor.service` | Hardened systemd user unit. |

Successful logins are announced by the **monitor**, not the banner. The
`.bashrc` hook only runs for interactive bash; `scp`, `sftp`, `rsync`,
`ssh host cmd` and any other shell would log in silently. The monitor reads
the journal and sees all of them.

## Requirements

- Linux with systemd and a readable system journal
- bash 5, curl, awk, `ss`, `who`, `getent`
- An ntfy instance, ideally [self-hosted](#self-hosted-ntfy)
- Optional, for country names: `mmdblookup` (Debian: `mmdb-bin`) with a
  GeoLite2 database in `/var/lib/GeoIP` or `/usr/share/GeoIP`, or the legacy
  `geoip-bin` + `geoip-database`. Without either the geo column reads
  `(unknown)`.

## Quickstart

```bash
git clone https://github.com/arn-c0de/seclog-linux.git ~/Projects/seclog-linux
cd ~/Projects/seclog-linux
./install.sh
```

Edit `~/.config/seclog-linux/config`:

```
NTFY_URL="https://ntfy.example.com/ssh-login"
NTFY_TOKEN="tk_..."          # only if your server needs it
```

Then:

```bash
seclog restart               # pick up the config
seclog diagnose              # every check, plus one test push
sudo loginctl enable-linger "$USER"   # keep the monitor alive after logout
```

Reconnect via SSH: you see the banner and get a push. Try `ssh nosuchuser@host`
from another machine to see a failure push.

The installer copies the commands to `~/.local/bin`, writes the config on the
first run (never overwrites it), installs bash completion, appends a one-line
hook to `~/.bashrc`, and enables the user service. It is safe to re-run.

## Commands

```
seclog [status] [--json] [lookback]   report for this machine, no push
seclog diagnose [--no-push]           dependencies, config, permissions, service, update trust
seclog update [--yes] [--channel C]   signed update of the git checkout
seclog restart                        reload units, restart the monitor
seclog test-push [message]            low-priority test notification
seclog version
```

The `seclog-diagnose`, `seclog-update` and `seclog-restart` names still work.

`seclog "1 hour ago"` changes the failed-attempt window for one run. Any
`journalctl --since` expression is accepted.

`seclog status --json` prints the same three blocks as JSON:

```json
{
  "version": "1.0.3",
  "host": "myserver",
  "generated": "2026-09-04T19:46:12+0200",
  "journal_readable": true,
  "connections": { "total": 4, "rows": [ { "direction": "in", "peer": "192.168.1.100", "port": 22, "process": "sshd-session", "count": 1, "geo": "[LAN]", "users": "alice" } ] },
  "logins": [ { "time": "2026-09-04T19:46:12+0200", "epoch": 1757007972, "user": "alice", "ip": "192.168.1.100", "geo": "[LAN]" } ],
  "failures": { "lookback": "24 hours ago", "total": 37, "distinct_ips": 4, "rows": [ { "count": 23, "last": "2026-09-04T03:14:00+0200", "epoch": 1756948440, "ip": "45.134.26.12", "user": "root", "geo": "RU, Russia" } ] }
}
```

## Configuration

`~/.config/seclog-linux/config` is a plain `KEY=value` file: optional quotes,
`#` comments, no shell. It is parsed, never executed, so `$VAR` and `$(...)`
are taken literally. Unknown keys are reported and ignored. Because it holds
the ntfy token and the update trust settings, seclog refuses to start if the
file is writable by group or others; the installer keeps it at `0600`.

Every key, with its default and a description, is in
[`config/config.example`](config/config.example). The short version:

| Key | Default | What it does |
|---|---|---|
| `NTFY_URL` | placeholder | Full topic URL. `https://` unless the host is on the LAN. |
| `NTFY_TOKEN` | empty | Bearer token for authenticated servers. |
| `NTFY_ALLOW_PLAINTEXT` | `0` | Permit plaintext HTTP to a non-local host (VPN, tunnel). |
| `NTFY_TIMEOUT` | `5` | Seconds before a push is abandoned. |
| `PUSH_METADATA_LEVEL` | `minimal` | `full` adds uid, groups, rDNS, key fingerprint, TTY to the banner push. |
| `LOGIN_PUSH_SOURCE` | `monitor` | Who announces logins: `monitor`, `banner`, `both`. |
| `LOGIN_DEDUP_WINDOW` | `60` | Collapse repeated logins from the same account and address. |
| `BANNER_EXTRA_FILE` | empty | Text file printed after the banner (your own admin hints). |
| `FAIL_LOOKBACK` | `24 hours ago` | Failed-attempt window in the report. |
| `JOURNAL_TIMEOUT` | `2` | Seconds the banner waits for journald; `0` disables. |
| `GEOIP_DB` | auto | Path to a GeoLite2 `.mmdb`. |
| `FAIL_RATELIMIT_WINDOW` | `300` | One failure push per source IP per window. |
| `STATE_TTL_DAYS` | `7` | Drop rate-limit state for IPs silent this long. |
| `REPLAY_MAX_AGE` | `3600` | When catching up after downtime, older events are counted, not pushed. |
| `UPDATE_CHANNEL` | `release` | `release` = signed `vX.Y.Z` tags, `branch` = signed branch tip. |
| `SECLOG_REPO_DIR` | `~/Projects/seclog-linux` | Where the checkout lives. |
| `ALLOW_CUSTOM_REPO_DIR` | `0` | Required to use a `SECLOG_REPO_DIR` other than the default. |
| `EXPECTED_UPDATE_ORIGIN[_ALT]` | this repo | `origin` must match one of them. |
| `UPDATE_SIGNER` | empty | Identity the release must be signed by. Required for `--yes`. |

After editing, run `seclog restart`.

## Updating

`seclog update` fetches, shows the current and target commit, verifies the
signature, asks, then fast-forwards, re-runs `install.sh`, restarts the
monitor and sends a push about the update.

```text
== seclog-update ==
Repo:    /home/you/Projects/seclog-linux
Branch:  main
Remote:  https://github.com/arn-c0de/seclog-linux.git
Channel: release
Current: b5bcc93 (security: close the alert-evasion, transport and update-trust gaps)
Target:  3f1c2aa (seclog-linux 1.0.3) [tag v1.0.3]
VERIFIED: yes (arn-c0de@protonmail.com, matches UPDATE_SIGNER)
Proceed with update? [y/N]
```

- **Verification is mandatory.** In the `release` channel the tag must be an
  annotated tag with a good signature (`git verify-tag`); in the `branch`
  channel the commit must be signed (`git verify-commit`). There is no
  opt-out. "Exit status 0" from gpg alone is not accepted: the signer identity
  has to be reported, and if `UPDATE_SIGNER` is set it has to match.
- `seclog update --yes` for unattended runs requires `UPDATE_SIGNER`.
- The checkout must be at `~/Projects/seclog-linux` unless
  `ALLOW_CUSTOM_REPO_DIR=1` and `SECLOG_REPO_DIR` are set. `origin` must match
  the expected repository.
- The fast-forward goes to the exact commit that was verified, not to
  wherever the ref points by the time the merge runs.

Setting up signature verification on the target host (SSH signatures):

```bash
mkdir -p ~/.config/seclog-linux
printf '%s %s\n' maintainer@example.com "$(cat maintainer_signing_key.pub)" \
    > ~/.config/seclog-linux/allowed_signers
git -C ~/Projects/seclog-linux config gpg.format ssh
git -C ~/Projects/seclog-linux config gpg.ssh.allowedSignersFile ~/.config/seclog-linux/allowed_signers
echo 'UPDATE_SIGNER="maintainer@example.com"' >> ~/.config/seclog-linux/config
```

`seclog diagnose` reports the state of all of this under `[ Update trust ]`.
For the threat model see [SECURITY.md](SECURITY.md); for how releases are cut
see [CHANGELOG.md](CHANGELOG.md).

## The monitor in detail

- One pipeline for its whole lifetime: `journalctl -f -o json` filtered to
  `sshd` and `sshd-session`, one awk that turns each record into a
  tab-separated event, and a bash loop that rate limits and pushes. A
  brute-force burst does not fork per line.
- **Resumes after downtime.** The journal cursor of the last handled event is
  saved in `~/.cache/seclog-linux/journal.cursor`. On start the monitor
  validates it and continues from there, so events during a reboot or an
  update are not lost. Events older than `REPLAY_MAX_AGE` are folded into the
  suppressed counters instead of being pushed.
- **Rate limit:** one failure push per source IP per `FAIL_RATELIMIT_WINDOW`;
  attempts in between are counted and reported in the next push.
- **Dedup:** logins from the same account and address within
  `LOGIN_DEDUP_WINDOW` produce one push (think `rsync` opening many sessions).
- **Attacker-controlled input.** The user name in a failed attempt is chosen
  by the attacker and sshd only escapes control characters. The parser works
  on the bare journal `MESSAGE`, anchors on the first token, reads the account
  positionally and takes the peer from the *last* `<ip> port <n>` pair, so a
  name like `x from 203.0.113.9 port 1` can neither misattribute the alert nor
  pin the rate-limit state on a foreign IP. Names are reduced to
  `[A-Za-z0-9._@-]` and truncated. `tests/parser.bats` pins these guarantees.
- Every push and every failure to push is recorded in the journal under the
  tag `seclog-linux` (`journalctl -t seclog-linux`). The journal is not
  writable by the monitored account, so that record survives an account
  takeover even though future notifications do not.

## Self-hosted ntfy

Do not use the public `ntfy.sh` for this. Every push profiles the host, and on
a public server the topic name is the only thing between the feed and
strangers. A Raspberry Pi on your LAN is enough:

```bash
docker run -d --name ntfy --restart=always \
  -v /path/to/ntfy-data:/etc/ntfy -v /path/to/ntfy-cache:/var/cache/ntfy \
  -p 2586:80 binwiederhier/ntfy serve
docker exec -it ntfy ntfy user add --role=admin admin
docker exec ntfy ntfy token add --expires 0 admin
```

Use [`ntfy/server.yml.example`](ntfy/server.yml.example) as the server
config: `auth-default-access: deny-all` and sane rate limits. Put TLS in front
if it is reachable from outside the LAN; seclog refuses plaintext HTTP to
non-local hosts. [docs/SETUP.md](docs/SETUP.md) walks through it step by step.

## Troubleshooting

| Symptom | Where to look |
|---|---|
| No push arrives | `seclog diagnose`, then `journalctl -t seclog-linux -n 20`. |
| `push REFUSED ... plaintext HTTP` | `NTFY_URL` is `http://` to a non-local host. Use `https://` or `NTFY_ALLOW_PLAINTEXT=1`. |
| `refusing to read ... config` | `chmod 600 ~/.config/seclog-linux/config`, `chmod 700` its directory. |
| `unknown setting X ignored` / `taken literally` | Since 1.0.3 the config is not shell. Write values out; see "Upgrading from 1.0.2 or earlier". |
| `seclog update` says no release tag | The branch has no signed `vX.Y.Z` tag yet. Wait for one or set `UPDATE_CHANNEL=branch`. |
| `seclog update` always aborts on VERIFIED | Signature verification is not set up; see "Updating". |
| Login history and failures stay empty | The account cannot read the system journal: `sudo usermod -aG systemd-journal "$USER"`, re-login. `seclog diagnose` tells you. |
| Banner does not appear | `.bashrc` only runs for interactive shells; `ssh -t host` to test. It also appears once per session only (`SECLOG_BANNER_SHOWN`). |
| Monitor stops after logout | `sudo loginctl enable-linger "$USER"`. |
| Installer says no systemd user session | Log in through a regular session or enable lingering, then `systemctl --user enable --now seclog-monitor`. |
| Geo column says `(unknown)` | No backend. Install `mmdb-bin` plus a GeoLite2 database, or `geoip-bin`. |

## Upgrading from 1.0.2 or earlier

1. **Config.** The file is no longer sourced. Any value that used shell
   syntax (`$HOME`, `$(...)`, backticks) must be written out literally.
   `seclog diagnose` and every command print a warning per offending line.
   `SSH_NOTIFY_CONFIG` and `LOGIN_JOURNAL_TIMEOUT` are gone; use
   `SECLOG_CONFIG` and `JOURNAL_TIMEOUT`.
2. **Updates follow release tags.** Until the branch you follow has a signed
   `vX.Y.Z` tag, `seclog update` stops with a message. Set
   `UPDATE_CHANNEL=branch` to keep the 1.0.2 behaviour.
3. **The banner's "Admin commands" block is gone.** Put your own lines into a
   file and set `BANNER_EXTRA_FILE`.
4. **bash 5** is required.
5. Re-run `./install.sh`: it rewrites the `.bashrc` hook (now with the
   interactivity guard) and installs completion.

## Tests

The suite uses [bats-core](https://github.com/bats-core/bats-core) and needs
no root, network, or real journal:

```bash
bats tests/
```

## Uninstall

```bash
./uninstall.sh
```

Removes the commands, the unit, the completion and the `.bashrc` hook. Config
and state in `~/.config/seclog-linux` and `~/.cache/seclog-linux` are kept.

## Security

seclog runs as the account it watches. It tells you reliably about logins and
failed attempts while that account is not yet compromised; it cannot defend
against someone who already holds it. Pushes are refused over plaintext HTTP
to non-local hosts, the token and body never appear on a command line, and
`PUSH_METADATA_LEVEL` defaults to `minimal`. The full threat model, the update
trust chain and the reporting address are in [SECURITY.md](SECURITY.md).

## License

MIT — see `LICENSE`.
