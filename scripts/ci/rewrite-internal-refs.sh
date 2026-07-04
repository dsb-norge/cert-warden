#!/usr/bin/env bash
#
# Rewrite every internal `uses: dsb-norge/cert-warden/...@<ref>` reference in the reusable
# workflows to a given ref. Used by the PR preview mechanism (pr-preview.yml) to produce a
# self-consistent preview tag: the tagged tree's workflows reference actions at the tag itself,
# so a calling repo consumes the whole PR at one ref.
#
# On main these refs are exact release versions maintained by release-please
# (`# x-release-please-version` annotations) — this script never runs against main's history;
# it only shapes the detached preview commit.
#
# Usage: rewrite-internal-refs.sh <new-ref>   (e.g. preview/pr-42)
#
set -euo pipefail
shopt -s inherit_errexit nullglob

newRef="${1:?usage: rewrite-internal-refs.sh <new-ref>}"

files=(.github/workflows/reusable-*.yml .github/workflows/preview-consume.yml)

rewritten=0
for f in "${files[@]}"; do
  # nullglob drops unmatched globs, but literal paths survive — guard both.
  [[ -f "${f}" ]] || continue
  before="$(md5sum "${f}")"
  # Matches `uses: dsb-norge/cert-warden/<path>@<anything>` and swaps the ref. The trailing
  # release-please annotation comment (if present) is left in place — harmless in a preview.
  sed -i -E "s|(uses:[[:space:]]+dsb-norge/cert-warden[^@[:space:]]*)@[^[:space:]]+|\1@${newRef}|g" "${f}"
  if [[ "$(md5sum "${f}")" != "${before}" ]]; then
    echo "rewrote internal refs in ${f} -> @${newRef}"
    rewritten=$((rewritten + 1))
  fi
done
echo "Done: ${rewritten} file(s) rewritten."
