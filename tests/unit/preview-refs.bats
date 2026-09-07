#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Unit tests for scripts/ci/rewrite-internal-refs.sh — the PR preview mechanism's one moving
# part. It had no tests until the ref it rewrites TO became load-bearing: pr-preview.yml now
# passes the PR head SHA rather than the preview tag, so that the generated commit is hermetic.
# A consumer that pins it must not have the engine swapped underneath by a later rebuild.

load ../test_helper

REWRITE_SH="${REPO_ROOT}/scripts/ci/rewrite-internal-refs.sh"

setup() {
  cd "${BATS_TEST_TMPDIR}" || return 1
  mkdir -p .github/workflows
  cat >.github/workflows/reusable-warden.yml <<'YML'
jobs:
  warden:
    steps:
      - uses: dsb-norge/cert-warden/actions/setup-lego@v1.0.4 # x-release-please-version
      - uses: dsb-norge/cert-warden/actions/warden@v1.0.4 # x-release-please-version
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: azure/login@f5d393ae46f8fde4be8b75f32e3fc50e654ad0ca # v3.0.1
YML
  cp .github/workflows/reusable-warden.yml .github/workflows/preview-consume.yml
}

@test "rewrites internal refs to the given ref and leaves third-party pins alone" {
  run bash "${REWRITE_SH}" 1234567890abcdef1234567890abcdef12345678
  assert_success
  assert_output --partial "Done: 2 file(s) rewritten."

  run grep -c 'dsb-norge/cert-warden/actions/[a-z-]*@1234567890abcdef1234567890abcdef12345678' \
    .github/workflows/reusable-warden.yml
  assert_output "2"

  # THE thing that must not happen: rewriting somebody else's pinned action.
  run grep -c 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' .github/workflows/reusable-warden.yml
  assert_output "1"
  run grep -c 'azure/login@f5d393ae46f8fde4be8b75f32e3fc50e654ad0ca' .github/workflows/reusable-warden.yml
  assert_output "1"
}

# The guard in pr-preview.yml greps the generated commit for these patterns. If the rewrite ever
# stopped matching a form, the guard is what catches it — so pin the shapes it looks for.
@test "no mutable internal ref survives a rewrite" {
  bash "${REWRITE_SH}" 1234567890abcdef1234567890abcdef12345678 >/dev/null
  run grep -nE 'uses:[[:space:]]+dsb-norge/cert-warden[^@[:space:]]*@(preview/|v[0-9]|main)' \
    .github/workflows/reusable-warden.yml .github/workflows/preview-consume.yml
  assert_failure # grep finds nothing
}

@test "the mutable preview tag would NOT satisfy the guard (regression: why this changed)" {
  # Passing the tag is what made the generated commit non-hermetic. Kept as a test so the reason
  # is executable rather than only written down.
  bash "${REWRITE_SH}" preview/pr-31 >/dev/null
  run grep -cE 'uses:[[:space:]]+dsb-norge/cert-warden[^@[:space:]]*@preview/' \
    .github/workflows/reusable-warden.yml
  assert_output "2" # exactly what the guard now rejects
}

@test "is idempotent, so a re-run cannot double-rewrite" {
  bash "${REWRITE_SH}" abc1234 >/dev/null
  before="$(md5sum .github/workflows/reusable-warden.yml)"
  run bash "${REWRITE_SH}" abc1234
  assert_success
  assert_output --partial "Done: 0 file(s) rewritten."
  [ "$(md5sum .github/workflows/reusable-warden.yml)" = "${before}" ]
}

@test "requires a ref rather than silently rewriting to nothing" {
  run bash "${REWRITE_SH}"
  assert_failure
  assert_output --partial "usage:"
}
