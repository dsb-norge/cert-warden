#!/usr/bin/env bash
#
# Install bats-core at an exact, cryptographically verified commit.
#
# Why not bats-core/bats-action: it downloads bats-core (and helper libs) as GitHub tarballs
# by MUTABLE tag name with no checksum — a moved upstream tag would deliver arbitrary bash
# into CI with no diff here. Fetching the pinned commit over the git protocol makes git
# itself verify the object hashes, so the ref below is the integrity check; no separate
# checksum file to maintain. The helper libraries are vendored instead (tests/vendor/).
#
# BATS_CORE_REF is "vX.Y.Z@<40-hex commit sha>" — the tag names the version for humans and
# Renovate; the sha is what installs. ci.yml passes it from its env block.
set -euo pipefail
shopt -s inherit_errexit

ref="${BATS_CORE_REF:?BATS_CORE_REF (vX.Y.Z@sha) is required}"
tag="${ref%%@*}"
sha="${ref##*@}"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "::error::BATS_CORE_REF has no 40-hex commit sha: ${ref}" >&2
  exit 1
}

prefix="${BATS_PREFIX:-${RUNNER_TEMP:-/tmp}/bats-core-${tag}}"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

git -C "${workdir}" init --quiet
git -C "${workdir}" fetch --quiet --depth 1 https://github.com/bats-core/bats-core.git "${sha}"
git -C "${workdir}" checkout --quiet "${sha}"

actual="$(git -C "${workdir}" rev-parse HEAD)"
[[ "${actual}" == "${sha}" ]] || {
  echo "::error::bats-core checkout mismatch: wanted ${sha}, got ${actual}" >&2
  exit 1
}

"${workdir}/install.sh" "${prefix}" >/dev/null
echo "bats-core ${tag} (${sha}) installed to ${prefix}"
"${prefix}/bin/bats" --version

# Under GitHub Actions, expose bats to subsequent steps; locally, print the hint.
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${prefix}/bin" >>"${GITHUB_PATH}"
else
  echo "add to PATH: ${prefix}/bin"
fi
