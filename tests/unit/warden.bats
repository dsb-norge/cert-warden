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
