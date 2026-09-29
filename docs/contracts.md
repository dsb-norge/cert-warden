# Contracts

The suite's public API is more than the action/workflow inputs — four cross-component
contracts (§1–3, §5) are covered by SemVer. Breaking any of them is a **major** release with a migration
note.

## 1. The environment-variable contract (scripts)

The scripts read all configuration from the environment. The composite actions map their
inputs onto these names; running the scripts directly (tests, `scripts/run-local.sh`) uses
them as-is.

### warden (`actions/warden/cert-warden.sh`)

| Variable | Required | Meaning |
|---|---|---|
| `AZ_TENANT_ID` | yes | Azure tenant id |
| `AZ_SUBSCRIPTION_ID` | yes | Subscription holding the DNS zones + Key Vault |
| `AZ_DNS_RG_NAME` | yes | Resource group with the public DNS zones |
| `AZ_CERT_KV_NAME` | yes | Key Vault for certs, LE account material, ARI metadata |
| `LE_NEW_ACCOUNT_EMAIL` | yes | Email for NEW LE account registration (existing account in KV wins) |
| `CERT_AZ_RESOURCE_TAG_ApplicationName` | yes | Tag on KV certificate objects |
| `CERT_AZ_RESOURCE_TAG_CreatedBy` | yes | Tag (conventionally the calling repo URL) |
| `CERT_AZ_RESOURCE_TAG_Description` | yes | Tag |
| `LE_ENVIRONMENT_NAME` | no (`staging`) | `staging` or `production` |
| `CERT_FORCE_ALL_NEW` | no (`false`) | Force new certs for all zones |
| `CERT_FORCE_RENEWAL` | no (`false`) | Force renewal of existing certs |
| `CERT_MAX_RENEWALS_PER_RUN` | no (`unlimited`) | Renewals/forces per run — zones the warden has already issued a certificate for. `none`, `unlimited` or a positive integer; **`0` is rejected**. See [pacing](reference-usage.md#pacing-a-large-fleet) |
| `CERT_MAX_NEW_ISSUANCE_PER_RUN` | no (`unlimited`) | The same for first issuances — zones the warden has not issued for yet, placeholder or not. A **separate** budget |
| `CERT_RUNS_PER_DAY` | no (`2`) | The caller's warden cadence; only feeds the renewal cap's sizing guard |
| `CERT_MONITOR_WARN_THRESHOLD` | no (`0.30`) | Mirror of the monitor's `WARN_THRESHOLD`; only feeds the same guard |
| `CERT_METRICS_OUTPUT_FILE` | no | Where the metrics artifact is written |

An unparsable value for any of the pacing variables **fails the run**. That is deliberate: a
typo'd cap silently reading as "unlimited" reinstates exactly the multi-hour, runner-blocking run
the cap exists to prevent, and it would do so at the worst possible moment.

**`0` is rejected rather than mapped to a meaning.** It is the one value with a genuinely split
reading — "max zero" says *none* to most people, *no cap* to others — and the two readings fail in
opposite directions. Guessing "none" stops certificate renewal across an environment with no
error, no failed zone and a green run. The error names both replacements. Negative values are
rejected for the same reason: `-1` conventionally means "no limit" elsewhere, the opposite of what
anyone would intend here.

**The two budgets are independent, and a zone's class follows the vault, not the recorded
action.** A zone whose slot holds a certificate *the warden issued* — one carrying its `IssuedBy`
tag (§3) — draws on `CERT_MAX_RENEWALS_PER_RUN`; any other zone draws on
`CERT_MAX_NEW_ISSUANCE_PER_RUN`, including one whose slot holds only a consumer-seeded placeholder. So a SAN-drift re-issue records `issued` but
spends renewal budget — correct, because it is maintenance of a zone already in service. If the
Key Vault pre-pass fails there is nothing to classify on, and both budgets collapse onto the
**smallest** cap that is set: conservative by design, since the alternative is letting a failed
listing produce an unbounded run.

### monitor (`actions/monitor/monitor.sh`)

Outputs include the drain pair — `renewed-count` and `still-due-count` — alongside
`severity`, `min-lifetime-fraction`, `managed-count`, `failed-count`, `worst-zone`,
`awaiting-issuance-count`, `renewals-suppressed`, `reasons-json`, `notified` and
`notify-http-status`. All are emitted **empty** under `UNKNOWN`.

`METRICS_FILE`, `ENV_NAME`, `WARN_THRESHOLD` (0.30), `PAGE_THRESHOLD` (0.15),
`LIVENESS_WINDOW_HOURS` (36), `CERT_WARDEN_CONCLUSION`, `CERT_WARDEN_RUN_URL`,
`METRICS_AGE_HOURS` (liveness check, and dates the run on the card/summary),
`RESOLVE_FAILED` (`false`), `BOT_API_BASE`, `BOT_API_AUDIENCE`,
`BOT_ALIAS`, `FORCE_NOTIFY`, `DRY_RUN`. All optional; without the bot triple the monitor is
evaluate-only. Exit code is always 0 on a completed evaluation.

**Severity is `OK | WARNING | CRITICAL | UNKNOWN`.** `UNKNOWN` means *nothing was measured* —
the caller set `RESOLVE_FAILED=true` because it could not work out which warden run to
evaluate. It is not a health verdict and it **never notifies** (not even under `FORCE_NOTIFY`);
`managed-count`, `failed-count`, `min-lifetime-fraction` and `worst-zone` are emitted **empty**
rather than `0`/`null`, so nothing downstream can mistake "we did not look" for "there are no
certificates". The trace is a `::warning::` annotation on the run and the `resolve-failed`
output. Consumers that branch on `severity` must treat an unrecognised value as "no signal".

### sweeper (`actions/sweeper/sweeper.sh`)

`KV_NAME` (required), `LOG_ONLY` (`true` — default-safe dry run), `SWEEP_EXPIRED` (`true`),
`MAX_DELETIONS` (120), `TARGET_CERT_PREFIXES`, `TARGET_SECRET_PREFIXES`,
`PROTECTED_PREFIXES`. A protected prefix always wins.

### Test seams (`CW_*` — NOT supported for production use)

Defaults are production behaviour; the integration harness overrides them
(see [testing.md](testing.md)):

| Variable | Default | Purpose |
|---|---|---|
| `CW_ACME_DIRECTORY_URL` | derived from `LE_ENVIRONMENT_NAME` | Point lego at a test ACME server |
| `CW_LEGO_DNS_PROVIDER` | `azuredns` | DNS-01 provider (`exec` in tests) |
| `CW_LEGO_DNS_RESOLVERS` | `1.1.1.1:53 8.8.8.8:53 9.9.9.9:53` | Propagation-check resolvers |
| `CW_LEGO_EXTRA_ARGS` | empty | Extra `lego run` args |
| `CW_DIG_ARGS` | `@1.1.1.1` | Resolver args for the delegation `dig NS` check |

## 2. The metrics artifact

JSON array, one record per zone; formal schema in
[`contracts/metrics.schema.json`](../contracts/metrics.schema.json) (validated by the unit
suite). The warden writes it **even when the run fails partially** — a failed zone must still
produce a record; that guarantee is regression-tested at every layer.

### The `action` vocabulary

`issued | renewed | forced | skipped | failed | not_delegated | deferred`.

`deferred` means the budget for that zone's class was spent before the zone was reached, or was
set to `none`: the zone was **not evaluated**, and the next run that permits its class takes it.
`deferred_reason` says which (`budget-spent` / `budget-none`).

**A deferred record is not automatically a backlog.** Renewals are walked most-urgent-first, so
healthy certificates sort last and are always deferred — a run can report dozens of deferred
renewals while only a handful are actually waiting. Anything sizing a wave has to filter, and
`cw_is_due` in [`lib/helpers.bash`](../lib/helpers.bash) is the shared definition for it: lego's
own renewal rule (a third of the lifetime remaining, or a half below a 10-day lifetime) applied to
the record's own numbers. The warden's advisory and the monitor's card both use it, so they cannot
disagree about the size of a wave. It is **reporting only** — dueness for the purpose of actually
renewing is still ARI's decision, inside lego. Which budget applies is derivable
from the record — a deferred renewal carries a validity window, a deferred first issuance has
none. It is a healthy state, not
a finding — but note what that does and does not mean for the monitor:

- The monitor is **action-blind for the SLO**. It never branches on `deferred`; it keys on
  `lifetime_fraction_remaining`. So there is nothing to "teach" it, and nothing to special-case.
- Deferred records therefore carry the **Key Vault validity window**, giving them a real
  `days_to_expiry` and `lifetime_fraction_remaining`. This is load-bearing. A null there would
  drop the zone out of `min_lifetime_fraction` entirely, and the run would look healthier the
  more certificates it declined to touch — a backlog that stopped draining would go unnoticed.
- The flip side is that a cap **deliberately holds certificates past their renewal point**,
  which is precisely what the SLO measures. A cap sized too small for the wave therefore trips
  the monitor's `WARNING` while draining. The warden predicts that and annotates the run; the
  sizing rule is in [reference-usage.md](reference-usage.md#sizing-the-renewal-cap).

Adding `deferred` was a **minor** bump: no consumer branches on the action except to recognise
`failed` and `not_delegated`, and a `deferred` record is deliberately neither. A consumer that
validates the artifact against a pinned older copy of the schema must bump it.

The reusable warden workflow uploads it as artifact
`cert-warden-metrics-<environment>-<run_id>-<run_attempt>`; the reusable monitor workflow
downloads by the pattern `cert-warden-metrics-<environment>-*`. The artifact name prefix is
part of this contract.

## 3. The Key Vault naming scheme

These names are **state in every consumer's vault** and what their certificate consumers (e.g.
Application Gateway) read — the most breaking-change-averse contract of all:

| Object | Name |
|---|---|
| Certificate (+ backing secret) | `le-cert-<le-env>-<zone-with-dots-as-dashes>-pfx` |
| lego/ARI metadata secret | `le-cert-<le-env>-<zone…>-pfx-meta` |
| LE account secrets | `letsencrypt-<le-env>-account-{email,key,json}` |

`<le-env>` is the **Let's Encrypt** environment (`staging`/`production`), not the consumer's
deployment environment — the name is identical in every consumer environment.

The sweeper's default target (`le-cert-staging-…`, `letsencrypt-staging-account-…`) and
protected (`letsencrypt-production-account-…`, `cert-…`) prefixes are derived from this scheme.

### The `IssuedBy` tag: which certificates are the warden's

Every certificate the warden imports is tagged `IssuedBy=<ACME directory URL>`, next to the
caller-supplied `ApplicationName`, `CreatedBy` and `Description` (an import **replaces** an
object's tags, so these are the only ones it keeps). The tag *name* is contract: it is how the
warden tells a certificate it issued from anything else at the same object name, and so which
budget a zone draws on (§1). The value is informational.

That distinction exists for **placeholders**. A consumer may seed a self-signed certificate at a
zone's slot name so that, for example, Application Gateway can reference the secret before the
first run ([consumer-prerequisites.md](consumer-prerequisites.md#key-vault-expectations)). Without
the tag, that object reads as a certificate in service, and the zone as renewal work: a run with
`max-renewals-per-run: none` defers it, and a capped run makes it wait behind every due renewal.

So, for anyone creating objects at a slot name:

- **Never put `IssuedBy` on a placeholder.** It would be classed as a renewal until the warden
  replaces it — the behaviour this tag exists to prevent.
- **Nothing else is needed.** The warden's first import replaces the placeholder's tags with its
  own, so the zone becomes a renewal exactly when it gets its first real certificate. If your IaC
  manages the object, ignore changes to its tags (and certificate and policy), or it will try to
  revert the import.
- Renaming the tag would turn every zone in every consumer's vault into a first issuance at once,
  so treat it like an object name: a breaking change.

## 4. The bot notification contract (external)

The monitor posts `POST {BOT_API_BASE}/v1/notify/{alias}` with
`{"format": "adaptive-card", "message": <raw Adaptive Card object>, "metadata": {…}}` and a
bearer token for `BOT_API_AUDIENCE` — the API of the
[Teams Notification Bot](https://github.com/dsb-norge/teams-notifier-function-app). That
contract is owned by the bot; this repo pins the request shape in its integration tests and
revisits on a breaking bot-API change.

## 5. The vault lock (reusable workflows)

`reusable-warden.yml` and `reusable-sweeper.yml` both write to the Key Vault, so their jobs share
one GitHub concurrency group per vault:

```yaml
concurrency:
  group: cert-warden-vault-${{ inputs.key-vault-name }}
  cancel-in-progress: false
  queue: max
```

- **Keyed on the vault, not the environment.** Every run that targets a vault waits for the
  others: the warden, a sweep, a canary pointed at the dev vault. Callers don't have to agree
  on a group name.
- **Nothing is cancelled**, whether it's in progress or waiting. `queue: max` keeps up to 100
  pending runs per vault and starts them roughly in the order they began waiting (GitHub's
  ordering is best-effort). The order doesn't matter, because every run reads the vault fresh.
  GitHub's default queue holds only one pending run, and a third arrival cancels it. That
  silently dropped work, because runs are not interchangeable: a scheduled renewal pass, a
  deploy-chained pass that renews nothing, a sweep.
- **Per calling repository**, like every concurrency group. Two repositories that manage the
  same vault are not serialised against each other, so a vault should have one managing
  repository.
- **The group name is public API.** A workflow that composes the actions directly and writes
  to the vault joins the lock by using the same group, with `cancel-in-progress: false` and
  `queue: max`. Renaming the group is a major release.
- **A caller must not cancel around it.** A `cancel-in-progress: true` group on the calling
  workflow or job still cancels the whole run, including a job that holds the lock or is
  waiting for it.
