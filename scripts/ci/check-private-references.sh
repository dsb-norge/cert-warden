#!/usr/bin/env bash
#
# Private-reference guard: this is a PUBLIC repository, and linking to private DSB
# repositories from it is forbidden — in files, in commit messages (they surface in the
# generated CHANGELOG.md), everywhere. This script fails CI when a deny-listed pattern
# appears in the working tree or, on pull requests, in any commit message in the PR.
#
# Patterns live in .github/private-ref-patterns.txt (one extended regex per line, '#' for
# comments). That file and this script are excluded from the tree scan.
#
# Environment (optional, provided by CI):
#   GH_TOKEN   token for the gh CLI (PR commit-message scan)
#   PR_NUMBER  pull request number; when empty the message scan is skipped
#   REPO       owner/repo for the gh CLI
#
set -euo pipefail
shopt -s inherit_errexit

patternsFile=".github/private-ref-patterns.txt"
selfPath="scripts/ci/check-private-references.sh"

if [[ ! -f "${patternsFile}" ]]; then
  echo "::error::${patternsFile} not found — the private-reference guard cannot run."
  exit 1
fi

mapfile -t patterns < <(grep -vE '^\s*(#|$)' "${patternsFile}")
if ((${#patterns[@]} == 0)); then
  echo "::error::${patternsFile} contains no patterns."
  exit 1
fi

failures=0

# --- working tree ---------------------------------------------------------------------------
for pattern in "${patterns[@]}"; do
  # git grep exits 1 on no match; that's the good case.
  if hits="$(git grep -In -E "${pattern}" -- ":!${patternsFile}" ":!${selfPath}")"; then
    echo "::error::Private reference (pattern: ${pattern}) found in the working tree:"
    echo "${hits}"
    failures=$((failures + 1))
  fi
done

# --- PR commit messages ---------------------------------------------------------------------
if [[ -n "${PR_NUMBER:-}" && -n "${GH_TOKEN:-}" ]]; then
  messages="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/commits" --paginate \
    --jq '.[] | "\(.sha[0:7]) \(.commit.message | gsub("\n"; " "))"')"
  for pattern in "${patterns[@]}"; do
    if hits="$(grep -E "${pattern}" <<<"${messages}")"; then
      echo "::error::Private reference (pattern: ${pattern}) found in PR commit message(s):"
      echo "${hits}"
      echo "Commit messages end up in the public CHANGELOG — reword the commit (git rebase -i)."
      failures=$((failures + 1))
    fi
  done
else
  echo "No PR context — skipping commit-message scan (tree scan still ran)."
fi

if ((failures > 0)); then
  echo "::error::${failures} private-reference violation(s). This repo is public: never link to private DSB repositories."
  exit 1
fi
echo "Private-reference guard: clean."
