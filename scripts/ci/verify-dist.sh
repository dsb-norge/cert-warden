#!/usr/bin/env bash
#
# Rebuild a JS action's committed dist/ bundle from its source at an exact commit and diff
# it — the bump-time check for actions with no upstream dist-verification CI.
#
#   scripts/ci/verify-dist.sh <owner/repo> <40-hex commit sha>
#
# WHY: a node action executes its committed dist/ bundle, not its src/. Upstreams that
# hand-build dist on a maintainer machine (no check-dist CI) could ship a bundle that does
# not match the source you reviewed — deliberately or via a compromised laptop. Rebuilding
# with `npm ci --ignore-scripts` from the lockfile and diffing proves src == dist, closing
# that gap at every bump. See docs/dependency-bumps.md §4.
#
# Modes (per upstream, based on what the 2026-08 assessment established):
#   gate    — rebuild is byte-identical at the assessed pins; ANY diff fails this script.
#   review  — rebuild is expected to differ slightly (azure/login ships cosmetically stale
#             bundles: stale user-agent marker + CRLF noise). The script prints the diff for
#             human review and exits 0 unless the build itself fails. A growing or
#             non-cosmetic diff is the signal to stop and investigate.
set -euo pipefail
shopt -s inherit_errexit

repo="${1:?usage: verify-dist.sh <owner/repo> <commit-sha>}"
sha="${2:?commit sha required}"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "::error::not a 40-hex commit sha: ${sha} (resolve with: gh api repos/${repo}/commits/<tag> --jq .sha)" >&2
  exit 1
}

case "${repo}" in
  googleapis/release-please-action) mode="gate" ;;
  Azure/login | actions/create-github-app-token) mode="review" ;;
  *)
    echo "::error::unknown repo '${repo}' — add it here with a tested build command and a gate/review decision" >&2
    exit 1
    ;;
esac

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

git -C "${workdir}" init --quiet
# GitHub sometimes refuses shallow fetches of unadvertised SHAs ("not our ref") — fall back
# to a full fetch and check the commit out from there.
if ! git -C "${workdir}" fetch --quiet --depth 1 "https://github.com/${repo}.git" "${sha}" 2>/dev/null; then
  git -C "${workdir}" fetch --quiet "https://github.com/${repo}.git" '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
fi
git -C "${workdir}" checkout --quiet "${sha}"
echo "verifying $(git -C "${workdir}" log -1 --format='%H %s')"

(cd "${workdir}" && npm ci --ignore-scripts --no-audit --no-fund --silent && npm run build >/dev/null 2>&1)

if git -C "${workdir}" diff --quiet -- dist/ lib/; then
  echo "OK: rebuilt bundle is byte-identical to the committed one (${repo} @ ${sha:0:12})"
  exit 0
fi

echo "rebuilt bundle differs from the committed one:"
git -C "${workdir}" diff --stat -- dist/ lib/
if [[ "${mode}" == "gate" ]]; then
  echo "::error::${repo} dist/ is NOT reproducible from source at ${sha} — do not merge this bump without an explanation"
  exit 1
fi
echo "review mode (${repo}): a small cosmetic diff is the known upstream state — READ it:"
echo "  git -C ${workdir} diff -- dist/ lib/    # (dir kept only while this shell runs)"
git -C "${workdir}" diff -- dist/ lib/ | head -100
echo "(diff truncated at 100 lines; anything beyond stale version markers/CRLF is a stop-and-investigate signal)"
