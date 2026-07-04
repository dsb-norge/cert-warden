#!/usr/bin/env bash
#
# Shared bats test helper. Loaded by every suite via `load ../test_helper`.
#
# Library resolution: CI (bats-core/bats-action) exports BATS_LIB_PATH; locally, point it at
# your clones of bats-support/bats-assert (see docs/testing.md), e.g.:
#   export BATS_LIB_PATH="$HOME/tools/bats-libs"

export BATS_LIB_PATH="${BATS_LIB_PATH:-/usr/lib:${HOME}/tools/bats-libs}"

bats_load_library bats-support
bats_load_library bats-assert

# Repo root (tests/ is one level below).
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

WARDEN_SH="${REPO_ROOT}/actions/warden/cert-warden.sh"
MONITOR_SH="${REPO_ROOT}/actions/monitor/monitor.sh"
SWEEPER_SH="${REPO_ROOT}/actions/sweeper/sweeper.sh"
HELPERS_BASH="${REPO_ROOT}/lib/helpers.bash"
export WARDEN_SH MONITOR_SH SWEEPER_SH HELPERS_BASH

# Minimal valid warden configuration — enough for loadConfig() under `set -u`.
export_dummy_warden_env() {
  export AZ_TENANT_ID="test-tenant"
  export AZ_SUBSCRIPTION_ID="test-sub"
  export AZ_DNS_RG_NAME="test-rg"
  export AZ_CERT_KV_NAME="test-kv"
  export LE_NEW_ACCOUNT_EMAIL="test@example.test"
  export LE_ENVIRONMENT_NAME="staging"
  export CERT_AZ_RESOURCE_TAG_ApplicationName="test-app"
  export CERT_AZ_RESOURCE_TAG_CreatedBy="test-created-by"
  export CERT_AZ_RESOURCE_TAG_Description="test-description"
}

# Write a metrics fixture (JSON array of per-zone records, schema per docs/contracts.md) to the
# given path. Pass records as individual JSON-object arguments.
write_metrics_fixture() {
  local path="${1}"
  shift
  printf '%s\n' "${@}" | jq -s '.' >"${path}"
}
