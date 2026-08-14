#!/usr/bin/env bash
#
# Install the local commit-msg hook so conventional-commit problems are caught at commit time
# instead of by CI. Requires npx (Node.js); the hook runs commitlint with the repo config.
#
set -euo pipefail
shopt -s inherit_errexit

repoRoot="$(git rev-parse --show-toplevel)"
hookPath="${repoRoot}/.git/hooks/commit-msg"

cat >"${hookPath}" <<'HOOK'
#!/usr/bin/env bash
# Installed by scripts/install-git-hooks.sh — lints the commit message with commitlint.
# Uses the repo's lockfile-pinned commitlint (root package.json) so the hook runs the exact
# versions CI runs, not a floating `npx` latest.
set -euo pipefail
if ! command -v npm >/dev/null 2>&1; then
  echo "commit-msg hook: npm not found; skipping commitlint (CI will still enforce it)." >&2
  exit 0
fi
repoRoot="$(git rev-parse --show-toplevel)"
if [[ ! -x "${repoRoot}/node_modules/.bin/commitlint" ]]; then
  (cd "${repoRoot}" && npm ci --ignore-scripts --no-audit --no-fund --silent)
fi
"${repoRoot}/node_modules/.bin/commitlint" --edit "${1}"
HOOK
chmod +x "${hookPath}"
echo "Installed commit-msg hook at ${hookPath}"
