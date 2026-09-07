#!/usr/bin/env bats
# Suite-wide shellcheck relaxations, inherent to bats suites that source the script under test
# via variables: SC1090 (non-constant source), SC2154/SC2034 (globals assigned by the sourced
# script / consumed by it), SC2030/SC2031 (bats runs each test in a subshell by design).
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Unit tests for lib/helpers.bash — logging prefix resolution and the GITHUB_OUTPUT writers,
# including the multiline-delimiter injection guard (P-10).

load ../test_helper

@test "log-info uses CW_ACTION_NAME when set" {
  run bash -c "CW_ACTION_NAME=myaction source '${HELPERS_BASH}'; log-info hello"
  assert_success
  assert_output --partial "myaction: hello"
}

@test "log prefix falls back to the outermost script's directory name" {
  # A script under a dir named 'fakeaction' sourcing the lib must log as 'fakeaction'.
  mkdir -p "${BATS_TEST_TMPDIR}/fakeaction"
  cat >"${BATS_TEST_TMPDIR}/fakeaction/run.sh" <<EOF
#!/usr/bin/env bash
source '${HELPERS_BASH}'
log-info hello
EOF
  run bash "${BATS_TEST_TMPDIR}/fakeaction/run.sh"
  assert_success
  assert_output --partial "fakeaction: hello"
}

@test "set-output fails loudly without GITHUB_OUTPUT" {
  # The ${VAR:?} expansion aborts a non-interactive shell; capture the rc explicitly so bats
  # doesn't mistake the 127 for command-not-found (BW01).
  run bash -c "source '${HELPERS_BASH}' >/dev/null
    unset GITHUB_OUTPUT
    (set-output k v) || echo \"FAILED_AS_EXPECTED rc=\$?\""
  assert_success
  assert_output --partial "FAILED_AS_EXPECTED"
  assert_output --partial "requires GITHUB_OUTPUT"
}

@test "set-output appends key=value" {
  local out="${BATS_TEST_TMPDIR}/gh_output"
  run bash -c "source '${HELPERS_BASH}' >/dev/null; GITHUB_OUTPUT='${out}' set-output answer 42"
  assert_success
  run cat "${out}"
  assert_output "answer=42"
}

@test "set-multiline-output survives values containing heredoc-marker-like lines (P-10)" {
  local out="${BATS_TEST_TMPDIR}/gh_output"
  # A hostile value that would terminate a fixed-delimiter heredoc early.
  local value=$'line1\nEOF\nghadelimiter\nline4'
  run bash -c "
    source '${HELPERS_BASH}' >/dev/null
    GITHUB_OUTPUT='${out}' set-multiline-output body \"\$1\"
  " _ "${value}"
  assert_success

  # Structure: name<<DELIM / value lines / DELIM — and the random delimiter must not occur in
  # the value (which would truncate it).
  local delim
  delim="$(head -1 "${out}")"
  delim="${delim#body<<}"
  [ -n "${delim}" ]
  run grep -c "^${delim}\$" "${out}"
  assert_output "1" # exactly one terminator line
  # The captured value round-trips intact:
  local captured
  captured="$(sed -n "2,\$p" "${out}" | sed "/^${delim}\$/d")"
  [ "${captured}" = "${value}" ]
}

@test "mask-value emits the add-mask workflow command" {
  run bash -c "source '${HELPERS_BASH}' >/dev/null; mask-value supersecret"
  assert_success
  assert_output "::add-mask::supersecret"
}

# --- the shared "due" vocabulary -------------------------------------------------------------
# cw_is_due is the ONE definition the warden's advisory and the monitor's card both use, so a
# wave can never be two different sizes depending on which one you read. It is lego's own rule
# (cmd_run_renew.go getDueDate): renew at a third of the lifetime remaining, or a half when the
# lifetime is 10 days or less.

due_of() { # <fraction> <days_to_expiry> -> true|false
  jq -r "${CW_JQ_LIB} .[0] | cw_is_due" <<<"[{\"lifetime_fraction_remaining\": ${1}, \"days_to_expiry\": ${2}}]"
}

@test "cw_is_due applies lego's one-third rule to a normal certificate" {
  source "${HELPERS_BASH}"
  # 90-day certificate: the renewal point is 30 days left, i.e. a fraction of 1/3.
  [ "$(due_of 0.295 26)" = true ]  # past due — the wave in a real drain
  [ "$(due_of 0.97 117)" = false ] # renewed days ago, four months of life left
  [ "$(due_of 0.34 31)" = false ]  # just inside the window, not yet
}

@test "cw_is_due switches to one-half for short-lived certificates, as lego does" {
  source "${HELPERS_BASH}"
  # 5-day certificate: lego renews at half the lifetime, not a third.
  [ "$(due_of 0.4 2)" = true ]  # 0.4 < 1/2 -> due, though it would NOT be under the 1/3 rule
  [ "$(due_of 0.7 4)" = false ] # 0.7 > 1/2 -> not yet
}

@test "cw_is_due treats an expired certificate as due and an unissued zone as not" {
  source "${HELPERS_BASH}"
  [ "$(due_of -0.02 -2)" = true ] # already expired: unambiguously due
  # A zone with no certificate has no fraction. It is NOT renewal backlog — it is onboarding,
  # governed by the other budget — so it must never inflate a renewal drain estimate.
  [ "$(due_of null null)" = false ]
  [ "$(due_of null 30)" = false ]
  [ "$(due_of 0.5 null)" = false ]
}

@test "cw_deferred, cw_renewed and cw_holds_cert classify the actions" {
  source "${HELPERS_BASH}"
  classify() { jq -r "${CW_JQ_LIB} .[0] | \"\(cw_deferred) \(cw_renewed) \(cw_holds_cert)\"" <<<"[${1}]"; }
  [ "$(classify '{"action":"deferred","lifetime_fraction_remaining":0.3}')" = "true false true" ]
  [ "$(classify '{"action":"deferred","lifetime_fraction_remaining":null}')" = "true false false" ]
  [ "$(classify '{"action":"renewed","lifetime_fraction_remaining":0.9}')" = "false true true" ]
  [ "$(classify '{"action":"forced","lifetime_fraction_remaining":0.9}')" = "false true true" ]
  [ "$(classify '{"action":"issued","lifetime_fraction_remaining":0.9}')" = "false false true" ]
}
