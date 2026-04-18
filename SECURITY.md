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

## Update security model

`seclog-update` is security-sensitive because it can fetch new code and then
run the repository installer. The current trust model includes these controls:

- update path pinning: by default, updates are only allowed from
  `~/Projects/seclog-linux`
- origin validation: `origin` must match the expected upstream remote
- canonical path handling: the repository path is resolved before use
- absolute installer execution: the updater runs the installer from the checked
  out repository path, not from an ambient shell location
- optional signed-update enforcement: when
  `VERIFY_UPDATE_SIGNATURES=1` is set, the target commit must pass
  `git verify-commit` before the update is applied

## Signed update verification

This project supports SSH-signed commit verification for update safety.

A typical hardened deployment looks like this:

- commits are signed by the maintainer locally using an SSH signing key
- the target host stores the matching public key in an `allowed_signers` file
- Git on the target host is configured with:
  `gpg.format=ssh` and `gpg.ssh.allowedSignersFile=...`
- `~/.config/seclog-linux/config` sets:
  `VERIFY_UPDATE_SIGNATURES=1`

With that configuration, `seclog-update` will refuse to apply an update unless
the target commit verifies against the configured signer trust.

## Limits of the protection

The update hardening reduces risk, but does not eliminate trust assumptions.

- If signed verification is disabled, trust falls back to the configured git
  remote.
- If the trusted signing key itself is compromised, signed malicious updates
  would still verify successfully.
- `seclog-update` still executes repository code as the local user after a
  trusted update is accepted.
- Local user compromise remains out of scope for this mechanism.
