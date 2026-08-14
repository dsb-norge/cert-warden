#!/usr/bin/env bash
#
# Shared bats test helper. Loaded by every suite via `load ../test_helper`.
#
# Library resolution: bats-support/bats-assert are VENDORED in tests/vendor (see its README
# for the supply-chain rationale) — no setup needed locally or in CI.

# Repo root (tests/ is one level below).
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# The vendored path goes FIRST, deliberately ahead of whatever is already in BATS_LIB_PATH:
# bats >=1.14 pre-seeds BATS_LIB_PATH=/usr/lib/bats, so appending would let a system copy of
# the helper libs silently shadow the reviewed vendored ones. Determinism is the point of
# vendoring — the committed copy must be the one that loads, everywhere.
export BATS_LIB_PATH="${REPO_ROOT}/tests/vendor${BATS_LIB_PATH:+:${BATS_LIB_PATH}}:/usr/lib:${HOME}/tools/bats-libs"

bats_load_library bats-support
bats_load_library bats-assert

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
