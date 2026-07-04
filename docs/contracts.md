# Contracts

The suite's public API is more than the action/workflow inputs — three cross-component
contracts are covered by SemVer. Breaking any of them is a **major** release with a migration
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
| `CERT_METRICS_OUTPUT_FILE` | no | Where the metrics artifact is written |

### monitor (`actions/monitor/monitor.sh`)

`METRICS_FILE`, `ENV_NAME`, `WARN_THRESHOLD` (0.40), `PAGE_THRESHOLD` (0.15),
`LIVENESS_WINDOW_HOURS` (36), `CERT_WARDEN_CONCLUSION`, `CERT_WARDEN_RUN_URL`,
`METRICS_AGE_HOURS`, `BOT_API_BASE`, `BOT_API_AUDIENCE`, `BOT_ALIAS`, `FORCE_NOTIFY`,
`DRY_RUN`. All optional; without the bot triple the monitor is evaluate-only. Exit code is
always 0 on a completed evaluation.

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

## 4. The bot notification contract (external)

The monitor posts `POST {BOT_API_BASE}/v1/notify/{alias}` with
`{"format": "adaptive-card", "message": <raw Adaptive Card object>, "metadata": {…}}` and a
bearer token for `BOT_API_AUDIENCE` — the API of the
[Teams Notification Bot](https://github.com/dsb-norge/teams-notifier-function-app). That
contract is owned by the bot; this repo pins the request shape in its integration tests and
revisits on a breaking bot-API change.
