#!/usr/bin/env bash
#
# Rewrite every internal `uses: dsb-norge/cert-warden/...@<ref>` reference in the reusable
# workflows to a given ref. Used by the PR preview mechanism (pr-preview.yml), which passes an
# IMMUTABLE per-push tag (`preview/pr-<N>-<short-sha>`) that it then points at the very commit
# containing these rewrites. The published tree is therefore self-referential, and a consumer who
# pins that tag cannot have the engine change underneath them.
#
# The ref MUST be one that resolves to the generated commit. Two attempts that do not:
#
#   - the moving `preview/pr-<N>` tag (the original design): force-moved on every push, so a
#     rebuild mid-run served two different engines to two jobs of one run;
#   - the PR head SHA: immutable, and fine for `actions/*` refs since only workflow files are
#     rewritten — but reusable workflows reference EACH OTHER, and a workflow-to-workflow `uses:`
#     then fetches the UN-rewritten file, whose own refs are `@vX.Y.Z`. That silently resolves
#     the released engine instead of the PR's, and fails outright on a release PR where the
#     version being released does not exist yet.
#
# pr-preview.yml enforces the property: every internal ref in the published tree must name the
# tag, and the tag must resolve to that commit.
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
