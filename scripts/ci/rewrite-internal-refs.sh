#!/usr/bin/env bash
#
# Rewrite every internal `uses: dsb-norge/cert-warden/...@<ref>` reference in the reusable
# workflows to a given ref. Used by the PR preview mechanism (pr-preview.yml), which passes the
# PR's HEAD SHA — an IMMUTABLE ref — so the generated preview commit is hermetic: pin it and the
# engine it resolves cannot change under you.
#
# It passed the preview TAG until 2026-09, which made the generated commit non-hermetic, because
# the tag is force-moved on every push. A consumer pinning the commit still had its actions
# resolve at job start time, and a rebuild landing mid-run served two engines to two jobs of one
# run. Only `.github/workflows/*.yml` is rewritten, so the action directories are byte-identical
# between the PR head and the generated commit — which is why the head SHA resolves exactly the
# code being previewed, and why a commit that cannot embed its own SHA does not need a tag here.
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
