# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** via GitHub's private vulnerability
reporting: [Security → Report a vulnerability](https://github.com/dsb-norge/cert-warden/security/advisories/new).
Do not open public issues for security reports.

## Scope notes for this repository

- The suite runs in *consumers'* pipelines against their Azure identities; this repo itself
  holds no cloud credentials. The only repository credential is a GitHub App scoped to this
  repo (releases + preview tags).
- Certificate material never transits this repo: consumers' runners talk directly to
  Let's Encrypt and their own Key Vaults.
- Supply-chain posture: third-party actions are SHA-pinned (enforced in CI), releases are
  immutable, and consumers are advised to pin full commit SHAs (see docs/reference-usage.md).
