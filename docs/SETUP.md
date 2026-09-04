# Detailed setup guide

The README covers the quick path. This is the long version: a self-hosted
ntfy server, the phone subscription, the install and the checks.

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

Create an admin user and a never-expiring token:

```bash
docker exec -it ntfy ntfy user add --role=admin myuser     # prompts for a password
docker exec ntfy ntfy token add --expires 0 myuser         # -> tk_... for NTFY_TOKEN
```

If the server is reachable from outside your LAN, terminate TLS in front of it
(Caddy, nginx, Traefik) and use the `https://` URL below. seclog refuses to
push over plaintext HTTP to anything that is not a local address: the push
body profiles the host and the token rides along.

## 2. Subscribe from your phone

1. Install the [ntfy Android/iOS app](https://ntfy.sh/app).
2. Add a subscription to your topic, e.g. `ssh-login`.
3. In the subscription settings, point the server URL at your own instance,
   not `ntfy.sh`, and enter the username and password or the token.

## 3. Install on the server

```bash
git clone https://github.com/arn-c0de/seclog-linux.git ~/Projects/seclog-linux
cd ~/Projects/seclog-linux
./install.sh
```

Edit `~/.config/seclog-linux/config`. It is a plain `KEY=value` file, not a
shell script, so write values out literally:

```
NTFY_URL="https://ntfy.example.com/ssh-login"
NTFY_TOKEN="tk_yourtokenhere"

# Pin who may ship you updates (see SECURITY.md).
UPDATE_SIGNER="maintainer@example.com"
```

Everything else has a sensible default; the complete list with explanations
is `config/config.example`.

For a LAN-only server, `http://192.168.x.y:2586/ssh-login` is accepted
without further ado. For anything else use TLS or set
`NTFY_ALLOW_PLAINTEXT=1` deliberately.

Apply the config and let the monitor survive logout:

```bash
seclog restart
sudo loginctl enable-linger "$USER"
```

Lingering matters more than it looks: the monitor is what notices *every*
login, including `scp`, `sftp`, `rsync` and `ssh host cmd`. The `.bashrc`
banner only ever runs for interactive bash. Without lingering the monitor
stops when you log out.

If the account cannot read the system journal, `seclog diagnose` says so.
On most distributions the fix is:

```bash
sudo usermod -aG systemd-journal "$USER"    # then log out and back in
```

Optional, for country names in the banner: `mmdblookup` with a GeoLite2
database (Debian: `apt install mmdb-bin`, then drop
`GeoLite2-Country.mmdb` into `/var/lib/GeoIP/`), or the legacy
`apt install geoip-bin geoip-database`.

## 4. Verify

```bash
seclog diagnose          # every check; sends one test push
seclog                   # the banner, on demand
```

Trigger a login push by reconnecting:

```bash
exit
ssh you@server
```

You should see the banner and get a push within a second or two.

Trigger a failure push from any other machine:

```bash
ssh nosuchuser@YOUR_SERVER
```

A push titled `SSH FAILED: nosuchuser from ...` should arrive.

Every push and every failure to push is written to the journal:

```bash
journalctl -t seclog-linux --since "1 hour ago"
journalctl --user -u seclog-monitor -n 50
```

## 5. Day to day

```bash
seclog                        # last 24h of failures
seclog "1 hour ago"           # custom window
seclog status --json | jq .   # for scripts
seclog update                 # signed update of the checkout
```

Troubleshooting lives in the README's table; the update trust chain and the
threat model in SECURITY.md.
