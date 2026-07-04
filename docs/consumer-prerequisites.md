# Consumer prerequisites

What your Azure landing zone must provide before calling the suite. Everything here is
**described with self-contained example declarations** — adapt names to your conventions.

## The moving parts

| You provide | Used by | Purpose |
|---|---|---|
| Public DNS zones in one resource group | warden | The zones to maintain certificates for |
| A Key Vault (RBAC mode) | warden, sweeper | Stores certs, LE account material, ARI metadata |
| A **cert-maintainer** user-assigned identity + federated credential | warden, sweeper | OIDC login from your caller workflow |
| A self-hosted runner with a network path to the Key Vault | warden, sweeper | The KV is typically private-endpoint-only |
| (optional) A **monitor** identity with `Notifications.Send` on your Teams Notification Bot | monitor | Bot delivery |
| (optional) A certificate consumer (e.g. Application Gateway) reading the versionless secret id | — | Auto-rotation |

## Identity and RBAC (example Terraform)

```hcl
resource "azurerm_user_assigned_identity" "cert_maintainer" {
  name                = "uai-cert-warden"
  resource_group_name = azurerm_resource_group.certs.name
  location            = azurerm_resource_group.certs.location
}

# OIDC from GitHub Actions. main-only by design: schedules and workflow_run chains execute on
# the default branch, and a branch-scoped subject prevents dispatching cert operations from
# arbitrary branches (a branch dispatch fails AADSTS700213 — expected, not a bug).
resource "azurerm_federated_identity_credential" "cert_maintainer_github" {
  name                = "github-main"
  resource_group_name = azurerm_resource_group.certs.name
  parent_id           = azurerm_user_assigned_identity.cert_maintainer.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:<your-org>/<your-repo>:ref:refs/heads/main"
}

# Key Vault (RBAC mode): the maintainer imports certificates and reads/writes secrets.
resource "azurerm_role_assignment" "kv_certificates_officer" {
  scope                = azurerm_key_vault.web_certs.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = azurerm_user_assigned_identity.cert_maintainer.principal_id
}

resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.web_certs.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.cert_maintainer.principal_id
}

# DNS: least-privilege custom role for the DNS-01 challenge — TXT records only, plus reads.
resource "azurerm_role_definition" "dns_txt_contributor" {
  name        = "DNS TXT Record Contributor (cert-warden)"
  scope       = azurerm_resource_group.dns.id
  description = "Write TXT record sets for ACME DNS-01 challenges; read zones."
  permissions {
    actions = [
      "Microsoft.Network/dnsZones/read",
      "Microsoft.Network/dnsZones/recordsets/read",
      "Microsoft.Network/dnsZones/TXT/read",
      "Microsoft.Network/dnsZones/TXT/write",
      "Microsoft.Network/dnsZones/TXT/delete",
    ]
  }
  assignable_scopes = [azurerm_resource_group.dns.id]
}

resource "azurerm_role_assignment" "dns_txt" {
  scope              = azurerm_resource_group.dns.id
  role_definition_id = azurerm_role_definition.dns_txt_contributor.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.cert_maintainer.principal_id
}
```

The warden also calls `az network dns record-set list` and `az network dns zone list` — the
reads above cover it (`recordsets/read` spans record types).

## Key Vault expectations

- **RBAC authorization mode** (not access policies).
- Typically `public_network_access_enabled = false` with a private endpoint — which is why the
  runner needs a network path (below). If your certificate consumer is an Azure service
  reading via trusted-services (e.g. Application Gateway), set
  `network_acls { bypass = "AzureServices" }`.
- Soft delete stays on (the sweeper relies on it: everything it deletes is recoverable for
  the retention window).
- Seed a **placeholder** certificate at the production slot name
  (`le-cert-production-<zone-dashed>-pfx`, see [contracts.md](contracts.md) §3) if a consumer
  like Application Gateway must reference the secret id before the warden's first run.

## Runner and network

- A **self-hosted Linux runner** whose network reaches: the Key Vault data plane (private
  endpoint), `login.microsoftonline.com`, the Let's Encrypt API
  (`acme-v02.api.letsencrypt.org` / `acme-staging-v02.api.letsencrypt.org`, port 443), public
  DNS resolution (the delegation check queries public resolvers), and — install-time — the Go
  module proxy (`proxy.golang.org`) for `setup-lego`. Egress-filtered environments must
  allow-list these.
- Runner prerequisites: `bash` ≥ 4.4, `az`, `jq`, `openssl`, `dig`, `go` (for setup-lego),
  `curl`.
- The monitor's evaluate-only mode runs fine on GitHub-hosted runners; bot delivery needs a
  path to your bot's endpoint.

## Let's Encrypt planning

- **Start every new consumer on `staging`** and promote to `production` via a one-line change
  after a clean staging run (SAN parity verified). Staging issues browser-untrusted certs —
  fine behind a placeholder strategy.
- One LE account per environment is created automatically on first run (email from
  `le-account-email`) and stored in the vault; use a team mailbox.
- **Production rate limits are your responsibility**: count your zones against LE's
  certificates-per-registered-domain weekly limit before promoting. Renewals driven by ARI are
  exempt from most limits, and the warden renews well ahead of expiry, so steady-state usage
  is minimal — the limit matters for first onboarding and forced reissues.
- Alerting thresholds are lifetime-relative (`min_lifetime_fraction`), so shorter LE
  lifetimes need no re-tuning.

## Bot delivery (optional)

A deployed [Teams Notification Bot](https://github.com/dsb-norge/teams-notifier-function-app),
an alias for your channel, and a monitor identity: a UAMI with a federated credential (same
`main`-only subject pattern) holding the bot API app's `Notifications.Send` app role. The
monitor identity needs **no subscription RBAC** (the reusable workflow logs in with
`allow-no-subscriptions`).
