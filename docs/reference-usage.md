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
      # More than ~20 zones in an environment? See "Pacing a large fleet" below — without a cap,
      # one renewal wave is a multi-hour job on this runner, every cycle, forever.
      # max-renewals-per-run: 9
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
    #   ^ the only trigger that looks the warden run up via the GitHub API; workflow_run gets
    #     it from the event payload. See "when the monitor cannot resolve a run" below.
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
      # Dispatch: the operator's choice. Schedule: always destructive (that's graduation step 3).
      log-only: ${{ github.event_name != 'schedule' && inputs.log_only }}
```

**When the monitor cannot resolve a run.** On the `schedule`/`workflow_dispatch` path the
monitor asks the API which warden run to evaluate, and separates three outcomes:

| outcome | severity | notifies |
|---|---|---|
| a run was found | the SLO verdict | on breach |
| the API answered: no workflow by that name, or it has no completed runs | `WARNING` | yes |
| the API did not answer (retried 3×) | `UNKNOWN` | **no** |

The middle row is why a typo'd or renamed `warden-workflow-name` keeps warning instead of going
quiet — a misconfiguration is a permanent, actionable finding, not a blip. The last row is the
opposite case: nothing was measured, so the monitor claims nothing. It emits **empty**
measurement outputs and sends nothing to Teams, not even under `force_notify`; an unevaluated
run is not a certificate finding, and a notification per network blip only teaches the
channel's readers to ignore it. The trace is a `::warning::` annotation on the monitor run plus
the `resolve-failed` output, and a *persistently* failing resolve is expected to surface
through your CA/vault's own near-expiry alerting rather than through this workflow. Note the
`workflow_run` path cannot take that branch at all, so an environment whose warden still runs
keeps getting evaluated normally.

**Sweeper graduation ladder** (default-safe by design): ① dispatch dry-runs and review the
candidate list → ② one destructive dispatch (`log_only: false`; the `max-deletions` spike
guard stays armed) → ③ uncomment the cron. Full auto is a two-line change.

## Pacing a large fleet (`max-renewals-per-run`)

Skip this unless an environment has more than ~20 zones. Below that, runs are short enough that
the cap buys nothing.

### The problem it solves

ARI schedules renewal relative to **issuance**, so an environment whose certificates were issued
together becomes one whose certificates *renew* together — and each renewal re-issues them
together again. **The shape of the first issuance is the shape of every renewal wave,
indefinitely.** Nothing about it self-corrects.

At roughly 4–5 minutes per certificate (DNS-01 propagation plus lego's deliberate random
smearing — not an error path), a wave of 50 zones is a 4-hour job. On a self-hosted runner shared
with your other pipelines, that is 4 hours of blocked unrelated work, twice over: once at first
issuance and again every renewal cycle. Neither force flag helps — both are all-or-nothing, and
`force-renewal: true` across an environment is one of the ways a fleet ends up in a single wave
to begin with.

`max-renewals-per-run` caps the certificates one run may issue, renew or force. The rest are
recorded `deferred` and taken by the next run:

```yaml
with:
  max-renewals-per-run: 9
```

- The cap counts **mutating** actions only. `skipped`, `not_delegated` and `failed` cost nothing.
- Past the budget, a zone reaches neither Key Vault nor lego — no ACME traffic, no random delay.
- The run walks the zones **most-urgent-first** (ascending remaining validity), so the cap can
  only ever defer a certificate with more time left than the ones it renewed. Zones with no
  certificate yet sort last: nothing is in service for them that could expire.
- **The force flags respect the cap.** If you really do want everything at once, leave the cap
  unset — that is what expresses it.
- Nothing is carried between runs. Dueness is already the selector, the deferred certificates are
  still due, and the set shrinks as they renew.

### Sizing it — the rule

**A cap is not free: it deliberately holds due certificates past their renewal point, and that
is exactly what the monitor's `min_lifetime_fraction` SLO measures.** Set it too low and you
trade one long run for days of `WARNING` cards.

ARI suggests renewal at ~⅓ of lifetime remaining (0.333) and the monitor warns below 0.30, so
the margin is the gap between where the wave is *now* and that warn threshold:

```
margin_days = (fraction_now − warn-threshold) × certificate_lifetime_days
```

`fraction_now` is the **worst deferred certificate's current** fraction, and that is the part
that bites: the margin is widest for a wave caught exactly at its renewal point, and it collapses
within days.

| Worst deferred certificate | Margin (90-day certs, warn 0.30) |
|---|---:|
| exactly at the ARI point (0.333) | ~3.0 days |
| ~1 day overdue (0.322) | ~1.8 days |
| ~2 days overdue (0.311) | ~0.9 days |

The whole wave has to drain inside that margin:

```
cap  ≥  ⌈ wave_size / (runs_per_day × margin_days) ⌉
```

| Wave size | Floor cap (twice daily, 3-day margin) | Drain | Run length at ~5 min/cert |
|---:|---:|---:|---:|
| 28 | 5 | 3.0 days | ~25 min |
| 41 | 7 | 3.0 days | ~35 min |
| 51 | 9 | 3.0 days | ~45 min |

**Those are floors with no headroom** — they land exactly on the 3-day best case, so a wave you
discover after it has already gone overdue needs a bigger cap than the table says. Aim for a
drain of about a day and leave the arithmetic to the warden's annotation.

Two corollaries worth internalising:

- **The cap's floor is set by your fleet, not by your patience.** A 51-zone environment cannot be
  paced at 3 per run without the monitor complaining — that is an 8.5-day drain against a 3-day
  margin at best. If you want a smaller cap, you need more runs per day, not a smaller number.
- **First issuance is the free case.** A zone with no certificate yet has no lifetime fraction to
  sink, so the SLO cannot trip. Cap a not-yet-issued environment as aggressively as you like.

You do not have to get this right from memory: when a run defers more than it can drain in time,
the warden annotates it with the numbers and the cap that would have fitted —

```
::warning::warden: CERT_MAX_RENEWALS_PER_RUN=3 is too small for this backlog. Draining 51
deferred certificate(s) at 2 run(s)/day takes ~8.5 days, but z7.example.com drops below the
monitor's warn threshold (0.30) in ~3.0 days, so the monitor will alert while the backlog is
still draining. Raise the cap to 9 (or clear it for this wave).
```

If your callers differ from the assumed shape, tell the warden so the guard stays honest:
`runs-per-day` (default 2) and `monitor-warn-threshold` (default 0.30 — set it if you tuned the
monitor's).

### Watching a wave drain

`zones-deferred` is a job output, and the step summary carries a `deferred` count, so progress
across runs ("5 renewed, 23 deferred") is visible without downloading the artifact.

### What the cap does not cover

- **A mass-revocation event.** Let's Encrypt can pull an ARI window far earlier than expiry, and
  urgency ordering — which sorts by *expiry* — cannot see that. Clear the cap for the duration;
  it takes effect on the next run.
- **SAN drift on a healthy certificate.** Adding an A record needs a re-issue, but the
  certificate's remaining validity is untouched, so it sorts late and can wait out a wave. It is
  picked up as soon as the wave drains.

## 2. Warden only (minimum viable consumer)

Just the first workflow above — monitor and sweeper are optional and independent.

## 3. Evaluate-only monitoring (roll your own delivery)

Call `reusable-monitor.yml` without `monitor-client-id`/bot inputs and consume its outputs
(`severity`, `min-lifetime-fraction`, `failed-count`, `reasons-json`, `resolve-failed`, …) in a
follow-up job. Handle `severity: UNKNOWN` — it means the monitor evaluated nothing (see below)
and the measurement outputs are empty, so gating on `managed-count == 0` there would read "no
certificates" out of a run that never looked.
Enabled by design, but **unsupported** — the supported channel is the
[Teams Notification Bot](https://github.com/dsb-norge/teams-notifier-function-app).

## Composing the actions directly

When the packaged shapes don't fit, build your own workflow from
`dsb-norge/cert-warden/actions/{setup-lego,warden,monitor,sweeper}` — same contracts, same
pins. The reusable workflows are themselves ~60-line examples of exactly this.
