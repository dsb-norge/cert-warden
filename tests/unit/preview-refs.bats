#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Unit tests for scripts/ci/rewrite-internal-refs.sh — the PR preview mechanism's one moving
# part. It had no tests until the ref it rewrites TO became load-bearing: pr-preview.yml passes
# an immutable per-push tag which it then points at the very commit containing the rewrites, so
# the published tree is self-referential and a consumer pinning it cannot have the engine swapped
# underneath by a later rebuild.
#
# The rewrite covers reusable workflows AND preview-consume.yml, which matters more than it looks:
# those files reference each other, so a workflow-to-workflow `uses:` must resolve to the
# rewritten copy. Pointing it anywhere else — a moving tag, or the PR head SHA — fetches a file
# whose own refs are `@vX.Y.Z`, silently resolving the released engine instead of the PR's.

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
  # preview-consume.yml calls a reusable WORKFLOW, not just actions — the case the head-SHA
  # attempt got wrong.
  cat >.github/workflows/preview-consume.yml <<'YML'
jobs:
  consume-reusable-monitor:
    uses: dsb-norge/cert-warden/.github/workflows/reusable-monitor.yml@v1.0.4 # x-release-please-version
  consume-actions:
    steps:
      - uses: dsb-norge/cert-warden/actions/monitor@v1.0.4 # x-release-please-version
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
YML
}

@test "rewrites internal refs to the given ref and leaves third-party pins alone" {
  run bash "${REWRITE_SH}" preview/pr-31-abc1234
  assert_success
  assert_output --partial "Done: 2 file(s) rewritten."

  run grep -c 'dsb-norge/cert-warden/actions/[a-z-]*@preview/pr-31-abc1234' \
    .github/workflows/reusable-warden.yml
  assert_output "2"

  # THE thing that must not happen: rewriting somebody else's pinned action.
  run grep -c 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' .github/workflows/reusable-warden.yml
  assert_output "1"
  run grep -c 'azure/login@f5d393ae46f8fde4be8b75f32e3fc50e654ad0ca' .github/workflows/reusable-warden.yml
  assert_output "1"
}

# pr-preview.yml's guard demands that EVERY internal ref name the pinned tag. That is stricter
# than "no mutable ref", deliberately: the head-SHA attempt contained no mutable ref and was
# still wrong. This asserts the rewrite leaves nothing behind for that guard to reject.
@test "every internal ref names the given ref after a rewrite" {
  pinned="preview/pr-31-abc1234"
  bash "${REWRITE_SH}" "${pinned}" >/dev/null
  run bash -c "grep -hoE 'uses:[[:space:]]+dsb-norge/cert-warden[^@[:space:]]*@[^[:space:]]+' \
    .github/workflows/reusable-warden.yml .github/workflows/preview-consume.yml \
    | grep -vE '@${pinned}\$' | wc -l"
  assert_output "0"
}

# The two refs that were tried and are wrong, kept executable so the reason cannot rot into a
# comment nobody believes.
@test "regression: the moving tag and the head SHA are both rejectable" {
  # The moving preview tag — force-moved on every push, so pinning it froze nothing.
  bash "${REWRITE_SH}" preview/pr-31 >/dev/null
  # No `$` anchor: these lines keep a trailing `# x-release-please-version` comment.
  run grep -cE 'uses:[[:space:]]+dsb-norge/cert-warden[^@[:space:]]*@preview/pr-31([[:space:]]|$)' \
    .github/workflows/reusable-warden.yml
  assert_output "2"

  # The PR head SHA — immutable, but it makes a workflow-to-workflow `uses:` fetch the
  # UN-rewritten file. Nothing in the rewrite's own output reveals that, which is precisely why
  # the guard checks the tag resolves to the published commit rather than just checking mutability.
  setup
  bash "${REWRITE_SH}" 1234567890abcdef1234567890abcdef12345678 >/dev/null
  run grep -c 'reusable-monitor.yml@1234567890abcdef1234567890abcdef12345678' \
    .github/workflows/preview-consume.yml
  assert_output "1" # points at a commit whose reusable-monitor.yml is NOT rewritten
}

@test "is idempotent, so a re-run cannot double-rewrite" {
  bash "${REWRITE_SH}" preview/pr-31-abc1234 >/dev/null
  before="$(md5sum .github/workflows/reusable-warden.yml)"
  run bash "${REWRITE_SH}" preview/pr-31-abc1234
  assert_success
  assert_output --partial "Done: 0 file(s) rewritten."
  [ "$(md5sum .github/workflows/reusable-warden.yml)" = "${before}" ]
}

@test "requires a ref rather than silently rewriting to nothing" {
  run bash "${REWRITE_SH}"
  assert_failure
  assert_output --partial "usage:"
}
