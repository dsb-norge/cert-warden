# Caller-side LE-staging canary — PROTOTYPE

> **Status: experimental.** This shape is being evaluated in a first consumer; it may be
> promoted to supported reference usage, reshaped, or deleted. Feedback to the maintainers.

## Why

Between suite releases, the outside world moves: Let's Encrypt policy, ACME/ARI behaviour,
lego regressions interacting with real DNS. The repo's CI can't see that (it tests against
Pebble by design). A **scheduled staging issuance in a real consumer environment** is the
early-warning signal — it exercises real Azure DNS, real LE staging, the real runner path,
end to end, independent of whether production renewals happen to be due.

## Shape

One caller workflow in your repo, alongside the reference callers:

```yaml
name: Cert Warden Canary

on:
  workflow_dispatch:
  schedule:
    - cron: "45 5 * * 1" # weekly; staging limits are far above this usage

permissions: {}

jobs:
  canary:
    permissions:
      id-token: write
    # No concurrency group: the warden locks the vault it targets, so the canary waits for the
    # real dev warden and the sweeper on this vault by itself.
    uses: dsb-norge/cert-warden/.github/workflows/reusable-warden.yml@v1
    with:
      environment: "canary"
      runs-on: "my-dev-runner-label"
      azure-tenant-id: "00000000-0000-0000-0000-000000000000"
      azure-subscription-id: "00000000-0000-0000-0000-000000000000"
      azure-client-id: "00000000-0000-0000-0000-000000000000" # the dev cert-maintainer
      key-vault-name: "kv-my-web-certs-dev"
      dns-rg-name: "rg-my-dns-dev"
      le-environment: "staging" # ALWAYS staging — this is the whole point
      le-account-email: "certs@example.com"
      force-all-new: true # full issuance every cycle, not just when due
      tag-application-name: "cert-warden canary"

```

And a **separate** monitor workflow chained on completion. (Why separate: the reusable
monitor resolves runs via the `workflow_run` event or "latest completed" — a `needs:` job in
the same run would evaluate the *previous* canary's artifact, since the current run isn't
completed yet.)

```yaml
name: Cert Warden Canary Monitor

on:
  workflow_run:
    workflows: ["Cert Warden Canary"]
    types: [completed]

permissions: {}

jobs:
  alert:
    permissions:
      id-token: write
      actions: read
    uses: dsb-norge/cert-warden/.github/workflows/reusable-monitor.yml@v1
    with:
      environment: "canary"
      warden-workflow-name: "Cert Warden Canary"
      azure-tenant-id: "00000000-0000-0000-0000-000000000000"
      monitor-client-id: "00000000-0000-0000-0000-000000000000"
      bot-api-base: "https://my-notifier.azurewebsites.net/api"
      bot-api-audience: "api://00000000-0000-0000-0000-000000000000"
      bot-alias: "from-canary" # a low-noise channel
```

## Hygiene, and what the sweeper does to the next run

Canary issuances land as `le-cert-staging-*` objects, with the account in
`letsencrypt-staging-account-*` secrets — exactly what the sweeper's default target prefixes
reap. A consumer running the full suite gets canary cleanup without configuring anything.

That cleanup is a soft delete, and Key Vault keeps a soft-deleted name taken for the vault's
retention period (7–90 days). The canary's next run writes the same names again, so the warden
recovers each soft-deleted object it needs (the account secrets, every certificate and its
`-meta` secret) and writes over it. What that means for you:

- The cert-maintainer identity needs `recover` on certificates and secrets. Key Vault
  Certificates Officer and Key Vault Secrets Officer include it; custom roles must grant it
  (see [consumer-prerequisites.md](consumer-prerequisites.md)).
- A run after a sweep finds no account in the vault and registers a new one. Once a week is far
  inside Let's Encrypt staging's limits.

## Notes

- Weekly `force-all-new` staging issuance over a typical zone count is negligible against LE
  staging limits.
- Point it at your least critical environment (fewest surprises, richest zone set).
- Do not point a canary at LE production — staging is deliberate: the signal is "the pipeline
  still works", not "browser-trusted certs".
