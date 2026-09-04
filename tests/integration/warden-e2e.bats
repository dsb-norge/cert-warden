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
  # lego sleeps a random interval before every RENEWAL to smear fleet-wide load (the single
  # biggest contributor to a real run's wall clock — and the reason max-renewals-per-run exists).
  # Here it is pure padding: it exercises no code path, and a renewal scenario can otherwise sit
  # idle for minutes. lego's own env var, not a warden seam — the warden never sets it, so
  # production keeps the smearing that Let's Encrypt asks clients for.
  export LEGO_NO_RANDOM_SLEEP="true"

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

@test "e2e-7 chaos: issuance succeeds under 20% nonce rejection (retry path, fresh CA)" {
  # Restart Pebble with hostile nonces (fresh CA root + empty account state), single zone to
  # keep the runtime bounded, wiped vault so registration + issuance both run under chaos.
  cat >"${CW_STATE}/fixtures/zones.json" <<'JSON'
[ {"name": "cw-test.internal", "nameServers": ["ns1.cw-test.internal."]} ]
JSON
  rm -f "${CW_STATE}"/secrets/* "${CW_STATE}"/certs/* 2>/dev/null || true

  docker compose -f "${HARNESS}/docker-compose.pebble.yml" \
    -f "${HARNESS}/docker-compose.chaos.override.yml" up -d --wait pebble
  local tries=0
  until curl -fsS --cacert "${HARNESS}/pebble.minica.pem" https://localhost:14000/dir >/dev/null 2>&1; do
    tries=$((tries + 1))
    ((tries > 30)) && skip "pebble did not come back under chaos config"
    sleep 1
  done
  # New boot => new issuance root; the az shim verifies chains against this file.
  curl -fsSk https://localhost:15000/roots/0 -o "${BATS_FILE_TMPDIR}/pebble-root.pem"

  run_warden
  assert_success
  run jq -r '.[] | select(.zone == "cw-test.internal") | .action' "${METRICS_OUT}"
  assert_output "issued"
  run grep -c "chain VERIFIED against test root" <(tail -5 "${CW_STATE}/calls.log")
  assert_output "1"
}

@test "e2e-8 force flags: force-all-new reissues over a valid cert; force-renewal forces renewal" {
  # Runs against the chaos-configured Pebble from e2e-7 (single zone, valid cert in the
  # vault). Also the only run with a step summary attached — asserting the warden's summary
  # block (never otherwise executed; the markdown-corruption class needs a guard here too).
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"

  # force-all-new: existing matching cert must be ignored and a NEW cert issued.
  CERT_FORCE_ALL_NEW=true run_warden
  assert_success
  run jq -r '.[] | select(.zone == "cw-test.internal") | .action' "${METRICS_OUT}"
  assert_output "issued"

  # The summary is real markdown, free of log prefixes:
  run grep -c '^## Cert Warden' "${GITHUB_STEP_SUMMARY}"
  assert_output "1"
  run grep -c 'cw-test.internal' "${GITHUB_STEP_SUMMARY}"
  assert_output "1"
  run grep -c 'warden: ' "${GITHUB_STEP_SUMMARY}"
  assert_output "0"

  # force-renewal: matching cert + --renew-force => renewed now (ARI bypassed), action=forced.
  CERT_FORCE_RENEWAL=true run_warden
  assert_success
  run jq -r '.[] | select(.zone == "cw-test.internal") | .action' "${METRICS_OUT}"
  assert_output "forced"
}

@test "e2e-9 renewal cap: forcing respects the budget, and the next run drains the rest" {
  # Runs against the chaos-configured Pebble from e2e-7/8 (cw-test.internal holds a valid cert;
  # zone2 was dropped in e2e-4 and never re-issued, so it needs a fresh certificate).
  cat >"${CW_STATE}/fixtures/zones.json" <<'JSON'
[
  {"name": "cw-test.internal",      "nameServers": ["ns1.cw-test.internal."]},
  {"name": "zone2.cw-test.internal", "nameServers": ["ns1.zone2.cw-test.internal."]}
]
JSON

  # Budget of one, with force-renewal on: exactly the case that must not run away, since a
  # forced renewal of a whole environment is how a fleet ends up renewing in a single wave.
  : >"${CW_STATE}/calls.log"
  CERT_MAX_RENEWALS_PER_RUN=1 CERT_FORCE_RENEWAL=true run_warden
  assert_success
  assert_output --partial "Renewal budget for this run: 1"
  assert_output --partial "Renewal budget spent (1/1)"

  # cw-test.internal has a certificate and therefore an expiry; zone2 has none, so it sorts
  # last (nothing is in service for it that could expire) and is the one deferred.
  run jq -r 'map({(.zone): .action}) | add | .["cw-test.internal"], .["zone2.cw-test.internal"]' "${METRICS_OUT}"
  assert_output "forced
deferred"

  # The deferred zone was not evaluated at all — that is where the hours are saved. Not one
  # Azure call names it: no record-set listing, no certificate download, so no `lego run` and
  # none of lego's random renewal delay. And it is not an error, so it must carry none.
  run grep -c "zone2" "${CW_STATE}/calls.log"
  assert_output "0"
  run jq -r '.[] | select(.zone == "zone2.cw-test.internal") | .error' "${METRICS_OUT}"
  assert_output ""

  # A deferred record still names its Key Vault object, so the monitor keeps counting it as a
  # managed certificate rather than losing sight of it.
  run jq -r '.[] | select(.zone == "zone2.cw-test.internal") | .kv_cert_name' "${METRICS_OUT}"
  assert_output "le-cert-staging-zone2-cw-test-internal-pfx"

  # Next run, same cap, no force: the freshly forced cert is not due (ARI says so), that costs
  # nothing against the budget, and the deferred zone is picked up. No state carried over —
  # dueness alone got us here.
  CERT_MAX_RENEWALS_PER_RUN=1 run_warden
  assert_success
  run jq -r 'map({(.zone): .action}) | add | .["cw-test.internal"], .["zone2.cw-test.internal"]' "${METRICS_OUT}"
  assert_output "skipped
issued"

  # Third run: force again, now that BOTH zones hold a certificate. This is the case the whole
  # design turns on — a deferred zone with a certificate in the vault must carry that
  # certificate's real validity window, because lifetime_fraction_remaining is the monitor's SLO
  # input and a null there would drop the zone out of the alert entirely. The cap would then look
  # like a success precisely while hiding a backlog that had stopped draining.
  CERT_MAX_RENEWALS_PER_RUN=1 CERT_FORCE_RENEWAL=true run_warden
  assert_success
  # Freshly issued, so the cap can comfortably drain it: the sizing guard stays quiet. Asserted
  # here, before any other `run` overwrites $output with its own (pitfall: `run` is the capture).
  refute_output --partial "::warning::"

  # zone2 was issued a moment ago, so it expires LAST and is the one deferred — urgency order.
  run jq -r 'map({(.zone): .action}) | add | .["cw-test.internal"], .["zone2.cw-test.internal"]' "${METRICS_OUT}"
  assert_output "forced
deferred"
  # THE property: a deferred zone that holds a certificate reports that certificate's real
  # window, which only the Key Vault pre-pass can supply.
  run jq -e '
    .[] | select(.zone == "zone2.cw-test.internal")
    | .days_to_expiry != null
      and .lifetime_fraction_remaining != null
      and .lifetime_fraction_remaining > 0.9
      and .not_after != ""
  ' "${METRICS_OUT}"
  assert_success

  # Fourth run: the wave has drained, so the cap has nothing left to defer and says nothing.
  CERT_MAX_RENEWALS_PER_RUN=1 run_warden
  assert_success
  refute_output --partial "Renewal budget spent"
  refute_output --partial "::warning::"
  run jq -r '[.[] | select(.action == "deferred")] | length' "${METRICS_OUT}"
  assert_output "0"
}

@test "e2e-10 no cap set: enumeration order and the artifact are untouched" {
  # The compatibility guarantee. An uncapped run must make no Key Vault certificate listing at
  # all and must keep Azure's enumeration order, so an existing consumer sees byte-identical
  # behaviour down to the artifact's record order.
  cat >"${CW_STATE}/fixtures/zones.json" <<'JSON'
[
  {"name": "zone2.cw-test.internal", "nameServers": ["ns1.zone2.cw-test.internal."]},
  {"name": "cw-test.internal",       "nameServers": ["ns1.cw-test.internal."]}
]
JSON
  : >"${CW_STATE}/calls.log"
  run_warden
  assert_success

  # Record order follows the zone listing, NOT urgency.
  run jq -r '[.[].zone] | join(",")' "${METRICS_OUT}"
  assert_output "zone2.cw-test.internal,cw-test.internal"

  # And the ordering pre-pass never ran.
  run grep -c "keyvault certificate list" "${CW_STATE}/calls.log"
  assert_output "0"
}
