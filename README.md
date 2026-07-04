# Cert Warden

Automated Let's Encrypt certificate maintenance for Azure DNS zones and Azure Key Vault,
delivered as GitHub Actions composite actions and reusable workflows:

- **warden** — enumerates delegated public DNS zones, issues/renews certificates via the
  [lego](https://github.com/go-acme/lego) ACME client (DNS-01 challenges against Azure DNS,
  renewal timing driven by ARI/RFC 9773), and imports them into Azure Key Vault. Consumers
  such as Azure Application Gateway read the certificates via versionless secret ids and
  rotate automatically — no certificates in Terraform state, no deploy-time renewals.
- **monitor** — evaluates each warden run against a lifetime-fraction SLO (pages only on
  *sustained* renewal failure, never on a single red run) and optionally notifies a
  [Teams Notification Bot](https://github.com/dsb-norge/teams-notifier-function-app).
- **sweeper** — soft-deletes orphaned/expired Key Vault objects, dry-run by default, with a
  spike guard.

> **Status: pre-release.** Do not consume until `v1.0.0` is tagged.

## Quickstart (consumer)

```yaml
jobs:
  warden:
    permissions:
      id-token: write
    uses: dsb-norge/cert-warden/.github/workflows/reusable-warden.yml@<sha> # vX.Y.Z
    with:
      environment: "test"
      runs-on: "my-runner-label"
      azure-tenant-id: "…"
      azure-subscription-id: "…"
      azure-client-id: "…" # cert-maintainer identity, OIDC
      key-vault-name: "kv-my-web-certs-test"
      dns-rg-name: "rg-my-dns-test"
      le-environment: "staging" # always start on staging
      le-account-email: "certs@example.com"
      tag-application-name: "My platform (test) DNS zones"
```

Full callers (schedules, monitoring, sweeper + its graduation ladder):
**[docs/reference-usage.md](docs/reference-usage.md)**. Azure-side requirements
(identities, Key Vault, network, runners): **[docs/consumer-prerequisites.md](docs/consumer-prerequisites.md)**.

## Documentation

| Doc | For |
|---|---|
| [reference-usage.md](docs/reference-usage.md) | Consumers: the standard callers |
| [consumer-prerequisites.md](docs/consumer-prerequisites.md) | Consumers: what your landing zone must provide |
| [contracts.md](docs/contracts.md) | The SemVer-covered contracts (env vars, metrics schema, KV naming) |
| [development-and-ci.md](docs/development-and-ci.md) | Contributors: commits, preview refs, releases |
| [testing.md](docs/testing.md) | Contributors: the test layers, the harness, the pitfalls catalogue |
| [security-tooling.md](docs/security-tooling.md) | Maintainers: zizmor/pinact/guards and how to respond |
| [reference-usage-canary.md](docs/reference-usage-canary.md) | Prototype: caller-side LE-staging canary |
| [docs/design/](docs/design/) | Design history (imported) |

## How it's tested

Real `lego` performing real ACME issuance against
[Pebble](https://github.com/letsencrypt/pebble) in CI, with Azure faked only at the `az` CLI
boundary — where the fake *validates* the artifacts (real openssl chain verification against
Pebble's root). Every PR also publishes a `preview/pr-<N>` tag consumable from any repo, and
CI consumes it through GitHub's real remote-fetch path. Details: [docs/testing.md](docs/testing.md).

## Provenance

Derived from DSB-internal certificate automation, extracted and hardened for reuse.

## License

[MIT](LICENSE)
