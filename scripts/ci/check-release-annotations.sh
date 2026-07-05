#!/usr/bin/env bash
#
# Release-annotation consistency guard: every file containing an `x-release-please-version`
# annotation must be listed in release-please-config.json's extra-files, and vice versa.
# Drift in either direction is a broken release:
#   - annotated but unlisted  -> the release PR ships WITHOUT bumping that file's internal
#     refs -> consumers resolve a tag that does not exist
#   - listed but unannotated  -> stale config that will silently rot
#
set -euo pipefail
shopt -s inherit_errexit

config="release-please-config.json"

# Match actual annotated refs (`uses: ...@vX.Y.Z # x-release-please-version`), not prose
# comments that merely mention the marker.
annotated="$(git grep -lE 'uses:.*# x-release-please-version' -- '.github/workflows/*.yml' '.github/workflows/*.yaml' | sort)"
listed="$(jq -r '.packages.".".["extra-files"][].path' "${config}" | sort)"

if [[ "${annotated}" != "${listed}" ]]; then
  echo "::error::release-please extra-files and x-release-please-version annotations have drifted."
  echo "Files containing annotations:"
  # shellcheck disable=SC2001 # per-line prefix on a multiline var: sed is the clear tool here
  sed 's/^/  /' <<<"${annotated:-<none>}"
  echo "Files listed in ${config} extra-files:"
  # shellcheck disable=SC2001
  sed 's/^/  /' <<<"${listed:-<none>}"
  echo "Fix: keep the two sets identical (see docs/development-and-ci.md, Releases)."
  exit 1
fi
echo "Release annotations consistent: $(wc -l <<<"${annotated}") file(s)."
