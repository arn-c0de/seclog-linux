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
── Currently active SSH connections (2) ──
  192.168.1.100    54123   alice      2026-04-18 19:46
  203.0.113.55     52401   bob        2026-04-18 19:30

── Last 5 successful logins (distinct IPs) ──
  Apr 18 19:46:12   alice        192.168.1.100
  Apr 18 18:22:01   alice        203.0.113.55
  ...

── ⚠ Failed SSH attempts (24 hours ago): 37 from 4 IP(s) ──
   23x  Apr 18 03:14:00  45.134.26.12          user=root
    8x  Apr 17 22:01:15  91.200.12.3           user=admin
  ...
```

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
| `bin/ssh-login-notify.sh` | Sourced from `.bashrc` on SSH login. Prints the banner and sends the login push. |
| `bin/ssh-failed-monitor.sh` | Long-running daemon. Tails `journalctl` for failed SSH events and pushes them. |
| `bin/seclog` | CLI command — prints the same banner on demand, without sending a push. |
| `bin/seclog-update` | Pulls the newest commit for your checked-out branch and re-runs the installer. |
| `bin/seclog-restart` | Reloads systemd user units and restarts the failed-login monitor service. |
| `systemd/seclog-linux-fail-monitor.service` | User-level systemd unit that supervises the daemon. |
| `ntfy/server.yml.example` | Recommended hardened config for self-hosted ntfy. |

## Unified push model

The project intentionally combines two different event sources into one push
channel:

- Interactive SSH login: handled at shell startup via `bin/ssh-login-notify.sh`
- Failed SSH authentication: handled in the background via `bin/ssh-failed-monitor.sh`

That gives you one consistent notification stream in ntfy:

- successful login events include session context, auth method, SSH key fingerprint and recent security summary
- failed login events include source IP, attempted username and rate-limited alerting during brute-force noise

This is useful when you want one topic, one mobile subscription and one alert
history for everything related to SSH access.

## Requirements

- Linux with `systemd` + `journalctl`
- `bash`, `curl`, `awk`, `ss`, `who`, `getent` (all part of any typical server install)
- An ntfy instance — either the public `https://ntfy.sh` or a self-hosted one

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
NTFY_URL="https://ntfy.sh/your-unique-topic"
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
3. Hook your `.bashrc` to source `ssh-login-notify.sh` on SSH logins
4. Drop a systemd user unit at `~/.config/systemd/user/seclog-linux-fail-monitor.service`
   and enable it

Then edit `~/.config/seclog-linux/config`:

```bash
NTFY_URL="https://ntfy.sh/your-unique-topic"
NTFY_TOKEN=""  # only if your ntfy needs auth
```

Re-login via SSH — you should see the banner and get a push.

If you installed from a git checkout and want to update later:

```bash
SECLOG_REPO_DIR="$PWD" seclog-update
```

If your checkout lives at `~/Projects/seclog-linux`, `seclog-update` works without
setting `SECLOG_REPO_DIR`.

To just restart the user service after config changes:

```bash
seclog-restart
```

## Configuration

The installer creates this file on first run:

```bash
~/.config/seclog-linux/config
```

Available settings:

```bash
# Full ntfy topic URL
NTFY_URL="http://YOUR_NTFY_HOST:2586/YOUR_TOPIC"

# Optional bearer token for protected ntfy instances
NTFY_TOKEN=""

# How far back the login banner should summarize failed attempts
FAIL_LOOKBACK="24 hours ago"

# Failed-login push rate-limit per source IP in seconds
FAIL_RATELIMIT_WINDOW=300
```

What the settings do:

- `NTFY_URL`: Full topic endpoint including server and topic path.
- `NTFY_TOKEN`: Optional token for authenticated ntfy servers.
- `FAIL_LOOKBACK`: Human-readable window shown in the banner, for example `1 hour ago` or `7 days ago`.
- `FAIL_RATELIMIT_WINDOW`: Prevents push spam during brute-force attempts.

## Typical workflow

1. Install the project with `./install.sh`.
2. Configure `NTFY_URL` and optionally `NTFY_TOKEN`.
3. Run `seclog` to check local output.
4. Reconnect via SSH to verify the interactive login banner and login push.
5. Trigger one intentionally failed SSH login from another machine to verify the failed-login alert path.

## Persistent daemon across logout

The failed-login monitor runs under your **user** systemd. By default it stops
when your last session ends. For 24/7 operation, enable lingering **once**:

```bash
sudo loginctl enable-linger "$USER"
```

## Self-hosted ntfy (recommended for sensitive data)

Your push payload contains your username, client IP, SSH key fingerprint and
group membership — don't publish that to the public `ntfy.sh`. Use a
self-hosted ntfy inside your LAN or behind a TLS reverse proxy.

See `ntfy/server.yml.example` for a hardened config: `auth-default-access: deny-all`
plus generous home-server rate limits. Create users and tokens:

```bash
docker exec -it ntfy ntfy user add --role=admin admin
docker exec ntfy ntfy token add admin
```

Use the resulting `tk_…` token as `NTFY_TOKEN` in the config.

## Verification

Use these checks after installation:

Check that the CLI works:

```bash
seclog
seclog "1 hour ago"
```

Check that the user service is active:

```bash
systemctl --user status seclog-linux-fail-monitor
```

Check recent daemon logs:

```bash
journalctl --user -u seclog-linux-fail-monitor -n 50
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
| `seclog` shows data, but no push arrives | `NTFY_URL` wrong, `NTFY_TOKEN` wrong, or ntfy is unreachable. Test with `curl` directly. |
| Login banner does not appear on SSH | `.bashrc` only runs for interactive shell sessions. Test with `ssh -t host`. |
| Failed-login pushes do not arrive | Check `systemctl --user status seclog-linux-fail-monitor` and `journalctl --user -u seclog-linux-fail-monitor -n 50`. |
| Failed-login monitor stops after logout | Run `sudo loginctl enable-linger "$USER"` once. |
| Public `ntfy.sh` works, but you are leaking too much metadata | Use a self-hosted ntfy server. The payload includes username, client IP, group membership and SSH key fingerprint. |
| The service starts, but sees no failures | Verify that your distro logs SSH failures to `journalctl` for `sshd` or `sshd-session`. |

## Files and behavior

The project separates interactive login handling from background monitoring:

- `bin/ssh-login-notify.sh`: Runs from `.bashrc` on interactive SSH logins.
- `bin/ssh-failed-monitor.sh`: Watches the journal continuously and pushes failed-login events.
- `bin/seclog`: Prints the security summary without sending a push.
- `bin/seclog-update`: Updates a git checkout on its current branch and re-runs `install.sh`.
- `bin/seclog-restart`: Reloads and restarts the failed-login monitor user service.
- `systemd/seclog-linux-fail-monitor.service`: Keeps the failed-login monitor alive as a user service.

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

- Only **interactive** SSH logins trigger the banner/push (`.bashrc` isn't
  sourced for `ssh host cmd` / `scp` / `sftp`). The failed-login daemon catches
  *all* authentication failures via `journalctl`, regardless of session type.
- The SSH key *fingerprint* in the push is a SHA256 of the **public** key —
  it cannot be used to impersonate you. It's useful as an authenticity anchor:
  a fingerprint you don't recognize = unknown device logging in.
- ntfy over plain HTTP within a trusted LAN is acceptable; for anything
  traversing the internet, put TLS in front of it.
- The daemon rate-limits pushes to one per source-IP per 5 minutes (configurable
  via `FAIL_RATELIMIT_WINDOW`) to survive brute-force floods without DoS-ing
  your phone.

## Security contact

If you want to report a vulnerability, do not open a public issue first.
See [SECURITY.md](SECURITY.md) and contact `arn-c0de@protonmail.com`.

## License

MIT — see `LICENSE`.
