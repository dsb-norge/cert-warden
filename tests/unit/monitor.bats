#!/usr/bin/env bats
# Suite-wide shellcheck relaxations, inherent to bats suites that source the script under test
# via variables: SC1090 (non-constant source), SC2154/SC2034 (globals assigned by the sourced
# script / consumed by it), SC2030/SC2031 (bats runs each test in a subshell by design).
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Unit tests for actions/monitor/monitor.sh — run as a process (its production invocation)
# against fixture metrics. The severity matrix is the contract: Layer A (lifetime SLO) pages,
# Layer C (job health/liveness) warns, and the script must ALWAYS exit 0.

load ../test_helper

setup() {
  export ENV_NAME="unittest"
  export DRY_RUN="true" # never POST anywhere in unit tests
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  METRICS="${BATS_TEST_TMPDIR}/metrics.json"
  export METRICS_FILE="${METRICS}"
}

healthy_record() {
  echo '{"zone":"a.example.test","action":"none","kv_cert_name":"le-cert-production-a-example-test-pfx","lifetime_fraction_remaining":0.85,"days_to_expiry":76,"error":""}'
}

@test "healthy metrics -> OK, no notification" {
  write_metrics_fixture "${METRICS}" "$(healthy_record)"
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "severity=OK"
  assert_output --partial "no notification sent"
}

@test "min lifetime fraction below page threshold -> CRITICAL with reason" {
  write_metrics_fixture "${METRICS}" \
    "$(healthy_record)" \
    '{"zone":"b.example.test","action":"none","kv_cert_name":"le-cert-production-b-pfx","lifetime_fraction_remaining":0.10,"days_to_expiry":9,"error":""}'
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "severity=CRITICAL"
  assert_output --partial "b.example.test"
}

@test "min lifetime fraction below warn threshold -> WARNING" {
  write_metrics_fixture "${METRICS}" \
    '{"zone":"c.example.test","action":"none","kv_cert_name":"le-cert-production-c-pfx","lifetime_fraction_remaining":0.30,"days_to_expiry":27,"error":""}'
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "severity=WARNING"
}

@test "failed zone with healthy lifetime -> WARNING (never pages on a single failure)" {
  write_metrics_fixture "${METRICS}" \
    "$(healthy_record)" \
    '{"zone":"d.example.test","action":"failed","kv_cert_name":"le-cert-production-d-pfx","lifetime_fraction_remaining":null,"days_to_expiry":null,"error":"boom"}'
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "severity=WARNING"
  assert_output --partial "d.example.test"
}

@test "missing metrics file -> WARNING (absence is a signal), exit 0" {
  rm -f "${METRICS}"
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "severity=WARNING"
  assert_output --partial "no managed-cert metrics"
}

@test "stale metrics (liveness window) -> WARNING" {
  write_metrics_fixture "${METRICS}" "$(healthy_record)"
  export METRICS_AGE_HOURS="48"
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "severity=WARNING"
  assert_output --partial "liveness window"
}

@test "non-delegated zones are excluded from the SLO" {
  write_metrics_fixture "${METRICS}" \
    '{"zone":"nd.example.test","action":"not_delegated","kv_cert_name":"","lifetime_fraction_remaining":null,"days_to_expiry":null,"error":""}'
  run bash "${MONITOR_SH}"
  assert_success
  # No managed certs at all -> Layer C warning, not OK:
  assert_output --partial "severity=WARNING"
}

@test "DRY_RUN prints the Adaptive Card payload on breach (bot contract shape)" {
  write_metrics_fixture "${METRICS}" \
    '{"zone":"e.example.test","action":"none","kv_cert_name":"le-cert-production-e-pfx","lifetime_fraction_remaining":0.05,"days_to_expiry":4,"error":""}'
  export BOT_API_BASE="https://bot.invalid/api"
  export BOT_API_AUDIENCE="api://unittest"
  export BOT_ALIAS="from-unittest"
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "DRY_RUN — would POST"
  assert_output --partial "/v1/notify/from-unittest"
  # Raw Adaptive Card per the bot API contract (format + message object):
  assert_output --partial '"format": "adaptive-card"'
  assert_output --partial '"type": "AdaptiveCard"'
}

@test "FORCE_NOTIFY posts even when OK (delivery test path)" {
  write_metrics_fixture "${METRICS}" "$(healthy_record)"
  export FORCE_NOTIFY="true"
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "DRY_RUN — would POST"
}

@test "step summary is written with the metrics table" {
  write_metrics_fixture "${METRICS}" "$(healthy_record)"
  run bash "${MONITOR_SH}"
  assert_success
  run cat "${GITHUB_STEP_SUMMARY}"
  assert_output --partial "Cert Warden monitor — unittest — OK"
  assert_output --partial "min_lifetime_fraction"
}

@test "corrupt/truncated metrics JSON degrades to the absent-metrics path, exit 0 (review F2)" {
  printf '[{"zone":"trunc' >"${METRICS}" # a warden killed mid-write
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "missing, empty or unparsable"
  assert_output --partial "severity=WARNING"
}

@test "failed zone WITHOUT kv_cert_name still alerts (review F4)" {
  write_metrics_fixture "${METRICS}" \
    "$(healthy_record)" \
    '{"zone":"early-fail.example.test","action":"failed","kv_cert_name":"","lifetime_fraction_remaining":null,"days_to_expiry":null,"error":"failed to resolve SAN additional domains"}'
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "severity=WARNING"
  assert_output --partial "early-fail.example.test"
}

@test "evaluate-only mode (no bot config) emits no error annotation (review F9)" {
  write_metrics_fixture "${METRICS}" \
    '{"zone":"c.example.test","action":"none","kv_cert_name":"le-cert-production-c-pfx","lifetime_fraction_remaining":0.30,"days_to_expiry":27,"error":""}'
  export DRY_RUN="false" # bot config entirely absent -> evaluate-only, not a delivery attempt
  run bash "${MONITOR_SH}"
  assert_success
  assert_output --partial "evaluate-only mode"
  refute_output --partial "::error::"
}

@test "GITHUB_OUTPUT emission is machine-clean key=value (regression: log prefix corrupted keys)" {
  write_metrics_fixture "${METRICS}" \
    "$(healthy_record)" \
    '{"zone":"d.example.test","action":"failed","kv_cert_name":"le-cert-production-d-pfx","lifetime_fraction_remaining":null,"days_to_expiry":null,"error":"boom"}'
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_output"
  : >"${GITHUB_OUTPUT}"
  run bash "${MONITOR_SH}"
  assert_success
  # Every line must be bare key=value (no log prefixes, no stray text):
  run grep -vcE '^[a-z-]+=' "${GITHUB_OUTPUT}"
  assert_output "0"
  run grep -c '^severity=WARNING$' "${GITHUB_OUTPUT}"
  assert_output "1"
  run grep -c '^failed-count=1$' "${GITHUB_OUTPUT}"
  assert_output "1"
}
