# Security Policy

## Supported versions

This project is currently maintained from the latest published branch state.
If you report a security issue, assume that only the most recent code in this
repository is supported unless stated otherwise.

## Reporting a vulnerability

Please do not report security vulnerabilities through public GitHub issues.

Instead, disclose them privately by email:

- `arn-c0de@protonmail.com`

When possible, include:

- a short summary of the issue
- affected file or component
- reproduction steps
- impact assessment
- any suggested fix or mitigation

## What to expect

Reasonable-effort expectations:

- acknowledgement after receipt
- triage and impact review
- a fix or mitigation if the issue is confirmed
- coordinated public disclosure after a patch is available

## Scope

Security-relevant areas in this repository include:

- SSH login event handling
- failed-authentication monitoring
- ntfy notification transport and token handling
- install and service wiring that affects persistence or exposure
- update-path trust and repository validation in `bin/seclog-update`

## Threat model

seclog-linux runs entirely as the account it watches. That is what makes it
installable without root, and it is also the limit of what it can promise:

- It reliably tells you about logins and failed attempts **while the account is
  not yet compromised**. That is the case it is built for.
- It cannot defend against someone who already holds the account. They can stop
  the user service, edit `~/.bashrc`, rewrite the config or replace the
  commands in `~/.local/bin`, and no further notification will be sent.
- Notifications are best effort. An attacker who can drop or delay traffic to
  your ntfy server suppresses alerts without touching the host.

Every push attempt, and every failure, is recorded through `logger(1)` to the
journal under the tag `seclog-linux`. The journal is not writable by the
monitored account, so the record that a notification was sent — or that sending
it failed — survives an account takeover even though future notifications do
not. Check it with:

```bash
journalctl -t seclog-linux --since "24 hours ago"
```

If you need an alerting path that survives full local compromise, forward the
journal to a host the monitored account cannot reach.

## Notification transport

The push payload is a reconnaissance profile of the host: account name, uid,
group membership (including `sudo`), client address and reverse DNS, the SSH
key fingerprint that was used, the TTY, and every currently connected peer.
The ntfy bearer token travels in the same request.

Consequently:

- Plaintext HTTP is **refused** for any target outside the local network.
  Set `NTFY_ALLOW_PLAINTEXT=1` only when the path is protected some other way,
  for instance a VPN that terminates elsewhere.
- Redirects cannot downgrade the transport: curl is pinned with `--proto` and
  `--proto-redir`.
- The URL, the topic, the token and the body are passed to curl through a
  config file on a file descriptor, never as command line arguments, because
  `/proc/<pid>/cmdline` is readable by every other local account.
- `PUSH_METADATA_LEVEL` defaults to `minimal`. `full` is genuinely more useful
  when investigating, but on a public ntfy topic it hands a stranger a map of
  the machine.

On a public server the topic name is the only secret protecting the feed. Self
hosting is strongly recommended; see `ntfy/server.yml.example`.

## Handling of attacker-controlled log data

The user name in a failed SSH login is chosen by the attacker, and OpenSSH only
escapes control characters when writing it to the journal — spaces and every
other printable character survive. A login attempt as
`x from 203.0.113.9 port 1 for root` therefore lets an attacker forge any field
that a parser reads by scanning the line left to right.

seclog parses defensively:

- The peer address is taken from the **last** `<ip> port <n>` pair on the line.
  sshd always writes the real client there and only appends its own trailer
  afterwards, so the value cannot be steered by the user name.
- The account name is read positionally from the known message grammar, not by
  searching the line for `for` or `user`.
- Names are reduced to `[A-Za-z0-9._@-]` and truncated before they reach a
  notification body or a terminal table.
- Rate-limit state files are keyed on the validated address. Without this, an
  attacker could pin every attempt onto one key and silence the monitor after a
  single notification.

## Configuration file trust

`~/.config/seclog-linux/config` is sourced by every command, so its contents
execute as the monitored user, and it also carries the update trust settings
below. seclog refuses to start when the file or its directory is owned by
someone else or is writable by group or others. The installer tightens an
existing config to `0600` and its directory to `0700`.

## Update security model

`seclog-update` is security-sensitive because it fetches new code and then runs
the repository installer. The controls are:

- **Update path pinning** — updates only run from `~/Projects/seclog-linux`
  unless `ALLOW_CUSTOM_REPO_DIR=1` is set explicitly.
- **Origin validation** — `origin` must match `EXPECTED_UPDATE_ORIGIN` or
  `EXPECTED_UPDATE_ORIGIN_ALT`, checked before anything is fetched.
- **Canonical path handling** — the repository path is resolved before use.
- **Mandatory signature verification** — the target commit must carry a good
  signature. This is not optional and has no off switch. (Releases before 1.1
  documented a `VERIFY_UPDATE_SIGNATURES` toggle; it no longer exists.)
- **Signer pinning** — when `UPDATE_SIGNER` is set, the reported identity must
  match it. `seclog-update --yes` refuses to run without it, so an unattended
  update can never fall back to "whatever my keyring happens to trust".
- **No verify/apply gap** — the update fast-forwards to the exact commit that
  was verified (`git merge --ff-only <sha>`), not to whatever the branch points
  at by the time the merge runs.
- **Absolute installer execution** — the installer runs from the checked out
  repository path, not from an ambient shell location.

## Signed update verification

Both signature backends are supported. Verification is mandatory, so **one of
them has to be configured or every update will abort.**

SSH signing (recommended — the allowed-signers file is itself the pin):

```bash
# On the target host, once:
mkdir -p ~/.config/seclog-linux
printf '%s %s\n' maintainer@example.com "$(cat maintainer_signing_key.pub)" \
    > ~/.config/seclog-linux/allowed_signers
chmod 600 ~/.config/seclog-linux/allowed_signers

git -C ~/Projects/seclog-linux config gpg.format ssh
git -C ~/Projects/seclog-linux config gpg.ssh.allowedSignersFile \
    ~/.config/seclog-linux/allowed_signers
```

OpenPGP signing: import the maintainer's public key into the keyring. Note that
a key merely being present in your keyring is not a trust decision, so with
OpenPGP you should always pin:

```bash
# ~/.config/seclog-linux/config
UPDATE_SIGNER="maintainer@example.com"
```

`seclog-diagnose` reports whether this is set up, under `[ Update trust ]`.

## Limits of the protection

- If the trusted signing key is compromised, signed malicious updates verify
  successfully.
- `seclog-update` executes repository code as the local user after a trusted
  update is accepted.
- Local user compromise remains out of scope; see the threat model above.
