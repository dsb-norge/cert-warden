# Cert Warden

Automated Let's Encrypt certificate maintenance for Azure DNS zones and Azure Key Vault,
delivered as a suite of GitHub Actions composite actions and reusable workflows:

- **warden** — enumerates delegated public DNS zones, issues/renews certificates via the
  [lego](https://github.com/go-acme/lego) ACME client (DNS-01, ARI-driven renewal timing),
  and imports them into Azure Key Vault. Consumers such as Azure Application Gateway read the
  certificates from Key Vault via versionless secret IDs and rotate automatically.
- **monitor** — evaluates each warden run against a lifetime-fraction SLO and (optionally)
  notifies a [Teams Notification Bot](https://github.com/dsb-norge/teams-notifier-function-app).
- **sweeper** — soft-deletes orphaned/expired Key Vault objects, with dry-run defaults and
  spike guards.

> **Status: pre-release scaffolding.** The suite is being extracted from DSB-internal
> automation. Do not consume until `v1.0.0` is tagged.

## Documentation

- `docs/reference-usage.md` — how to call the suite (start here as a consumer)
- `docs/consumer-prerequisites.md` — Azure identity, Key Vault, and runner requirements
- `docs/development-and-ci.md` — how to make changes; how CI, previews, and releases work
- `docs/testing.md` — the test-implementation spec
- `docs/contracts.md` — env-var contract, metrics schema, Key Vault naming scheme
- `docs/design/` — design history (extraction feasibility and the repo design spec)

## License

[MIT](LICENSE)
