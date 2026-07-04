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
