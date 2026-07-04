#!/usr/bin/env bats
# Suite-wide shellcheck relaxations, inherent to bats suites that source the script under test
# via variables: SC1090 (non-constant source), SC2154/SC2034 (globals assigned by the sourced
# script / consumed by it), SC2030/SC2031 (bats runs each test in a subshell by design).
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
#
# L2 integration: the REAL warden script doing REAL ACME issuance with the REAL lego binary
# against Pebble (-strict), with DNS-01 served by challtestsrv (lego `exec` hook), delegation
# checks answered by CoreDNS, and Azure faked only at the az CLI boundary — whose
# `certificate import` performs real openssl parsing + chain verification against Pebble's
# per-boot root. See docs/testing.md.
#
# Scenarios build on each other IN ORDER within this file (shared state dir): issuance ->
# ARI-skip -> SAN-mismatch reissue -> partial failure -> monitor/sweeper over the real state.
#
# Requires: docker (compose), lego, jq, openssl, dig. Skips cleanly when missing.

load ../test_helper

HARNESS="${REPO_ROOT}/tests/harness"

setup_file() {
  if ! command -v docker >/dev/null || ! command -v lego >/dev/null; then
    export CW_L2_SKIP="missing docker and/or lego"
    return 0
  fi

  docker compose -f "${HARNESS}/docker-compose.pebble.yml" up -d --wait 2>/dev/null || {
    export CW_L2_SKIP="docker compose up failed"
    return 0
  }

  # Pebble ready? (trust anchor: the vendored static minica pem; SAN covers localhost)
  local tries=0
  until curl -fsS --cacert "${HARNESS}/pebble.minica.pem" https://localhost:14000/dir >/dev/null 2>&1; do
    tries=$((tries + 1))
    if ((tries > 30)); then
      export CW_L2_SKIP="pebble did not become ready"
      return 0
    fi
    sleep 1
  done

  # Per-boot issuance root — used by the az shim for REAL chain verification on import.
  curl -fsSk https://localhost:15000/roots/0 -o "${BATS_FILE_TMPDIR}/pebble-root.pem"

  # CoreDNS serving the test zones' NS records?
  dig +short +timeout=5 NS cw-test.internal @127.0.0.1 -p 5354 | grep -q ns1 || {
    export CW_L2_SKIP="coredns not answering"
    return 0
  }

  # Shared, ordered state across the scenarios in this file.
  export CW_STATE="${BATS_FILE_TMPDIR}/az-state"
  mkdir -p "${CW_STATE}/fixtures"
  cat >"${CW_STATE}/fixtures/zones.json" <<'JSON'
[
  {"name": "cw-test.internal",      "nameServers": ["ns1.cw-test.internal."]},
  {"name": "zone2.cw-test.internal", "nameServers": ["ns1.zone2.cw-test.internal."]},
  {"name": "not-delegated.internal", "nameServers": ["ns.other.example."]}
]
JSON
}

teardown_file() {
  [[ -n "${CW_L2_SKIP:-}" ]] || docker compose -f "${HARNESS}/docker-compose.pebble.yml" down -v >/dev/null 2>&1 || true
}

setup() {
  [[ -z "${CW_L2_SKIP:-}" ]] || skip "${CW_L2_SKIP}"

  export CW_AZ_STATE_DIR="${CW_STATE}"
  export CW_TEST_VERIFY_CHAIN_ROOT="${BATS_FILE_TMPDIR}/pebble-root.pem"
  export PATH="${HARNESS}/az-shim:${PATH}"

  export_dummy_warden_env # AZ_*/LE_*/CERT_* dummies; LE_ENVIRONMENT_NAME=staging

  # Point every seam at the harness (see docs/contracts.md):
  export CW_ACME_DIRECTORY_URL="https://localhost:14000/dir"
  export LEGO_CA_CERTIFICATES="${HARNESS}/pebble.minica.pem"
  export CW_LEGO_DNS_PROVIDER="exec"
  export EXEC_PATH="${HARNESS}/challtestsrv-hook.sh"
  export EXEC_POLLING_INTERVAL="2"
  export EXEC_PROPAGATION_TIMEOUT="30"
  export CW_LEGO_DNS_RESOLVERS="127.0.0.1:8053"
  export CW_LEGO_EXTRA_ARGS="--dns.propagation.disable-ans"
  export CW_DIG_ARGS="@127.0.0.1 -p 5354"

  # File-scoped (not per-test) so later scenarios consume earlier scenarios' metrics —
  # e2e-5 feeds e2e-4's partial-failure metrics to the monitor.
  export METRICS_OUT="${BATS_FILE_TMPDIR}/last-metrics.json"
  export CERT_METRICS_OUTPUT_FILE="${METRICS_OUT}"
  unset GITHUB_STEP_SUMMARY || true
}

run_warden() {
  run bash "${WARDEN_SH}"
}

@test "e2e-1 first run: real ACME issuance lands verified certs in the vault" {
  run_warden
  assert_success

  # Both delegated zones issued; the non-delegated one recorded and skipped:
  run jq -r 'map({(.zone): .action}) | add | .["cw-test.internal"], .["zone2.cw-test.internal"], .["not-delegated.internal"]' "${METRICS_OUT}"
  assert_output "issued
issued
not_delegated"

  # Cert objects exist with real-extracted SANs (apex + wildcard):
  run jq -r '.sans | sort | join(",")' "${CW_STATE}/certs/le-cert-staging-cw-test-internal-pfx.json"
  assert_output "*.cw-test.internal,cw-test.internal"

  # The shim performed REAL chain verification against Pebble's per-boot root:
  run grep -c "chain VERIFIED against test root" "${CW_STATE}/calls.log"
  assert_output "2"

  # LE account captured to the vault (email/key/json secrets):
  [ -f "${CW_STATE}/secrets/letsencrypt-staging-account-key" ]
  [ -f "${CW_STATE}/secrets/letsencrypt-staging-account-json" ]

  # ARI metadata persisted per cert:
  [ -f "${CW_STATE}/secrets/le-cert-staging-cw-test-internal-pfx-meta" ]
}

@test "e2e-2 second run: existing certs recognised, ARI says not due, nothing re-issued" {
  run_warden
  assert_success
  assert_output --partial "Reading Let's Encrypt account details from KeyVault"

  run jq -r 'map({(.zone): .action}) | add | .["cw-test.internal"], .["zone2.cw-test.internal"]' "${METRICS_OUT}"
  assert_output "skipped
skipped"
}

@test "e2e-3 SAN drift: new A record forces a re-issue with the new SAN set" {
  cat >"${CW_STATE}/fixtures/recordsets-cw-test.internal.json" <<'JSON'
[
  {"name": "www", "type": "Microsoft.Network/dnszones/A"},
  {"name": "@",   "type": "Microsoft.Network/dnszones/A"}
]
JSON
  run_warden
  assert_success
  assert_output --partial "does not match A records"

  run jq -r '.[] | select(.zone == "cw-test.internal") | .action' "${METRICS_OUT}"
  assert_output "issued"
  # New cert's real SANs match the new record set (apex + www, no wildcard):
  run jq -r '.sans | sort | join(",")' "${CW_STATE}/certs/le-cert-staging-cw-test-internal-pfx.json"
  assert_output "cw-test.internal,www.cw-test.internal"

  # NOTE: the record-set fixture stays in place so e2e-4 sees a matching cert (ARI skip path).
}

@test "e2e-4 partial failure: one zone's challenge breaks; metrics survive, exit is non-zero" {
  # Force zone2 into a fresh issuance (drop its cert), then SERVFAIL its challenge record.
  rm -f "${CW_STATE}/certs/le-cert-staging-zone2-cw-test-internal-pfx.json" \
    "${CW_STATE}/secrets/le-cert-staging-zone2-cw-test-internal-pfx" \
    "${CW_STATE}/secrets/le-cert-staging-zone2-cw-test-internal-pfx-meta"
  curl -fsS -X POST -d '{"host":"_acme-challenge.zone2.cw-test.internal."}' \
    http://127.0.0.1:8055/set-servfail >/dev/null

  run_warden
  assert_failure # error count > 0 -> non-zero exit

  # THE regression this suite exists for: a partial failure must still emit full metrics.
  run jq -r 'map({(.zone): .action}) | add | .["cw-test.internal"], .["zone2.cw-test.internal"]' "${METRICS_OUT}"
  assert_output "skipped
failed"
  run jq -r '.[] | select(.zone == "zone2.cw-test.internal") | .error' "${METRICS_OUT}"
  assert_output --partial "Let's Encrypt"

  curl -fsS -X POST -d '{"host":"_acme-challenge.zone2.cw-test.internal."}' \
    http://127.0.0.1:8055/clear-servfail >/dev/null
}

@test "e2e-5 monitor consumes the partial-failure metrics and POSTs a real Adaptive Card to the sink" {
  # Bot sink on a local port; the monitor's az call for a token hits the shim.
  local sinklog="${BATS_TEST_TMPDIR}/sink.log"
  python3 "${HARNESS}/bot-sink/sink.py" 8025 "${sinklog}" &
  local sinkpid=$!
  # Close bats' fd3 in the daemon path and give the sink a beat to bind.
  sleep 1

  ENV_NAME="l2" METRICS_FILE="${METRICS_OUT}" DRY_RUN="false" \
    BOT_API_BASE="http://127.0.0.1:8025/api" BOT_API_AUDIENCE="api://l2-test" \
    BOT_ALIAS="from-l2" run bash "${MONITOR_SH}"
  kill "${sinkpid}" 2>/dev/null || true
  assert_success
  assert_output --partial "severity=WARNING" # 1 failed zone, healthy lifetime elsewhere

  run jq -r '.path, .authorization, .body.format, .body.message.type' "${sinklog}"
  assert_output "/api/v1/notify/from-l2
Bearer az-shim-test-token
adaptive-card
AdaptiveCard"
}

@test "e2e-6 sweeper over the real vault state: candidates listed, KV delete semantics honoured" {
  # The staging certs issued above are exactly what the default target prefixes match.
  KV_NAME="kv-l2" LOG_ONLY="true" run bash "${SWEEPER_SH}"
  assert_success
  assert_output --partial "DELETE  : le-cert-staging-cw-test-internal-pfx [orphan-name]"
  [ -f "${CW_STATE}/certs/le-cert-staging-cw-test-internal-pfx.json" ] # dry run deleted nothing

  KV_NAME="kv-l2" LOG_ONLY="false" run bash "${SWEEPER_SH}"
  assert_success
  # Cert gone AND its backing secret gone via the cert delete (KV semantics in the shim);
  # the -meta and account secrets deleted as plain secrets.
  [ ! -f "${CW_STATE}/certs/le-cert-staging-cw-test-internal-pfx.json" ]
  [ ! -f "${CW_STATE}/secrets/le-cert-staging-cw-test-internal-pfx" ]
  [ ! -f "${CW_STATE}/secrets/le-cert-staging-cw-test-internal-pfx-meta" ]
  [ ! -f "${CW_STATE}/secrets/letsencrypt-staging-account-key" ]
}
