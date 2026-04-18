# Security Policy

## Supported versions

This project is currently maintained from the latest `main` branch state.
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
