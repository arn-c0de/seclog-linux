# seclog-linux

![Platform](https://img.shields.io/badge/platform-Linux-0f172a)
![Language](https://img.shields.io/badge/language-Bash-22c55e)
![Init](https://img.shields.io/badge/init-systemd%20user-2563eb)
![Architecture](https://img.shields.io/badge/architecture-x86__64%20%7C%20ARM64-7c3aed)
![License](https://img.shields.io/badge/license-MIT-f59e0b)

Lightweight SSH login observability for Linux servers. Sends a rich push
notification via [ntfy](https://ntfy.sh) on every SSH login and failed
attempt, and shows a live security banner at login time.

`seclog-linux` uses a unified push model: successful interactive SSH logins
and failed authentication events both end up in the same ntfy topic, so you
have one notification stream for SSH visibility instead of separate tooling.

## What you get

On every successful SSH login, the user sees a colored banner:

```
── All active connections (4) ──
  [IN ]  192.168.1.100 -> :2222
         app: sshd-session  |  [LAN]  |  alice

  [OUT]  203.0.113.55:443
         app: curl  |  US, United States (3x)

  [OUT]  192.168.1.50:8080
         app: python3  |  [LAN]

── Last 5 successful logins (distinct IPs) ──
  Apr 18 19:46:12   alice        192.168.1.100     [LAN]
  Apr 18 18:22:01   alice        203.0.113.55      US, United States
  ...

── ⚠ Failed SSH attempts (24 hours ago): 37 from 4 IP(s) ──
   23x  Apr 18 03:14:00  45.134.26.12          user=root
    8x  Apr 17 22:01:15  91.200.12.3           user=admin
  ...
```

The active connections section shows **all** established TCP connections, not
just SSH — grouped by app and remote target, with direction (`IN`/`OUT`) and
country via a local GeoIP database. Private IP ranges are labelled `[LAN]`
without a lookup. Multiple connections to the same destination are collapsed
into one line with a repeat count.

And a push to your phone:

```
SSH login: alice@myserver from 192.168.1.100
──────────────────────────────────────────
User:   alice (uid=1000) (sudo)
From:   192.168.1.100:54123
Host:   laptop.local
Auth:   publickey ED25519
Key:    SHA256:pbtcot6DtoyQGtTk...
TTY:    pts/0
Groups: alice,sudo,docker,...

Active sessions: 2 (192.168.1.100,203.0.113.55)
Failed 24h: 37 from 4 IP(s)

Time:   2026-04-18 19:46:12 CEST
```

On every **failed** login, a separate push fires (rate-limited to one per
source-IP per 5 minutes so a brute-force flood won't spam your phone).

## Components

| File | What it does |
|------|--------------|
| `bin/seclog-login` | Started from `.bashrc` on SSH login. Prints the banner and sends the login push. |
| `bin/seclog-monitor` | Long-running daemon. Tails `journalctl` for failed SSH events and pushes them. |
| `bin/seclog` | CLI command — prints the same banner on demand, without sending a push. |
| `bin/seclog-update` | Pulls the newest commit for your checked-out branch and re-runs the installer. |
| `bin/seclog-restart` | Reloads systemd user units and restarts the failed-login monitor service. |
| `bin/seclog-diagnose` | Health check for dependencies, config, permissions and the monitor service. |
| `bin/seclog-lib.sh` | Shared library: config loading, journal access, geo-lookup, report rendering, ntfy push. |
| `systemd/seclog-monitor.service` | User-level systemd unit that supervises the daemon. |
| `ntfy/server.yml.example` | Recommended hardened config for self-hosted ntfy. |

## Management commands

If you installed `seclog-linux` from a git checkout, two helper commands are
available after `./install.sh`:

- `seclog-update`: fetches the newest commit for the **currently checked-out branch**,
  shows your current and target commit, asks for confirmation only when an
  update is available, then runs the update, re-runs `install.sh` and sends a
  push notification about the applied update.
- `seclog-restart`: reloads user systemd units and restarts the failed-login
  monitor service.

Example update flow:

```bash
cd ~/Projects/seclog-linux
seclog-update
```

Typical output:

```text
== seclog-update ==
Repo:    /home/you/Projects/seclog-linux
Branch:  1.0.1
Remote:  https://github.com/arn-c0de/seclog-linux.git
Current: abc1234
Target:  def5678
Message: Harden seclog-update trust boundaries
Verify:  commit signature required
VERIFIED: yes
Signer:   arn-c0de@protonmail.com with ED25519 key SHA256:CTFPPmCdjzltcUEfz5uJvfLrKuj6vJzveU/kfk6Gvlo
Update:  available
Proceed with update? [y/N]
```

- Press `y` or `Y` to continue.
- Any other key or an empty input aborts the update.
- If `Current` and `Target` are identical, `seclog-update` exits without
  re-running the installer.
- After a successful update, `seclog-update` sends a push with host, source IP,
  branch, old commit, new commit, commit text and timestamp.
- The terminal output also shows the target commit text, and on an already
  current checkout it prints the current commit hash together with its subject.
- If signature verification is enabled, the terminal output also shows an
  explicit `VERIFIED: yes` line and the signer identity for the target commit.
- By default, `seclog-update` only allows the expected repo checkout at
  `~/Projects/seclog-linux` and only if `origin` matches the official repo
  remote. You must opt in explicitly to use a custom checkout path.

To just restart the daemon after config changes:

```bash
seclog-restart
```

## Unified push model

The project intentionally combines two different event sources into one push
channel:

- Successful SSH login: handled in the background via `bin/seclog-monitor`
- Failed SSH authentication: handled in the background via `bin/seclog-monitor`
- The login banner you see in the terminal: `bin/seclog-login`, from `.bashrc`

Both notifications come from the monitor on purpose. The `.bashrc` hook only
ever runs for interactive bash, so `scp`, `sftp`, `rsync`, `ssh host cmd` and
any other login shell would log in without a word. The monitor reads the
journal and therefore sees every one of them. Set `LOGIN_PUSH_SOURCE="banner"`
if you cannot run the user service and accept that gap.

That gives you one consistent notification stream in ntfy:

- successful login events include session context, auth method, SSH key fingerprint and recent security summary
- failed login events include source IP, attempted username and rate-limited alerting during brute-force noise

This is useful when you want one topic, one mobile subscription and one alert
history for everything related to SSH access.

## Requirements

- Linux with `systemd` + `journalctl`
- `bash`, `curl`, `awk`, `ss`, `who`, `getent` (all part of any typical server install)
- An ntfy instance — either the public `https://ntfy.sh` or a self-hosted one
- **Optional:** `geoip-bin` + `geoip-database` for country lookup in the active connections banner

  ```bash
  sudo apt install geoip-bin geoip-database
  ```

  Without these packages the geo column is simply omitted — everything else works normally.

## Quickstart

If you already have a working ntfy topic, this is enough:

```bash
git clone git@github.com:arn-c0de/seclog-linux.git
cd seclog-linux
./install.sh
```

Then edit:

```bash
~/.config/seclog-linux/config
```

Minimum config:

```bash
NTFY_URL="https://ntfy.example.com/your-topic"
NTFY_TOKEN=""
```

Finally:

```bash
seclog
exit
ssh your-user@your-server
```

`seclog` shows the current banner locally. Reconnecting via SSH triggers the
login banner and sends the push notification.

## Install (per-user, no sudo needed)

```bash
git clone git@github.com:arn-c0de/seclog-linux.git
cd seclog-linux
./install.sh
```

The installer will:

1. Copy scripts to `~/.local/bin/`
2. Write a default config to `~/.config/seclog-linux/config` (on first run)
3. Hook your `.bashrc` to run `seclog-login` on SSH logins
4. Drop a systemd user unit at `~/.config/systemd/user/seclog-monitor.service`
   and enable it

Then edit `~/.config/seclog-linux/config`:

```bash
NTFY_URL="https://ntfy.example.com/your-topic"
NTFY_TOKEN=""  # only if your ntfy needs auth
```

Re-login via SSH — you should see the banner and get a push.

If you installed from a git checkout and want to update later:

```bash
SECLOG_REPO_DIR="$PWD" seclog-update
```

If your checkout lives at `~/Projects/seclog-linux`, `seclog-update` works without
setting `SECLOG_REPO_DIR`.

`seclog-update` always works on the currently checked-out branch. It asks for
confirmation before applying a real update, exits immediately if the checkout
is already current, and sends an ntfy push after a successful update.

## Configuration

The installer creates this file on first run:

```bash
~/.config/seclog-linux/config
```

Available settings:

```bash
# Full ntfy topic URL. Plaintext http:// is refused for anything outside the
# local network — the push profiles this host and the token rides along.
NTFY_URL="https://ntfy.example.com/YOUR_TOPIC"

# Optional bearer token for protected ntfy instances
NTFY_TOKEN=""

# Accept plaintext HTTP to a non-local address anyway (VPN, tunnel, ...)
NTFY_ALLOW_PLAINTEXT=0

# Who announces a successful login: monitor | banner | both
LOGIN_PUSH_SOURCE="monitor"

# Seconds to collapse repeated logins from the same account and address
LOGIN_DEDUP_WINDOW=60

# How far back the login banner should summarize failed attempts
FAIL_LOOKBACK="24 hours ago"

# Failed-login push rate-limit per source IP in seconds
FAIL_RATELIMIT_WINDOW=300

# Max seconds to spend reading journal data during interactive SSH login (0 = no limit)
JOURNAL_TIMEOUT=2

# Seconds to wait for ntfy before giving up on a push
NTFY_TIMEOUT=5

# Days of silence after which an IP's rate-limit state file is discarded
STATE_TTL_DAYS=7

# Push payload detail level: minimal or full
PUSH_METADATA_LEVEL="minimal"

# Allow seclog-update to use a custom SECLOG_REPO_DIR
ALLOW_CUSTOM_REPO_DIR=0

# Expected origin remotes for seclog-update
EXPECTED_UPDATE_ORIGIN="https://github.com/arn-c0de/seclog-linux.git"
EXPECTED_UPDATE_ORIGIN_ALT="git@github.com:arn-c0de/seclog-linux.git"

# Identity the update commit must be signed by. Required for --yes.
UPDATE_SIGNER=""
```

The config is *sourced* by every command, so it runs as shell code, and it
holds the update trust settings. seclog refuses to start if it is writable by
anyone but you; the installer keeps it at `0600` in a `0700` directory.

What the settings do:

- `NTFY_URL`: Full topic endpoint including server and topic path. Must be `https://` unless the host is on the local network.
- `NTFY_TOKEN`: Optional token for authenticated ntfy servers. It is handed to curl through a config file rather than the command line, so it does not appear in `/proc/<pid>/cmdline`.
- `NTFY_ALLOW_PLAINTEXT`: Set to `1` to permit plaintext HTTP to a non-local address. Only sensible when the path is protected some other way.
- `LOGIN_PUSH_SOURCE`: `monitor` (default) announces every login including non-interactive ones; `banner` only interactive bash; `both` sends two pushes per interactive login.
- `LOGIN_DEDUP_WINDOW`: Collapses repeated logins from the same account and address, so a loop of `scp` calls is not a notification storm.
- `FAIL_LOOKBACK`: Human-readable window shown in the banner, for example `1 hour ago` or `7 days ago`.
- `FAIL_RATELIMIT_WINDOW`: Prevents push spam during brute-force attempts.
- `JOURNAL_TIMEOUT`: Caps how long the login banner waits on `journalctl` before continuing. `0` disables the timeout. The old name `LOGIN_JOURNAL_TIMEOUT` is still accepted.
- `NTFY_TIMEOUT`: Caps how long a push may take before it is abandoned.
- `STATE_TTL_DAYS`: How long per-IP rate-limit state is kept in `~/.cache/seclog-linux`.
- `PUSH_METADATA_LEVEL`: Set to `minimal` to omit UID, groups, reverse-DNS host, TTY and SSH key fingerprint from login pushes.
- `ALLOW_CUSTOM_REPO_DIR`: Keeps `seclog-update` pinned to `~/Projects/seclog-linux` unless you explicitly allow another checkout path.
- `EXPECTED_UPDATE_ORIGIN` / `EXPECTED_UPDATE_ORIGIN_ALT`: `seclog-update` aborts if `origin` does not match one of these remotes.
- `UPDATE_SIGNER`: The identity the update commit must be signed by. Leave it empty and any identity your git trust store accepts can ship you code; `seclog-update --yes` refuses to run without it. See `SECURITY.md`.

`PUSH_METADATA_LEVEL` changes the login push payload like this:

- `full`: includes username, UID, sudo hint, client IP/port, reverse-DNS host,
  auth method, key type, SSH key fingerprint, TTY, groups, active session
  summary, failed-attempt summary and timestamp.
- `minimal`: keeps only username, sudo hint, client IP/port, auth method,
  active session summary, failed-attempt summary and timestamp.

This setting affects the **interactive SSH login push**. It does not change the
failed-login alert format or the update notification sent by `seclog-update`.

`seclog-update` sends a separate management push after a real update with:

- hostname of the machine that ran the update
- detected local source IP of that machine
- branch name
- previous commit
- new commit
- commit text / subject line
- timestamp

Example update push:

```text
seclog updated on raspberrypi: Show commit text in seclog-update output

Host:    raspberrypi
IP:      192.168.178.244
Branch:  1.0.1
From:    5b05d66
To:      78a6287
Commit:  Show commit text in seclog-update output
Time:    2026-04-18 21:12:00 CEST
```

Security behavior of `seclog-update`:

- It changes into the repository using `cd --` and resolves the canonical path first.
- It runs the installer via the absolute path inside the checked-out repository.
- It refuses updates from unexpected `origin` remotes.
- It refuses a custom `SECLOG_REPO_DIR` unless `ALLOW_CUSTOM_REPO_DIR=1` is set.
- **Commit signature verification is mandatory.** `seclog-update` always runs
  `git verify-commit` on the target commit and aborts if verification fails or
  the signer cannot be identified. There is no opt-out.

To use signed-update verification in practice:

1. Configure your local repo to sign commits with a trusted key.
2. Put the matching public key into an `allowed_signers` file on the target host.
3. Run `seclog-update`. It aborts unless `git verify-commit` succeeds for the target commit.

For the full trust model, threat boundaries and limits of this mechanism, see
[SECURITY.md](SECURITY.md).

For SSH signing, an `allowed_signers` line looks like this:

```text
arn-c0de@protonmail.com ssh-ed25519 AAAA...
```

## Typical workflow

1. Install the project with `./install.sh`.
2. Configure `NTFY_URL` and optionally `NTFY_TOKEN`.
3. Run `seclog` to check local output.
4. Run `seclog-restart` if you changed the config while the failed-login monitor was already running.
5. Reconnect via SSH to verify the interactive login banner and login push.
6. Trigger one intentionally failed SSH login from another machine to verify the failed-login alert path.
7. Later, update the installed checkout with `seclog-update`.

## Persistent daemon across logout

The failed-login monitor runs under your **user** systemd. By default it stops
when your last session ends. For 24/7 operation, enable lingering **once**:

```bash
sudo loginctl enable-linger "$USER"
```

## Self-hosted ntfy (strongly recommended)

**Do not use the public `ntfy.sh` server for seclog-linux.**

Every login push contains your username, UID, group membership, client IP,
reverse-DNS hostname, SSH key fingerprint and TTY. Sending that to a
third-party server means:

- A public ntfy topic is readable by anyone who knows the topic name.
- Even a token-protected topic sends your payload through infrastructure you
  do not control, where it may be logged or retained.
- In the event of a breach or data request, your SSH access patterns and
  device fingerprints are exposed.

Run ntfy on a machine you own — a Raspberry Pi on your LAN is enough:

```bash
docker run -d --name ntfy \
  -v /path/to/ntfy-data:/var/lib/ntfy \
  -p 2586:80 \
  binwiederhier/ntfy serve --config /etc/ntfy/server.yml
```

See `ntfy/server.yml.example` for a hardened config with
`auth-default-access: deny-all` and sensible rate limits.

Create a user and token:

```bash
docker exec -it ntfy ntfy user add --role=admin admin
docker exec ntfy ntfy token add admin
```

Set the resulting `tk_…` token as `NTFY_TOKEN` in `~/.config/seclog-linux/config`
and point `NTFY_URL` at your own instance. Keep ntfy behind a TLS reverse proxy
(nginx, Caddy) if you expose it outside your LAN.

## Verification

Use these checks after installation:

Check that the CLI works:

```bash
seclog
seclog "1 hour ago"
```

Check that the user service is active:

```bash
systemctl --user status seclog-monitor
```

Reload and restart the service after config edits:

```bash
seclog-restart
```

Check recent daemon logs:

```bash
journalctl --user -u seclog-monitor -n 50
```

Check that the ntfy endpoint itself accepts a message:

```bash
curl -fsS -d "test from seclog-linux" "$NTFY_URL"
```

For token-protected ntfy:

```bash
curl -fsS -H "Authorization: Bearer $NTFY_TOKEN" \
  -d "test from seclog-linux" "$NTFY_URL"
```

Then verify the two real event paths:

- Successful login: reconnect via SSH and confirm you see the banner and receive a push.
- Failed login: from another machine, run `ssh nosuchuser@YOUR_SERVER` and confirm you receive a failed-login push.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `seclog` shows data, but no push arrives | Run `seclog-diagnose`, then `journalctl -t seclog-linux -n 20` — every push and every failure is recorded there. |
| `push REFUSED ... plaintext HTTP` | `NTFY_URL` is `http://` to a non-local host. Use `https://` or set `NTFY_ALLOW_PLAINTEXT=1`. |
| `refusing to source ... config` | `chmod 600 ~/.config/seclog-linux/config` and `chmod 700` its directory. |
| `seclog-update` always aborts | Signature verification is not configured. See "Signed update verification" in `SECURITY.md`. |
| `curl` or seclog gets `403 forbidden` from ntfy | Your ntfy server requires auth and `NTFY_TOKEN` is missing or invalid. Put a valid `tk_...` token into `~/.config/seclog-linux/config`, then run `seclog-restart`. |
| Login banner does not appear on SSH | `.bashrc` only runs for interactive shell sessions. Test with `ssh -t host`. |
| Failed-login pushes do not arrive | Check `systemctl --user status seclog-monitor` and `journalctl --user -u seclog-monitor -n 50`. |
| Login history or failed-attempt summaries stay empty | Your user may not be allowed to read system SSH logs. On affected distros, add the user to `systemd-journal`, then log out and back in: `sudo usermod -aG systemd-journal "$USER"` |
| Failed-login monitor stops after logout | Run `sudo loginctl enable-linger "$USER"` once. |
| Public `ntfy.sh` works, but you are leaking too much metadata | Use a self-hosted ntfy server. The payload includes username, client IP, group membership and SSH key fingerprint. |
| The service starts, but sees no failures | Verify that your distro logs SSH failures to `journalctl` for `sshd` or `sshd-session`. |

## Files and behavior

The project separates interactive login handling from background monitoring:

- `bin/seclog-login`: Runs from `.bashrc` on interactive SSH logins.
- `bin/seclog-monitor`: Watches the journal continuously and pushes failed-login events.
- `bin/seclog`: Prints the security summary without sending a push.
- `bin/seclog-update`: Updates a git checkout on its current branch, asks for confirmation when needed, re-runs `install.sh`, then sends an ntfy update push with host/IP, commit change and commit text.
  It also validates the repo path and expected `origin`, and can optionally verify commit signatures.
- `bin/seclog-restart`: Reloads and restarts the failed-login monitor user service after config or unit changes.
- `systemd/seclog-monitor.service`: Keeps the failed-login monitor alive as a user service.

This means:

- `ssh host`, opening a normal shell: banner + login push.
- `ssh host command`, `scp`, `sftp`: usually no banner, because `.bashrc` is not used for a normal interactive shell.
- Failed SSH attempts: handled by the daemon through the journal, independent of interactive shell startup.

## Uninstall

```bash
./uninstall.sh
```

Removes the scripts, the systemd unit, and the `.bashrc` hook. Leaves your
config and state cache untouched.

## Security notes

- **Every** login is announced, not just interactive ones. `seclog-monitor`
  reads the journal, so `ssh host cmd`, `scp`, `sftp`, `rsync` and non-bash
  shells are covered too. That only holds while the user service runs — enable
  lingering (`sudo loginctl enable-linger "$USER"`) so it survives logout.
- Pushes are **refused over plaintext HTTP** to anything outside the local
  network. The body profiles the machine and the token travels with it. Use
  TLS, or set `NTFY_ALLOW_PLAINTEXT=1` if the path is protected another way.
- The token, URL and body never appear in `curl`'s command line, because
  `/proc/<pid>/cmdline` is readable by every other local account.
- The config is sourced as shell code and carries the update trust settings, so
  seclog refuses to run if it is writable by anyone but you.
- `PUSH_METADATA_LEVEL` defaults to `minimal`. `full` adds uid, groups,
  reverse-DNS and the SSH key fingerprint — useful when investigating, but on a
  public ntfy topic it hands a stranger a map of the machine.
- The SSH key *fingerprint* in a `full` push is a SHA256 of the **public** key —
  it cannot be used to impersonate you. It is useful as an authenticity anchor:
  a fingerprint you do not recognise means an unknown device logged in.
- Log parsing treats the attempted user name as hostile. It is attacker chosen
  and sshd only escapes control characters, so seclog reads the peer address
  from the end of the line and the account name positionally — otherwise a name
  like `x from 203.0.113.9 port 1` could forge the reported source and silence
  the rate limiter. See `SECURITY.md`.
- Failed-login pushes are rate limited to one per source IP per five minutes
  (`FAIL_RATELIMIT_WINDOW`), so a brute-force run cannot flood your phone.
  Suppressed attempts are counted and reported in the next push.
- Every push attempt and every failure is written to the journal under the tag
  `seclog-linux` (`journalctl -t seclog-linux`). The journal is not writable by
  the monitored account, so that record survives an account takeover — but
  future notifications do not. seclog runs as the user it watches and cannot
  defend against someone who already holds that account; see the threat model
  in `SECURITY.md`.

## Security contact

If you want to report a vulnerability, do not open a public issue first.
See [SECURITY.md](SECURITY.md) and contact `arn-c0de@protonmail.com`.

## License

MIT — see `LICENSE`.
