#!/usr/bin/env bash
#
# Run the warden from a laptop for dev/debugging. All configuration comes from an env file so
# no organisation-specific values live in this (public) repo.
#
# Usage:
#   scripts/run-local.sh <env-file> [warden|sweeper|monitor]
#
# The env file is plain KEY=VALUE lines matching the script contracts (docs/contracts.md), e.g.:
#
#   AZ_TENANT_ID=00000000-0000-0000-0000-000000000000
#   AZ_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000
#   AZ_DNS_RG_NAME=my-dns-rg
#   AZ_CERT_KV_NAME=my-web-certs-kv
#   LE_NEW_ACCOUNT_EMAIL=certs@example.com
#   LE_ENVIRONMENT_NAME=staging
#   CERT_AZ_RESOURCE_TAG_ApplicationName=my-app
#   CERT_AZ_RESOURCE_TAG_CreatedBy=https://github.com/my-org/my-repo
#   CERT_AZ_RESOURCE_TAG_Description=Managed by Cert Warden. Do not modify manually.
#
# Prerequisites: az login as an identity with the documented RBAC + a network path to the
# Key Vault (see docs/consumer-prerequisites.md); lego, jq, openssl, dig on PATH.
#
set -euo pipefail
shopt -s inherit_errexit

envFile="${1:?usage: run-local.sh <env-file> [warden|sweeper|monitor]}"
tool="${2:-warden}"

[[ -f "${envFile}" ]] || {
  echo "env file not found: ${envFile}" >&2
  exit 1
}

repoRoot="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

set -o allexport
# shellcheck source=/dev/null
source "${envFile}"
source "${repoRoot}/lib/helpers.bash"
set +o allexport

case "${tool}" in
  warden) exec bash "${repoRoot}/actions/warden/cert-warden.sh" ;;
  sweeper) exec bash "${repoRoot}/actions/sweeper/sweeper.sh" ;;
  monitor) exec bash "${repoRoot}/actions/monitor/monitor.sh" ;;
  *)
    echo "unknown tool: ${tool} (expected warden|sweeper|monitor)" >&2
    exit 1
    ;;
esac
