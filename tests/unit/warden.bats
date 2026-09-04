#!/usr/bin/env bats
# Suite-wide shellcheck relaxations, inherent to bats suites that source the script under test
# via variables: SC1090 (non-constant source), SC2154/SC2034 (globals assigned by the sourced
# script / consumed by it), SC2030/SC2031 (bats runs each test in a subshell by design).
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Unit tests for actions/warden/cert-warden.sh — sourced in library mode (source-guard).
# Ports and extends the original selftest: the `set -e` error-counter regression (P-1), the
# metrics-on-failure guarantee, plus the loadConfig/test-seam contract.

load ../test_helper

setup() {
  export_dummy_warden_env
}

@test "sourcing has no side effects (source-guard)" {
  run bash -c "set -euo pipefail; source '${WARDEN_SH}'; echo SOURCED_CLEAN"
  assert_success
  assert_output --partial "SOURCED_CLEAN"
  # Nothing from the main flow may run at source time:
  refute_output --partial "Init"
  refute_output --partial "lego --version"
}

@test "loadConfig: production defaults" {
  source "${WARDEN_SH}"
  loadConfig
  [ "${letsencryptServer}" = "acme-staging-v02.api.letsencrypt.org" ]
  [ "${acmeDirectoryUrl}" = "https://acme-staging-v02.api.letsencrypt.org/directory" ]
  [ "${legoDnsProvider}" = "azuredns" ]
  [ "${digArgs}" = "@1.1.1.1" ]
  [ -z "${legoExtraRunArgs}" ]
}

@test "loadConfig: LE production environment selects the production server" {
  export LE_ENVIRONMENT_NAME="production"
  source "${WARDEN_SH}"
  loadConfig
  [ "${letsencryptServer}" = "acme-v02.api.letsencrypt.org" ]
  [ "${letsencryptAccountKeySecretName}" = "letsencrypt-production-account-key" ]
}

@test "loadConfig: CW_* test seams override defaults" {
  export CW_ACME_DIRECTORY_URL="https://localhost:14000/dir"
  export CW_LEGO_DNS_PROVIDER="exec"
  export CW_LEGO_DNS_RESOLVERS="127.0.0.1:8053"
  export CW_LEGO_EXTRA_ARGS="--dns.propagation.disable-ans"
  export CW_DIG_ARGS="@127.0.0.1 -p 5354"
  source "${WARDEN_SH}"
  loadConfig
  [ "${acmeDirectoryUrl}" = "https://localhost:14000/dir" ]
  [ "${legoDnsProvider}" = "exec" ]
  [ "${legoDnsResolvers}" = "127.0.0.1:8053" ]
  [ "${legoExtraRunArgs}" = "--dns.propagation.disable-ans" ]
  [ "${digArgs}" = "@127.0.0.1 -p 5354" ]
}

@test "loadConfig: the renewal cap is unlimited by default" {
  source "${WARDEN_SH}"
  loadConfig
  [ "${maxRenewalsPerRun}" -eq 0 ]
  [ "${wardenRunsPerDay}" -eq 2 ]
  [ "${monitorWarnThreshold}" = "0.30" ]
}

@test "loadConfig: the renewal cap and its sizing-guard inputs are configurable" {
  export CERT_MAX_RENEWALS_PER_RUN="5"
  export CERT_RUNS_PER_DAY="4"
  export CERT_MONITOR_WARN_THRESHOLD="0.25"
  source "${WARDEN_SH}"
  loadConfig
  [ "${maxRenewalsPerRun}" -eq 5 ]
  [ "${wardenRunsPerDay}" -eq 4 ]
  [ "${monitorWarnThreshold}" = "0.25" ]
}

# A typo'd cap must NOT read as "unlimited": that is exactly the multi-hour, runner-blocking run
# the cap exists to prevent, and it would fail silently at the worst possible moment.
@test "loadConfig: an unparsable renewal cap fails the run loudly" {
  run bash -c "set -euo pipefail; export CERT_MAX_RENEWALS_PER_RUN='five'; source '${WARDEN_SH}'; loadConfig; echo REACHED"
  assert_failure
  assert_output --partial "CERT_MAX_RENEWALS_PER_RUN must be a non-negative integer"
  refute_output --partial "REACHED"

  run bash -c "set -euo pipefail; export CERT_MAX_RENEWALS_PER_RUN='-3'; source '${WARDEN_SH}'; loadConfig; echo REACHED"
  assert_failure
  refute_output --partial "REACHED"
}

@test "loadConfig: the sizing-guard inputs are validated too" {
  run bash -c "set -euo pipefail; export CERT_RUNS_PER_DAY='0'; source '${WARDEN_SH}'; loadConfig; echo REACHED"
  assert_failure
  assert_output --partial "CERT_RUNS_PER_DAY must be a positive integer"

  # A bare ".30" is rejected on purpose: it reaches jq as --argjson and is not valid JSON.
  run bash -c "set -euo pipefail; export CERT_MONITOR_WARN_THRESHOLD='.30'; source '${WARDEN_SH}'; loadConfig; echo REACHED"
  assert_failure
  assert_output --partial "CERT_MONITOR_WARN_THRESHOLD must be a fraction"

  run bash -c "set -euo pipefail; export CERT_MONITOR_WARN_THRESHOLD='30'; source '${WARDEN_SH}'; loadConfig; echo REACHED"
  assert_failure
}

@test "getCommonLegoRunOptions honours the seams" {
  export CW_ACME_DIRECTORY_URL="https://localhost:14000/dir"
  export CW_LEGO_DNS_PROVIDER="exec"
  export CW_LEGO_DNS_RESOLVERS="127.0.0.1:8053"
  export CW_LEGO_EXTRA_ARGS="--dns.propagation.disable-ans"
  source "${WARDEN_SH}"
  loadConfig
  legoDirPath="/tmp/lego-test"
  accountEmail="test@example.test"
  zoneName="zone.example.test"
  certSanAdditionalDomains=("*.zone.example.test")
  run getCommonLegoRunOptions
  assert_success
  assert_output --partial "--server https://localhost:14000/dir"
  assert_output --partial "--dns exec"
  assert_output --partial "--dns.resolvers 127.0.0.1:8053"
  assert_output --partial "--domains zone.example.test"
  assert_output --partial "--domains *.zone.example.test"
  assert_output --partial "--dns.propagation.disable-ans"
  assert_output --partial "--pfx"
}

# P-1 regression (the metrics-loss incident): `((count++))` returns exit status 1 when the
# counter is 0, so under `set -e` the FIRST error aborts the run before metrics are written.
# The probe MUST run in a child process: command substitution does not propagate a `set -e`
# abort (P-2), so an in-process probe would mask exactly this bug.
@test "logCertificateActionError survives set -e and counts (P-1, child-process probe)" {
  run bash -c "
    set -euo pipefail
    source '${WARDEN_SH}'
    certificateActionErrorCount=0
    logCertificateActionError 'simulated error 1'
    logCertificateActionError 'simulated error 2'
    logCertificateActionError 'simulated error 3'
    echo PROBE_COUNT=\${certificateActionErrorCount}
  "
  assert_success
  assert_output --partial "PROBE_COUNT=3"
}

@test "scripts enable inherit_errexit (P-2)" {
  run bash -c "set -euo pipefail; source '${WARDEN_SH}'; shopt -q inherit_errexit && echo ON"
  assert_success
  assert_output --partial "ON"
}

@test "zoneCertKvSecretName derives the Key Vault object name from zone + LE environment" {
  source "${WARDEN_SH}"
  loadConfig
  run zoneCertKvSecretName "a.example.test"
  assert_output "le-cert-staging-a-example-test-pfx"
  # The derivation must match the one the zone body uses, for every dot in the zone.
  run zoneCertKvSecretName "deep.sub.example.test"
  assert_output "le-cert-staging-deep-sub-example-test-pfx"

  export LE_ENVIRONMENT_NAME="production"
  loadConfig
  run zoneCertKvSecretName "a.example.test"
  assert_output "le-cert-production-a-example-test-pfx"
}

@test "recordCertMetric writes a monitor-safe failed record" {
  source "${WARDEN_SH}"
  loadConfig # recordCertMetric labels records with the LE environment from config
  metricsFile="$(mktemp "${BATS_TEST_TMPDIR}/metrics.XXXX")"
  : >"${metricsFile}"
  # Globals consumed by recordCertMetric:
  # shellcheck disable=SC2034
  zoneName="selftest.example.test"
  # shellcheck disable=SC2034
  certKvPfxSecretName="le-cert-staging-selftest-example-test-pfx"
  recordCertMetric "failed" "-" "simulated failure"

  run jq -s -e '
    .[0].action == "failed"
    and .[0].zone == "selftest.example.test"
    and .[0].kv_cert_name == "le-cert-staging-selftest-example-test-pfx"
    and .[0].error == "simulated failure"
    and .[0].lifetime_fraction_remaining == null
  ' "${metricsFile}"
  assert_success
}

# A zone the run declines to walk has no PEM on disk, so the validity window has to arrive as
# arguments. The point of the exercise is lifetime_fraction_remaining: it is the monitor's SLO
# input, and a record that reported null there would silently drop the zone out of the alert.
@test "recordCertMetric derives the validity window from fallback dates (no PEM)" {
  source "${WARDEN_SH}"
  loadConfig
  metricsFile="${BATS_TEST_TMPDIR}/m.json"
  : >"${metricsFile}"
  zoneName="fallback.example.test"
  certKvPfxSecretName="le-cert-staging-fallback-example-test-pfx"

  # A 90-day certificate, 60 days in: ~30 days left, ~1/3 of its lifetime remaining. Key
  # Vault's own ISO-8601-with-offset rendering, deliberately, not OpenSSL's format.
  nb="$(date -u -d '60 days ago' +'%Y-%m-%dT%H:%M:%S+00:00')"
  na="$(date -u -d '30 days' +'%Y-%m-%dT%H:%M:%S+00:00')"
  recordCertMetric "deferred" "-" "" "${nb}" "${na}"

  run jq -s -e '
    .[0].action == "deferred"
    and .[0].error == ""
    and .[0].kv_cert_name == "le-cert-staging-fallback-example-test-pfx"
    and .[0].days_to_expiry >= 29 and .[0].days_to_expiry <= 30
    and (.[0].lifetime_fraction_remaining > 0.32 and .[0].lifetime_fraction_remaining < 0.34)
  ' "${metricsFile}"
  assert_success
}

@test "recordCertMetric leaves the window null when no dates are available at all" {
  # The degraded path: the pre-pass listing failed, so a deferred record has no window. It must
  # still be a well-formed record (and must NOT invent a date from an empty `date -d`).
  source "${WARDEN_SH}"
  loadConfig
  metricsFile="${BATS_TEST_TMPDIR}/m.json"
  : >"${metricsFile}"
  zoneName="nowindow.example.test"
  certKvPfxSecretName="le-cert-staging-nowindow-pfx"
  run bash -c "
    set -euo pipefail
    source '${WARDEN_SH}'; loadConfig
    metricsFile='${metricsFile}'; zoneName='nowindow.example.test'; certKvPfxSecretName='x-pfx'
    recordCertMetric 'deferred' '-' '' '' ''
    echo SURVIVED
  "
  assert_success
  assert_output --partial "SURVIVED"
  run jq -s -e '
    .[0].action == "deferred"
    and .[0].days_to_expiry == null
    and .[0].lifetime_fraction_remaining == null
    and .[0].not_after == ""
  ' "${metricsFile}"
  assert_success
}

# A readable PEM must keep winning over any fallback: the served certificate is the truth, the
# Key Vault attributes are only a stand-in for when it was never fetched.
@test "recordCertMetric prefers the PEM over fallback dates" {
  source "${WARDEN_SH}"
  loadConfig
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "${BATS_TEST_TMPDIR}/k.pem" -out "${BATS_TEST_TMPDIR}/c.pem" \
    -days 10 -subj "/CN=pem.example.test" >/dev/null 2>&1
  metricsFile="${BATS_TEST_TMPDIR}/m.json"
  : >"${metricsFile}"
  zoneName="pem.example.test"
  certKvPfxSecretName="le-cert-staging-pem-pfx"
  # Fallbacks describe a wildly different (1-year) certificate; the PEM's 10 days must win.
  recordCertMetric "renewed" "${BATS_TEST_TMPDIR}/c.pem" "" \
    "$(date -u -d '1 year ago' +'%Y-%m-%dT%H:%M:%S+00:00')" \
    "$(date -u -d '1 year' +'%Y-%m-%dT%H:%M:%S+00:00')"
  run jq -s -e '.[0].days_to_expiry <= 10 and .[0].serial != ""' "${metricsFile}"
  assert_success
}

@test "recordCertMetric output conforms to contracts/metrics.schema.json" {
  source "${WARDEN_SH}"
  loadConfig
  metricsFile="$(mktemp "${BATS_TEST_TMPDIR}/metrics.XXXX")"
  : >"${metricsFile}"
  zoneName="schema.example.test"
  certKvPfxSecretName="le-cert-staging-schema-example-test-pfx"
  recordCertMetric "failed" "-" "boom"

  # Validate against the shipped schema itself (required fields + the action enum) so the
  # producer can never drift from the contract without this test noticing.
  schema="${REPO_ROOT}/contracts/metrics.schema.json"
  run jq -e --slurpfile schema "${schema}" -s '
    ($schema[0].items.required) as $req
    | ($schema[0].items.properties.action.enum) as $actions
    | all(.[]; . as $rec | ($req | all(. as $k | $rec | has($k))) and (($actions | index($rec.action)) != null))
  ' "${metricsFile}"
  assert_success
}

@test "resolveCertSanAdditionalDomains fails loudly when az fails (review F1)" {
  source "${WARDEN_SH}"
  loadConfig
  # PATH-shim az that fails like a throttled call — the function must return non-zero, NOT
  # fall through to an empty SAN set (which would issue a wrong apex-only certificate).
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/az"
  chmod +x "${BATS_TEST_TMPDIR}/bin/az"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  zoneName="f1.example.test"
  # Call exactly like the call site does (if-tested => errexit disabled inside, pitfall P-4):
  if ! resolveCertSanAdditionalDomains; then
    rc=1
  else
    rc=0
  fi
  [ "${rc}" -eq 1 ]
}

@test "dns_zone_is_publicly_delegated returns 2 on lookup failure (review F6)" {
  source "${WARDEN_SH}"
  export CW_DIG_ARGS="@127.0.0.1 -p 1" # nothing listens: dig errors out fast
  loadConfig
  rc=0
  dns_zone_is_publicly_delegated "f6.example.test" '["ns1.f6.example.test."]' || rc=$?
  [ "${rc}" -eq 2 ]
}

@test "delegation semantics: configured NS must be a subset of public NS" {
  source "${WARDEN_SH}"
  loadConfig
  # dig PATH-stub controlled per-case via DIG_STUB_NS (newline-separated answer).
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  # shellcheck disable=SC2016 # expansion deliberately deferred to the stub at run time
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${DIG_STUB_NS}"\n' >"${BATS_TEST_TMPDIR}/bin/dig"
  chmod +x "${BATS_TEST_TMPDIR}/bin/dig"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

  # exact match -> delegated
  export DIG_STUB_NS=$'ns1.x.test.\nns2.x.test.'
  run dns_zone_is_publicly_delegated "x.test" '["ns1.x.test.","ns2.x.test."]'
  assert_success
  # configured subset of public (extra public NS) -> delegated
  export DIG_STUB_NS=$'ns1.x.test.\nns2.x.test.\nns3.other.test.'
  run dns_zone_is_publicly_delegated "x.test" '["ns1.x.test."]'
  assert_success
  # configured NS missing from public answer -> NOT delegated
  export DIG_STUB_NS=$'ns1.x.test.'
  run dns_zone_is_publicly_delegated "x.test" '["ns1.x.test.","ns2.x.test."]'
  assert_failure 1
  # empty public answer (SERVFAIL-shaped) -> NOT delegated
  export DIG_STUB_NS=''
  run dns_zone_is_publicly_delegated "x.test" '["ns1.x.test."]'
  assert_failure 1
}

@test "garbage PFX from the vault fails installZoneCertFromKeyVault cleanly" {
  source "${WARDEN_SH}"
  loadConfig
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  # az returns base64 of garbage bytes for the cert-backing secret.
  cat >"${BATS_TEST_TMPDIR}/bin/az" <<'AZSTUB'
#!/usr/bin/env bash
printf 'bm90LWEtcGZ4LWF0LWFsbA==' # "not-a-pfx-at-all"
AZSTUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/az"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  run installZoneCertFromKeyVault "kv" "le-cert-staging-x-pfx" \
    "${BATS_TEST_TMPDIR}/c.crt" "${BATS_TEST_TMPDIR}/c.key" "${BATS_TEST_TMPDIR}/c.issuer" "pw"
  assert_failure
}

@test "recordCertMetric survives a certificate without SANs (P-12 guard)" {
  source "${WARDEN_SH}"
  loadConfig
  # Real self-signed cert with NO subjectAltName: the SAN/keytype greps find nothing and,
  # unguarded, would abort the run under pipefail before metrics were written.
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "${BATS_TEST_TMPDIR}/k.pem" -out "${BATS_TEST_TMPDIR}/nosan.pem" \
    -days 2 -subj "/CN=nosan.example.test" >/dev/null 2>&1
  metricsFile="${BATS_TEST_TMPDIR}/m.json"
  : >"${metricsFile}"
  zoneName="nosan.example.test"
  certKvPfxSecretName="le-cert-staging-nosan-pfx"
  run bash -c "
    set -euo pipefail
    source '${WARDEN_SH}'; loadConfig
    metricsFile='${metricsFile}'; zoneName='nosan.example.test'; certKvPfxSecretName='x-pfx'
    recordCertMetric 'issued' '${BATS_TEST_TMPDIR}/nosan.pem' ''
    echo SURVIVED
  "
  assert_success
  assert_output --partial "SURVIVED"
  run jq -s -e '.[0].san == [] and .[0].days_to_expiry != null' "${metricsFile}"
  assert_success
}

# --- run pacing: zone order + validity-window cache -------------------------------------------
# The cap makes the walk order load-bearing (it decides WHICH certificates renew), so the order
# is asserted directly rather than left to whatever Azure's listing happens to return.

# Stub `az keyvault certificate list` with a fixed answer; every other az call fails loudly.
stub_az_cert_list() {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/az" <<AZSTUB
#!/usr/bin/env bash
if [[ "\${1} \${2} \${3}" == "keyvault certificate list" ]]; then
  cat "${BATS_TEST_TMPDIR}/certlist.json"
  exit 0
fi
echo "unexpected az call: \$*" >&2
exit 1
AZSTUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/az"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

@test "resolveZoneProcessingOrder sorts most-urgent-first and puts uncertified zones last" {
  source "${WARDEN_SH}"
  loadConfig
  # b expires first, then a; c has no certificate at all. Enumeration order is deliberately
  # neither alphabetical nor urgency order, so a pass-through would be visible.
  publicZonesJson='[{"name":"a.example.test"},{"name":"c.example.test"},{"name":"b.example.test"}]'
  cat >"${BATS_TEST_TMPDIR}/certlist.json" <<'JSON'
[
  {"name":"le-cert-staging-a-example-test-pfx","nbf":"2026-06-01T00:00:00+00:00","exp":"2026-11-03T00:00:00+00:00"},
  {"name":"le-cert-staging-b-example-test-pfx","nbf":"2026-05-01T00:00:00+00:00","exp":"2026-10-01T00:00:00+00:00"},
  {"name":"le-cert-staging-unrelated-pfx","nbf":"2026-01-01T00:00:00+00:00","exp":"2026-02-01T00:00:00+00:00"}
]
JSON
  stub_az_cert_list
  resolveZoneProcessingOrder

  # Urgency order: b (Oct) -> a (Nov) -> c (no cert, nothing in service to lose).
  run echo "${zoneProcessingOrder[*]}"
  assert_output "b.example.test a.example.test c.example.test"

  # ... and the validity windows are cached for the deferred records to use.
  [ "${zoneCertNotAfter["b.example.test"]}" = "2026-10-01T00:00:00+00:00" ]
  [ "${zoneCertNotBefore["a.example.test"]}" = "2026-06-01T00:00:00+00:00" ]
  [ -z "${zoneCertNotAfter["c.example.test"]}" ]
  # An unrelated vault certificate must not leak into the run.
  [ "${#zoneProcessingOrder[@]}" -eq 3 ]
}

@test "resolveZoneProcessingOrder degrades to enumeration order when the listing fails" {
  # A failed listing must not stop the warden maintaining certificates: it costs the ordering
  # and the deferred records' validity window for one run, nothing more.
  source "${WARDEN_SH}"
  loadConfig
  publicZonesJson='[{"name":"a.example.test"},{"name":"c.example.test"},{"name":"b.example.test"}]'
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/az"
  chmod +x "${BATS_TEST_TMPDIR}/bin/az"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

  run resolveZoneProcessingOrder
  assert_success
  assert_output --partial "Could not list certificates in KeyVault"

  resolveZoneProcessingOrder
  run echo "${zoneProcessingOrder[*]}"
  assert_output "a.example.test c.example.test b.example.test"
  [ -z "${zoneCertNotAfter["a.example.test"]:-}" ]
}

@test "resolveZoneProcessingOrder rejects a non-array listing rather than silently emptying" {
  source "${WARDEN_SH}"
  loadConfig
  publicZonesJson='[{"name":"a.example.test"},{"name":"b.example.test"}]'
  echo '{"error":"throttled"}' >"${BATS_TEST_TMPDIR}/certlist.json"
  stub_az_cert_list

  run resolveZoneProcessingOrder
  assert_success
  assert_output --partial "Could not list certificates in KeyVault"
  resolveZoneProcessingOrder
  [ "${#zoneProcessingOrder[@]}" -eq 2 ]
}

@test "resolveZoneProcessingOrder maps zones to Key Vault names per the LE environment" {
  # Same zones, production environment: the staging certificates must not match.
  export LE_ENVIRONMENT_NAME="production"
  source "${WARDEN_SH}"
  loadConfig
  publicZonesJson='[{"name":"a.example.test"}]'
  cat >"${BATS_TEST_TMPDIR}/certlist.json" <<'JSON'
[{"name":"le-cert-staging-a-example-test-pfx","nbf":"2026-06-01T00:00:00+00:00","exp":"2026-11-03T00:00:00+00:00"}]
JSON
  stub_az_cert_list
  resolveZoneProcessingOrder
  [ -z "${zoneCertNotAfter["a.example.test"]}" ]
}

@test "the deferred action is part of the shipped metrics contract" {
  # The monitor is action-blind for the SLO, but a consumer validating the artifact against the
  # schema must accept a deferred record.
  source "${WARDEN_SH}"
  loadConfig
  metricsFile="${BATS_TEST_TMPDIR}/m.json"
  : >"${metricsFile}"
  zoneName="deferred.example.test"
  certKvPfxSecretName="le-cert-staging-deferred-example-test-pfx"
  recordCertMetric "deferred" "-" "" \
    "$(date -u -d '60 days ago' +'%Y-%m-%dT%H:%M:%S+00:00')" \
    "$(date -u -d '30 days' +'%Y-%m-%dT%H:%M:%S+00:00')"

  schema="${REPO_ROOT}/contracts/metrics.schema.json"
  run jq -e --slurpfile schema "${schema}" -s '
    ($schema[0].items.required) as $req
    | ($schema[0].items.properties.action.enum) as $actions
    | all(.[]; . as $rec | ($req | all(. as $k | $rec | has($k))) and (($actions | index($rec.action)) != null))
  ' "${metricsFile}"
  assert_success
}

# --- run pacing: the cap's sizing guard -------------------------------------------------------
# A cap holds due certificates past their ARI renewal point, which is precisely what the
# monitor's min_lifetime_fraction SLO measures. Sized well nobody hears about it; sized badly one
# long run becomes days of warning cards. The guard predicts which of the two you configured.

# Deferred fixture: a certificate `lifetime_days` long that is `age_days` old, i.e. still due.
deferred_record() {
  local zone="$1" lifetime="$2" age="$3"
  local dte frac
  dte=$((lifetime - age))
  frac=$(awk "BEGIN{printf \"%.4f\", ${dte}/${lifetime}}")
  jq -n -c --arg z "${zone}" --argjson dte "${dte}" --argjson frac "${frac}" \
    '{zone:$z, kv_cert_name:("le-cert-staging-" + $z), action:"deferred", days_to_expiry:$dte,
      lifetime_fraction_remaining:$frac, error:""}'
}

@test "warnIfCapCannotDrain says nothing when no cap is configured" {
  source "${WARDEN_SH}"
  loadConfig
  write_metrics_fixture "${BATS_TEST_TMPDIR}/m.json" \
    "$(deferred_record "a.example.test" 90 62)"
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  assert_success
  refute_output --partial "::warning::"
}

@test "warnIfCapCannotDrain says nothing when the cap drains inside the monitor's margin" {
  # 28 certificates just past due (90-day, 61 days old => fraction 0.322, ~1.9 days of margin
  # before 0.30). Cap 20 at twice daily drains in 0.5 days: comfortably inside.
  export CERT_MAX_RENEWALS_PER_RUN="20"
  source "${WARDEN_SH}"
  loadConfig
  local recs=()
  for i in $(seq 1 28); do recs+=("$(deferred_record "z${i}.example.test" 90 61)"); done
  write_metrics_fixture "${BATS_TEST_TMPDIR}/m.json" "${recs[@]}"
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  assert_success
  refute_output --partial "::warning::"
}

# The headline case from the request that prompted this feature: 51 certificates in one wave with
# a cap of 3 needs ~8.5 days at twice daily, and the fleet has ~3 days before the monitor warns.
@test "warnIfCapCannotDrain warns, and recommends a cap that fits, when the drain is too slow" {
  export CERT_MAX_RENEWALS_PER_RUN="3"
  source "${WARDEN_SH}"
  loadConfig
  local recs=()
  for i in $(seq 1 51); do recs+=("$(deferred_record "z${i}.example.test" 90 60)"); done
  write_metrics_fixture "${BATS_TEST_TMPDIR}/m.json" "${recs[@]}"
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  assert_success
  assert_output --partial "::warning::"
  assert_output --partial "CERT_MAX_RENEWALS_PER_RUN=3 is too small"
  assert_output --partial "Draining 51 deferred certificate(s) at 2 run(s)/day takes ~8.5 days"
  assert_output --partial "warn threshold (0.30)"
  # 51 certificates, ~3 days of margin, 2 runs/day => 9 per run.
  assert_output --partial "Raise the cap to 9"
  # Annotations cannot span lines — silence the load/config chatter so wc sees only the warning.
  run bash -c "{ source '${WARDEN_SH}'; loadConfig; } >/dev/null; warnIfCapCannotDrain '${BATS_TEST_TMPDIR}/m.json' | wc -l"
  assert_output "1"
}

@test "warnIfCapCannotDrain names the most urgent deferred certificate, not the first" {
  export CERT_MAX_RENEWALS_PER_RUN="1"
  source "${WARDEN_SH}"
  loadConfig
  write_metrics_fixture "${BATS_TEST_TMPDIR}/m.json" \
    "$(deferred_record "healthy.example.test" 90 58)" \
    "$(deferred_record "urgent.example.test" 90 84)" \
    "$(deferred_record "middling.example.test" 90 61)"
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  assert_output --partial "urgent.example.test"
  refute_output --partial "healthy.example.test"
}

@test "warnIfCapCannotDrain tells the operator to clear the cap when the margin is already gone" {
  # Already below the warn threshold: there is no margin left to size a cap against, so the
  # recommendation degenerates to "move the whole backlog now".
  export CERT_MAX_RENEWALS_PER_RUN="2"
  source "${WARDEN_SH}"
  loadConfig
  write_metrics_fixture "${BATS_TEST_TMPDIR}/m.json" \
    "$(deferred_record "a.example.test" 90 70)" \
    "$(deferred_record "b.example.test" 90 71)" \
    "$(deferred_record "c.example.test" 90 72)"
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  assert_output --partial "::warning::"
  assert_output --partial "in ~0.0 days"
  assert_output --partial "Raise the cap to 3"
}

@test "warnIfCapCannotDrain is silent when nothing was deferred" {
  export CERT_MAX_RENEWALS_PER_RUN="5"
  source "${WARDEN_SH}"
  loadConfig
  write_metrics_fixture "${BATS_TEST_TMPDIR}/m.json" \
    '{"zone":"a.example.test","kv_cert_name":"x","action":"renewed","days_to_expiry":89,"lifetime_fraction_remaining":0.99,"error":""}'
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  assert_success
  refute_output --partial "::warning::"
}

@test "warnIfCapCannotDrain cannot judge deferred records without a validity window" {
  # The degraded pre-pass path: no window means no honest prediction, so stay quiet rather than
  # guess -- but do not crash on the arithmetic either (a null would divide by zero).
  export CERT_MAX_RENEWALS_PER_RUN="1"
  source "${WARDEN_SH}"
  loadConfig
  write_metrics_fixture "${BATS_TEST_TMPDIR}/m.json" \
    '{"zone":"a.example.test","kv_cert_name":"x","action":"deferred","days_to_expiry":null,"lifetime_fraction_remaining":null,"error":""}'
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  assert_success
  refute_output --partial "::warning::"
}

@test "warnIfCapCannotDrain honours a tuned cadence and warn threshold" {
  # A consumer running four times a day drains twice as fast, so the same cap that warns at
  # twice-daily must not warn here.
  export CERT_MAX_RENEWALS_PER_RUN="3"
  export CERT_RUNS_PER_DAY="4"
  source "${WARDEN_SH}"
  loadConfig
  local recs=()
  for i in $(seq 1 6); do recs+=("$(deferred_record "z${i}.example.test" 90 61)"); done
  write_metrics_fixture "${BATS_TEST_TMPDIR}/m.json" "${recs[@]}"
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  refute_output --partial "::warning::"

  # A consumer that lowered the monitor's warn threshold has more margin, so the same backlog
  # that would warn at 0.30 must not warn at 0.20.
  export CERT_MAX_RENEWALS_PER_RUN="3"
  export CERT_RUNS_PER_DAY="2"
  export CERT_MONITOR_WARN_THRESHOLD="0.20"
  loadConfig
  run warnIfCapCannotDrain "${BATS_TEST_TMPDIR}/m.json"
  refute_output --partial "::warning::"
  assert_success
}
