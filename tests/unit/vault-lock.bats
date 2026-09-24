#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Structural tests for the vault lock (docs/contracts.md §5): the concurrency block that keeps
# reusable-warden.yml and reusable-sweeper.yml from racing on one Key Vault.
#
# The lock only works while both jobs name the SAME group. Nothing at runtime notices when they
# drift apart: each workflow still serialises against itself, so every run stays green while
# the warden and the sweeper quietly stop excluding each other. Before the suite held the lock,
# callers wrote the group by hand: the design spec and the reference usage had already given it
# different names, and the canary doc hard-coded the one a real consumer did not use. Hence a
# test, not a comment.
#
# The workflows are read with yq (mikefarah v4, preinstalled on GitHub's ubuntu runners), so
# the comparison is on parsed YAML: inline comments may differ between the two blocks.

load ../test_helper

WARDEN_WF="${REPO_ROOT}/.github/workflows/reusable-warden.yml"
SWEEPER_WF="${REPO_ROOT}/.github/workflows/reusable-sweeper.yml"

setup() {
  command -v yq >/dev/null || fail "yq (mikefarah v4) is required for this suite"
}

@test "the warden and the sweeper hold the identical lock" {
  warden=$(yq -o json -I 0 '.jobs.warden.concurrency' "${WARDEN_WF}")
  sweeper=$(yq -o json -I 0 '.jobs.sweep.concurrency' "${SWEEPER_WF}")
  [[ "${warden}" != "null" ]] || fail "reusable-warden.yml: jobs.warden has no concurrency block"
  [[ "${sweeper}" != "null" ]] || fail "reusable-sweeper.yml: jobs.sweep has no concurrency block"
  assert_equal "${sweeper}" "${warden}"
}

@test "the lock is keyed on the vault, under the contract name" {
  # Consumers composing the actions directly join this group by name, so the exact string is
  # public API: changing it is a breaking change (docs/contracts.md §5).
  run yq '.jobs.warden.concurrency.group' "${WARDEN_WF}"
  # shellcheck disable=SC2016 # the literal GitHub expression IS the expected value
  assert_output 'cert-warden-vault-${{ inputs.key-vault-name }}'
}

@test "the lock never cancels a run, pending or in progress" {
  # cancel-in-progress false: never interrupt an import or a delete. queue max: keep every
  # pending run instead of GitHub's default of one, where a third arrival cancels the second.
  run yq '.jobs.warden.concurrency.cancel-in-progress' "${WARDEN_WF}"
  assert_output "false"
  run yq '.jobs.warden.concurrency.queue' "${WARDEN_WF}"
  assert_output "max"
}
