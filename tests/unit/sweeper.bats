#!/usr/bin/env bats
# Suite-wide shellcheck relaxations, inherent to bats suites that source the script under test
# via variables: SC1090 (non-constant source), SC2154/SC2034 (globals assigned by the sourced
# script / consumed by it), SC2030/SC2031 (bats runs each test in a subshell by design).
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Unit tests for actions/sweeper/sweeper.sh — run as a process against a PATH-shim `az` serving
# fixture data. Covers the selection rules (protected > target > expiry), the LOG_ONLY default,
# the cert-backing-secret dedup, and the MAX_DELETIONS spike guard.

load ../test_helper

setup() {
  export KV_NAME="kv-unittest"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  export AZ_STUB_CALLS="${BATS_TEST_TMPDIR}/az-calls.log"
  export AZ_STUB_CERTS_JSON="${BATS_TEST_TMPDIR}/certs.json"
  export AZ_STUB_SECRETS_TSV="${BATS_TEST_TMPDIR}/secrets.tsv"
  : >"${AZ_STUB_CALLS}"
  echo "[]" >"${AZ_STUB_CERTS_JSON}"
  : >"${AZ_STUB_SECRETS_TSV}"

  # Minimal az shim mirroring exactly the four subcommands the sweeper calls. Fixture shapes
  # match the real CLI's output for the exact --query expressions used (captured, not invented).
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/az" <<'AZSTUB'
#!/usr/bin/env bash
set -euo pipefail
echo "az $*" >>"${AZ_STUB_CALLS}"
case "$1 $2 $3" in
  "keyvault certificate list") cat "${AZ_STUB_CERTS_JSON}" ;;
  "keyvault secret list") cat "${AZ_STUB_SECRETS_TSV}" ;;
  "keyvault certificate delete") exit 0 ;;
  "keyvault secret delete") exit 0 ;;
  *)
    echo "az stub: unhandled: $*" >&2
    exit 64
    ;;
esac
AZSTUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/az"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

# --- fixtures ---------------------------------------------------------------------------------

seed_typical_vault() {
  # Shape = output of: az keyvault certificate list --query "[].{name:name, exp:attributes.expires}" -o json
  cat >"${AZ_STUB_CERTS_JSON}" <<'JSON'
[
  {"name": "le-cert-production-live-example-pfx", "exp": "2099-01-01T00:00:00+00:00"},
  {"name": "le-cert-staging-orphan-example-pfx",  "exp": "2099-01-01T00:00:00+00:00"},
  {"name": "le-cert-production-lapsed-zone-pfx",  "exp": "2001-01-01T00:00:00+00:00"},
  {"name": "cert-legacy-acme-import",             "exp": "2001-01-01T00:00:00+00:00"}
]
JSON
  # Shape = output of: az keyvault secret list --query "[].name" -o tsv
  cat >"${AZ_STUB_SECRETS_TSV}" <<'TSV'
le-cert-production-live-example-pfx
le-cert-staging-orphan-example-pfx
le-cert-staging-orphan-example-pfx-meta
letsencrypt-staging-account-key
letsencrypt-production-account-key
TSV
}

# --- tests ------------------------------------------------------------------------------------

@test "LOG_ONLY default: evaluates, deletes nothing, exit 0" {
  seed_typical_vault
  run bash "${SWEEPER_SH}"
  assert_success
  assert_output --partial "LOG_ONLY=true — nothing deleted"
  run grep -c "delete" "${AZ_STUB_CALLS}"
  assert_output "0"
}

@test "selection: staging orphans and expired certs targeted; protected + live spared" {
  seed_typical_vault
  run bash "${SWEEPER_SH}"
  assert_success
  # Orphan by name pattern:
  assert_output --partial "DELETE  : le-cert-staging-orphan-example-pfx [orphan-name]"
  # Expired production cert = orphan by expiry (live certs never expire; deliberately unprotected):
  assert_output --partial "DELETE  : le-cert-production-lapsed-zone-pfx [expired"
  # Protected prefixes always win — even over expiry:
  assert_output --partial "protect : cert-legacy-acme-import"
  assert_output --partial "protect : letsencrypt-production-account-key"
  # Live production cert kept:
  assert_output --partial "keep    : le-cert-production-live-example-pfx"
}

@test "SWEEP_EXPIRED=false keeps expired certs" {
  seed_typical_vault
  export SWEEP_EXPIRED="false"
  run bash "${SWEEPER_SH}"
  assert_success
  assert_output --partial "keep    : le-cert-production-lapsed-zone-pfx"
}

@test "destructive run deletes candidates and dedups cert-backing secrets" {
  seed_typical_vault
  export LOG_ONLY="false"
  run bash "${SWEEPER_SH}"
  assert_success
  # Certs deleted:
  run grep -c "^az keyvault certificate delete" "${AZ_STUB_CALLS}"
  assert_output "2"
  # Secrets: staging-orphan secret is the cert-backing secret of a deleted cert -> deduped;
  # the -meta and staging-account secrets are deleted.
  run grep "keyvault secret delete" "${AZ_STUB_CALLS}"
  assert_output --partial "le-cert-staging-orphan-example-pfx-meta"
  assert_output --partial "letsencrypt-staging-account-key"
  run grep -c "secret delete --vault-name kv-unittest --name le-cert-staging-orphan-example-pfx$" "${AZ_STUB_CALLS}"
  assert_output "0"
}

@test "MAX_DELETIONS spike guard aborts before deleting" {
  seed_typical_vault
  export LOG_ONLY="false"
  export MAX_DELETIONS="1"
  run bash "${SWEEPER_SH}"
  assert_failure
  assert_output --partial "exceeds MAX_DELETIONS=1"
  run grep -c "delete" "${AZ_STUB_CALLS}"
  assert_output "0"
}

@test "empty vault: destructive run is a clean no-op" {
  export LOG_ONLY="false"
  run bash "${SWEEPER_SH}"
  assert_success
  assert_output --partial "Nothing to delete"
}

@test "step summary written with mode and counts" {
  seed_typical_vault
  run bash "${SWEEPER_SH}"
  assert_success
  run cat "${GITHUB_STEP_SUMMARY}"
  assert_output --partial "Cert Warden sweeper"
  assert_output --partial "log-only (dry run)"
  assert_output --partial "Certificates to delete: **2**"
}
