#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Unit tests for scripts/security-findings.sh, the maintainer's read-only view of the Security
# tab (routine: docs/security-findings.md). `gh` is stubbed at the CLI boundary with canned API
# answers, so these tests pin the script's own logic: the ignore table, a source the repository
# has not enabled, and that any OTHER API failure stops the report instead of shrinking it.
#
# The script finds its ignore table relative to itself (../docs/security-findings.md), so each
# test runs a copy of it inside a scratch tree whose docs/ it controls. No test seam needed.

load ../test_helper

setup() {
  mkdir -p "${BATS_TEST_TMPDIR}/tree/scripts" "${BATS_TEST_TMPDIR}/tree/docs" \
    "${BATS_TEST_TMPDIR}/bin" "${BATS_TEST_TMPDIR}/api"
  cp "${REPO_ROOT}/scripts/security-findings.sh" "${BATS_TEST_TMPDIR}/tree/scripts/"
  SCRIPT="${BATS_TEST_TMPDIR}/tree/scripts/security-findings.sh"
  IGNORE_DOC="${BATS_TEST_TMPDIR}/tree/docs/security-findings.md"
  API="${BATS_TEST_TMPDIR}/api"

  # Stub gh: answers `gh api [--paginate] <path> [-q <filter>]` from files in ${API}, keyed by
  # the endpoint (the path without its query string, slashes as dashes). A <key>.fail file makes
  # the call fail with that file's content as gh's error message, the way gh reports HTTP errors.
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "api" ]] || { echo "unexpected gh call: $*" >&2; exit 1; }
shift
[[ "$1" == "--paginate" ]] && shift
path="$1"
shift
key="$(sed -e 's/?.*//' -e 's#/#-#g' <<<"${path}")"
if [[ -f "${GH_STUB_API}/${key}.fail" ]]; then
  cat "${GH_STUB_API}/${key}.fail" >&2
  exit 1
fi
[[ -f "${GH_STUB_API}/${key}.json" ]] || { echo "gh stub: no fixture for ${key}" >&2; exit 1; }
if [[ "${1:-}" == "-q" ]]; then jq -r "$2" "${GH_STUB_API}/${key}.json"; else cat "${GH_STUB_API}/${key}.json"; fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export GH_STUB_API="${API}"

  # A healthy repository with one finding per source, and scans on HEAD finished.
  local r="repos-dsb-norge-cert-warden"
  echo '{"sha":"abc1234def5678"}' >"${API}/${r}-commits-main.json"
  echo '{"workflow_runs":[
    {"name":"CodeQL","path":"dynamic/github-code-scanning/codeql","status":"completed","conclusion":"success"},
    {"name":"CI","path":".github/workflows/ci.yml","status":"completed","conclusion":"success"},
    {"name":"release-please","path":".github/workflows/release-please.yml","status":"in_progress","conclusion":null}
  ]}' >"${API}/${r}-actions-runs.json"
  echo '[{"number":11,"tool":{"name":"zizmor"},"rule":{"id":"zizmor/artipacked","severity":"warning","description":"credential persistence"},
    "most_recent_instance":{"location":{"path":".github/workflows/ci.yml","start_line":42}},"html_url":"https://example.test/cs/11"}]' \
    >"${API}/${r}-code-scanning-alerts.json"
  echo '[{"number":21,"rule":{"id":"js/unused-local-variable","severity":"note","title":"Unused variable"},
    "location":{"path":"scripts/ci/lint-commits.mjs","start_line":7}}]' >"${API}/${r}-code-quality-findings.json"
  echo '[{"number":6,"dependency":{"package":{"ecosystem":"npm","name":"fast-uri"},"manifest_path":"package-lock.json"},
    "security_advisory":{"classification":"general","severity":"high","ghsa_id":"GHSA-58mr-gqgx-xq4g","summary":"host confusion"},
    "security_vulnerability":{"first_patched_version":{"identifier":"3.1.7"}},"html_url":"https://example.test/dep/6"}]' \
    >"${API}/${r}-dependabot-alerts.json"
  echo '[]' >"${API}/${r}-secret-scanning-alerts.json"
}

@test "security-findings: reports every open finding, grouped by source" {
  run bash "${SCRIPT}"
  assert_success
  assert_output --partial "Security and quality findings for dsb-norge/cert-warden (main at abc1234)"
  # Only the runs that feed the Security tab count; release-please still running is irrelevant.
  assert_output --partial "Scans on abc1234: 2 runs, all completed."
  assert_output --partial "code-scanning#11  warning  zizmor: zizmor/artipacked  .github/workflows/ci.yml:42"
  assert_output --partial "code-quality#21"
  assert_output --partial "dependabot#6  high  Dependabot: GHSA-58mr-gqgx-xq4g  npm:fast-uri (package-lock.json)"
  assert_output --partial "host confusion (fixed in 3.1.7)"
  assert_output --partial "Total: 3 to assess, 0 permanently ignored."
}

@test "security-findings: the ignore table hides its findings and names the ones no longer open" {
  cat >"${IGNORE_DOC}" <<'MD'
| ID | Rule | Location (when recorded) | Why it is ignored | Recorded |
|----|------|--------------------------|-------------------|----------|
| `code-scanning#11` | `zizmor/artipacked` | `.github/workflows/ci.yml:42` | By design. | 2026-09-29 |
| `dependabot#3` | `GHSA-xxxx` | `npm:old` | Fixed long ago. | 2026-01-01 |
MD
  run bash "${SCRIPT}"
  assert_success
  refute_output --partial "code-scanning#11"
  assert_output --partial "Code scanning: 0 to assess, 1 ignored"
  assert_output --partial "No longer open, prune from docs/security-findings.md: dependabot#3"
  assert_output --partial "Total: 2 to assess, 1 permanently ignored."

  run bash "${SCRIPT}" --all
  assert_output --partial "code-scanning#11  warning  zizmor: zizmor/artipacked  .github/workflows/ci.yml:42  (ignored)"
}

# Code Quality is not enabled on this repository. The script it was ported from assumed every
# source answered, and died on a jq error about the 403 body instead of reporting.
@test "security-findings: a source the repository has not enabled is reported, not fatal" {
  echo "gh: Code quality is not enabled for this repository. Please enable code quality in the repository settings. (HTTP 403)" \
    >"${API}/repos-dsb-norge-cert-warden-code-quality-findings.fail"
  run bash "${SCRIPT}"
  assert_success
  assert_output --partial "Code Quality (standard findings): not enabled for this repository"
  assert_output --partial "dependabot#6"
  assert_output --partial "Total: 2 to assess"

  run bash "${SCRIPT}" --json
  assert_success
  run jq -c '.sources' <<<"${output}"
  assert_output '{"code-scanning":true,"code-quality":false,"dependabot":true,"secret-scanning":true}'
}

# The opposite case must NOT degrade the same way: a report that silently drops a source reads
# exactly like a clean one.
@test "security-findings: any other API failure stops the report" {
  echo "gh: Bad credentials (HTTP 401)" >"${API}/repos-dsb-norge-cert-warden-dependabot-alerts.fail"
  run bash "${SCRIPT}"
  assert_failure
  assert_output --partial "Bad credentials"
  refute_output --partial "Total:"
}

@test "security-findings: warns when the scans on HEAD have not finished" {
  echo '{"workflow_runs":[
    {"name":"CodeQL","path":"dynamic/github-code-scanning/codeql","status":"in_progress","conclusion":null}
  ]}' >"${API}/repos-dsb-norge-cert-warden-actions-runs.json"
  run bash "${SCRIPT}"
  assert_success
  assert_output --partial "WARNING: scans on abc1234 still running (CodeQL). Rerun with --wait."
}

@test "security-findings: the committed ignore table parses" {
  # Every row the script would read must be well-formed; a malformed ID would silently be
  # neither ignored nor reported as stale.
  local doc="${REPO_ROOT}/docs/security-findings.md" rows
  [ -f "${doc}" ]
  # shellcheck disable=SC2016  # the backticks are literal Markdown
  rows="$(grep -cE '^\| *`' "${doc}" || true)"
  # shellcheck disable=SC2016
  run grep -cE '^\| *`(code-scanning|code-quality|dependabot|secret-scanning)#[0-9]+`' "${doc}"
  [ "${output}" = "${rows}" ]
}
