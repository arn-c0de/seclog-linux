# Detailed setup guide

## 1. Prepare ntfy (self-hosted)

Run ntfy in Docker (official image):

```bash
mkdir -p ~/ntfy-data ~/ntfy-cache
docker run -d --name ntfy --restart=always \
    -p 2586:80 \
    -v ~/ntfy-data:/etc/ntfy \
    -v ~/ntfy-cache:/var/cache/ntfy \
    binwiederhier/ntfy \
    serve --cache-file /var/cache/ntfy/cache.db
```

Copy `ntfy/server.yml.example` to the container's config mount:

```bash
docker exec ntfy sh -c 'cat > /etc/ntfy/server.yml' < ntfy/server.yml.example
# Edit base-url to your real host, then:
docker restart ntfy
```

Create an admin user + a never-expiring token:

```bash
# Password (you'll be prompted)
docker exec -it ntfy ntfy user add --role=admin myuser

# Token (use this in NTFY_TOKEN)
docker exec ntfy ntfy token add --expires 0 myuser
```

## 2. Subscribe from your phone

1. Install the [ntfy Android/iOS app](https://ntfy.sh/app).
2. Add a subscription to your topic, e.g. `ssh-login`.
3. **Important:** in the subscription settings, point the server URL to your
   self-hosted instance (not `ntfy.sh`), and enter your username + password
   (or access token if the app supports it).

## 3. Install on the server

```bash
git clone git@github.com:arn-c0de/seclog-linux.git
cd seclog-linux
./install.sh
```

Edit `~/.config/seclog-linux/config`:

```bash
NTFY_URL="https://ntfy.example.com/ssh-login"
NTFY_TOKEN="tk_yourtokenhere"
FAIL_LOOKBACK="24 hours ago"
FAIL_RATELIMIT_WINDOW=300

# Pin who is allowed to ship you updates (see SECURITY.md).
UPDATE_SIGNER="maintainer@example.com"
```

`https://` is not decoration. The push body profiles this host — account, uid,
groups, client address, SSH key fingerprint — and the token above travels in
the same request, so seclog refuses plaintext HTTP to anything outside the
local network. For a LAN-only server (`http://192.168.x.y:2586/...`) it is
allowed automatically; for anything else either use TLS or set
`NTFY_ALLOW_PLAINTEXT=1` to accept the risk deliberately.

Enable user-linger so the daemon survives logout:

```bash
sudo loginctl enable-linger "$USER"
```

This matters more than it looks: the monitor is what notices *successful*
logins, including `scp`, `sftp`, `rsync` and `ssh host cmd`. The `.bashrc`
banner only ever runs for interactive bash. Without lingering the monitor stops
when you log out, and those logins go unannounced.

## 4. Verify

Trigger a login push by reconnecting:

```bash
exit
ssh you@server
```

You should see the colored banner and get a push within a second or two.

Trigger a failed push from any other machine:

```bash
ssh nosuchuser@YOUR_SERVER
```

A push with title `SSH FAILED: nosuchuser from ...` should arrive.

## 5. Ad-hoc status query

Any time after install, any shell on the server can run:

```bash
seclog                    # last 24h of fails
seclog "1 hour ago"       # custom window
seclog "7 days ago"       # last week
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Banner appears, no push arrives | Run `seclog-diagnose`, then check `journalctl -t seclog-linux -n 20` — every push and every failure is logged there. |
| `push REFUSED ... plaintext HTTP` | `NTFY_URL` is `http://` to a non-local host. Use `https://`, or set `NTFY_ALLOW_PLAINTEXT=1` if the path is protected another way. |
| `refusing to source ... config` | The config is group/world writable or foreign-owned. `chmod 600 ~/.config/seclog-linux/config` and `chmod 700` its directory. |
| `seclog-update` always aborts | Signature verification is not set up. See "Signed update verification" in SECURITY.md, or run `seclog-diagnose`. |
| No failed-attempt pushes | Daemon not running: `systemctl --user status seclog-monitor`. Check logs: `journalctl --user -u seclog-monitor -n 50` |
| Daemon stops after I log out | `sudo loginctl enable-linger $USER` not done |
| Banner doesn't appear on SSH | `.bashrc` only runs for **interactive** sessions. Test: `ssh -t host`. For non-interactive logins, catch them via the daemon (which watches the journal). |
| `last` command missing on new Debian | Expected — Debian 13 moved it to the `wtmpdb` package. Scripts use `journalctl` instead of `last`, so this doesn't matter. |
