# Reference usage — the standard way to call the suite

Copy-paste caller workflows for the three tools. Prerequisites (identities, Key Vault,
network, runners) are in [consumer-prerequisites.md](consumer-prerequisites.md); the contracts
behind the inputs are in [contracts.md](contracts.md).

## Pinning

Pin a **full commit SHA with a version comment** (Renovate and Dependabot both bump these):

```yaml
uses: dsb-norge/cert-warden/.github/workflows/reusable-warden.yml@<full-sha> # vX.Y.Z
```

The floating `v1` tag is offered as a lower-friction alternative for high-trust consumers.
The examples below write `@v1` for brevity — substitute your pin style.

> Nothing is consumable before the first `v1.0.0` release: the internal refs on `main` point
> at the next release version by design.

## 1. Full suite (recommended shape)

Three caller workflows. Note the two contracts in comments: the **shared concurrency group**
(warden and sweeper must never race on the same vault) and the **workflow name** (the monitor
resolves the warden's runs by name).

### `cert-warden.yml`

```yaml
name: Cert Warden # <- the monitor's warden-workflow-name input must match this

on:
  workflow_dispatch:
  schedule:
    - cron: "34 4 * * *"
    - cron: "34 16 * * *"
  # Optional: chain after your IaC deploy so placeholder/config changes are picked up fast.
  workflow_run:
    workflows: ["IAC deploy test"]
    types: [completed]
    branches: [main]

permissions: {}

jobs:
  warden:
    # Only run after a SUCCESSFUL deploy when chained; always run for schedule/dispatch.
    if: github.event.workflow_run.conclusion == 'success' || github.event.workflow_run == null
    strategy:
      fail-fast: false
      max-parallel: 1 # Let's Encrypt hygiene: one environment at a time
      matrix:
        environment: ["test", "dev"]
        include:
          - environment: "test"
            vars:
              runs-on: "my-test-runner-label"
              azure-subscription-id: "00000000-0000-0000-0000-000000000000"
              azure-client-id: "00000000-0000-0000-0000-000000000000" # cert-maintainer UAMI
              key-vault-name: "kv-my-web-certs-test"
              dns-rg-name: "rg-my-dns-test"
              le-environment: "staging" # promote to "production" after a clean staging run
          - environment: "dev"
            vars:
              runs-on: "my-dev-runner-label"
              azure-subscription-id: "00000000-0000-0000-0000-000000000000"
              azure-client-id: "00000000-0000-0000-0000-000000000000"
              key-vault-name: "kv-my-web-certs-dev"
              dns-rg-name: "rg-my-dns-dev"
              le-environment: "staging"
    concurrency:
      group: cert-warden-${{ matrix.environment }} # shared with the sweeper — same vault
      cancel-in-progress: false
    permissions:
      id-token: write # OIDC login
    uses: dsb-norge/cert-warden/.github/workflows/reusable-warden.yml@v1
    with:
      environment: ${{ matrix.environment }}
      runs-on: ${{ matrix.vars.runs-on }}
      azure-tenant-id: "00000000-0000-0000-0000-000000000000"
      azure-subscription-id: ${{ matrix.vars.azure-subscription-id }}
      azure-client-id: ${{ matrix.vars.azure-client-id }}
      key-vault-name: ${{ matrix.vars.key-vault-name }}
      dns-rg-name: ${{ matrix.vars.dns-rg-name }}
      le-environment: ${{ matrix.vars.le-environment }}
      le-account-email: "certs@example.com"
      tag-application-name: "My platform (${{ matrix.environment }}) DNS zones"
```

### `cert-warden-monitor.yml`

```yaml
name: Cert Warden Monitor

on:
  workflow_run:
    workflows: ["Cert Warden"] # evaluate each warden run as it completes
    types: [completed]
  schedule:
    - cron: "17 6 * * *" # liveness watchdog: catches "warden stopped running entirely"
  workflow_dispatch:
    inputs:
      force_notify:
        description: "Post to the bot even when status is OK (test delivery)."
        type: boolean
        default: false
      dry_run:
        description: "Evaluate and log but never POST."
        type: boolean
        default: false

permissions: {}

jobs:
  monitor:
    # Only evaluate real outcomes when chained (not cancelled/skipped runs).
    if: >-
      github.event_name != 'workflow_run' ||
      github.event.workflow_run.conclusion == 'success' ||
      github.event.workflow_run.conclusion == 'failure'
    strategy:
      fail-fast: false
      matrix:
        environment: ["test", "dev"]
        include:
          - environment: "test"
            vars:
              monitor-client-id: "00000000-0000-0000-0000-000000000000" # monitor UAMI
              alias: "from-test-env"
          - environment: "dev"
            vars:
              monitor-client-id: "00000000-0000-0000-0000-000000000000"
              alias: "from-dev-env"
    permissions:
      id-token: write # bot-token identity
      actions: read # resolve runs + download the metrics artifact
    uses: dsb-norge/cert-warden/.github/workflows/reusable-monitor.yml@v1
    with:
      environment: ${{ matrix.environment }}
      warden-workflow-name: "Cert Warden"
      azure-tenant-id: "00000000-0000-0000-0000-000000000000"
      monitor-client-id: ${{ matrix.vars.monitor-client-id }}
      bot-api-base: "https://my-notifier.azurewebsites.net/api"
      bot-api-audience: "api://00000000-0000-0000-0000-000000000000"
      bot-alias: ${{ matrix.vars.alias }}
      force-notify: ${{ github.event_name == 'workflow_dispatch' && inputs.force_notify }}
      dry-run: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}
```

### `cert-sweeper.yml`

```yaml
name: Cert Sweeper

on:
  workflow_dispatch:
    inputs:
      log_only:
        description: "Dry run — log what would be deleted, delete nothing."
        type: boolean
        default: true
  # Graduation step 2 (set-and-forget): uncomment after validating a destructive dispatch.
  # Scheduled runs sweep for real (log_only resolves to false for non-dispatch events).
  # schedule:
  #   - cron: "17 3 * * 0"

permissions: {}

jobs:
  sweep:
    strategy:
      fail-fast: false
      max-parallel: 1
      matrix:
        environment: ["test", "dev"]
        include:
          - environment: "test"
            vars:
              runs-on: "my-test-runner-label"
              azure-subscription-id: "00000000-0000-0000-0000-000000000000"
              azure-client-id: "00000000-0000-0000-0000-000000000000" # same cert-maintainer UAMI
              key-vault-name: "kv-my-web-certs-test"
          - environment: "dev"
            vars:
              runs-on: "my-dev-runner-label"
              azure-subscription-id: "00000000-0000-0000-0000-000000000000"
              azure-client-id: "00000000-0000-0000-0000-000000000000"
              key-vault-name: "kv-my-web-certs-dev"
    concurrency:
      group: cert-warden-${{ matrix.environment }} # NEVER race the warden on the same vault
      cancel-in-progress: false
    permissions:
      id-token: write
    uses: dsb-norge/cert-warden/.github/workflows/reusable-sweeper.yml@v1
    with:
      environment: ${{ matrix.environment }}
      runs-on: ${{ matrix.vars.runs-on }}
      azure-tenant-id: "00000000-0000-0000-0000-000000000000"
      azure-subscription-id: ${{ matrix.vars.azure-subscription-id }}
      azure-client-id: ${{ matrix.vars.azure-client-id }}
      key-vault-name: ${{ matrix.vars.key-vault-name }}
      log-only: ${{ github.event_name != 'schedule' && (inputs.log_only || true) }}
```

**Sweeper graduation ladder** (default-safe by design): ① dispatch dry-runs and review the
candidate list → ② one destructive dispatch (`log_only: false`; the `max-deletions` spike
guard stays armed) → ③ uncomment the cron. Full auto is a two-line change.

## 2. Warden only (minimum viable consumer)

Just the first workflow above — monitor and sweeper are optional and independent.

## 3. Evaluate-only monitoring (roll your own delivery)

Call `reusable-monitor.yml` without `monitor-client-id`/bot inputs and consume its outputs
(`severity`, `min-lifetime-fraction`, `failed-count`, `reasons-json`, …) in a follow-up job.
Enabled by design, but **unsupported** — the supported channel is the
[Teams Notification Bot](https://github.com/dsb-norge/teams-notifier-function-app).

## Composing the actions directly

When the packaged shapes don't fit, build your own workflow from
`dsb-norge/cert-warden/actions/{setup-lego,warden,monitor,sweeper}` — same contracts, same
pins. The reusable workflows are themselves ~60-line examples of exactly this.
