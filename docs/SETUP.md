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
NTFY_URL="http://YOUR_HOST:2586/ssh-login"
NTFY_TOKEN="tk_yourtokenhere"
FAIL_LOOKBACK="24 hours ago"
FAIL_RATELIMIT_WINDOW=300
```

Enable user-linger so the daemon survives logout:

```bash
sudo loginctl enable-linger "$USER"
```

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
| Banner appears, no push arrives | `NTFY_URL` wrong or `NTFY_TOKEN` invalid. Test: `curl -u user:pass -d hi http://HOST:2586/topic` |
| No failed-attempt pushes | Daemon not running: `systemctl --user status seclog-linux-fail-monitor`. Check logs: `journalctl --user -u seclog-linux-fail-monitor -n 50` |
| Daemon stops after I log out | `sudo loginctl enable-linger $USER` not done |
| Banner doesn't appear on SSH | `.bashrc` only runs for **interactive** sessions. Test: `ssh -t host`. For non-interactive logins, catch them via the daemon (which watches the journal). |
| `last` command missing on new Debian | Expected — Debian 13 moved it to the `wtmpdb` package. Scripts use `journalctl` instead of `last`, so this doesn't matter. |
