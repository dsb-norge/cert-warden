#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2154,SC2034,SC2030,SC2031
# Unit tests for the "Resolve warden run" step of reusable-monitor.yml: which warden run the
# monitor evaluates on the schedule/dispatch path (pitfall P-27 in docs/testing.md).
#
# The step used to ask for `gh run list --status completed`. A status filter makes GitHub serve
# the listing from a search capped at 1,000 results, and past that cap it intermittently returns
# stale pages: a consumer's scheduled monitor evaluated a 26-day-old run and sent a false
# WARNING. The step now pages the unfiltered listing newest-first, and these tests pin that:
# no search parameter is ever sent, a backlog of queued runs is paged past, and the three
# outcomes (found / the API answered nothing / the API did not answer) stay distinct.
#
# The step body is read from the workflow with yq (mikefarah v4, preinstalled on GitHub's ubuntu
# runners) and run the way `shell: bash` runs it, so the test exercises the committed script.
# `gh` is stubbed at the CLI boundary, and `sleep` with it, so retries cost no time.

load ../test_helper

MONITOR_WF="${REPO_ROOT}/.github/workflows/reusable-monitor.yml"

setup() {
  command -v yq >/dev/null || fail "yq (mikefarah v4) is required for this suite"
  STEP="${BATS_TEST_TMPDIR}/resolve.sh"
  yq '.jobs.monitor.steps[] | select(.id == "resolve") | .run' "${MONITOR_WF}" >"${STEP}"
  [[ -s "${STEP}" ]] || fail "no step with id 'resolve' in ${MONITOR_WF}"

  API="${BATS_TEST_TMPDIR}/api"
  mkdir -p "${BATS_TEST_TMPDIR}/bin" "${API}"
  # Stub gh: answers `gh api [--paginate] <path> --jq <filter>`. The workflow list is fixed and
  # holds one workflow, "Cert Warden" with id 7. A run-listing page N is served from
  # ${API}/page<N>.json (a JSON array of runs; missing means an empty page), or fails when
  # ${API}/fail<N> exists. Every requested path is appended to ${API}/calls.
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "api" ]] || { echo "unexpected gh call: $*" >&2; exit 1; }
shift
[[ "$1" == "--paginate" ]] && shift
path="$1" filter="$3"
echo "${path}" >>"${GH_STUB_API}/calls"
if [[ "${path}" == */actions/workflows ]]; then
  echo '{"workflows":[{"id":7,"name":"Cert Warden"}]}' | jq -r "${filter}"
  exit
fi
page="$(sed -E 's/.*[?&]page=([0-9]+).*/\1/' <<<"${path}")"
[[ -e "${GH_STUB_API}/fail${page}" ]] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
runs="${GH_STUB_API}/page${page}.json"
[[ -f "${runs}" ]] || runs=/dev/null
jq -s '{workflow_runs: (.[0] // [])}' "${runs}" | jq -r "${filter}"
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' >"${BATS_TEST_TMPDIR}/bin/sleep"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh" "${BATS_TEST_TMPDIR}/bin/sleep"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export GH_STUB_API="${API}"

  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
  : >"${GITHUB_OUTPUT}"
  export EVENT_NAME="schedule" WORKFLOW_NAME="Cert Warden" REPO="o/r"
  export WR_ID="" WR_CONCLUSION="" WR_URL="" WR_UPDATED=""
}

# page <N> <count> <status> <conclusion> <first id>: write page N with <count> runs, ids
# descending from <first id>. created_at follows the id, so a higher id is a newer run.
page() {
  jq -n --argjson n "$2" --arg s "$3" --arg c "$4" --argjson id0 "$5" \
    '[range($n) | ($id0 - .) as $id | {id: $id, status: $s,
      conclusion: (if $c == "" then null else $c end),
      created_at: (1790000000 + $id * 60 | todate), updated_at: "updated-\($id)",
      html_url: "https://example.test/runs/\($id)"}]' >"${API}/page$1.json"
}

run_step() {
  run bash --noprofile --norc -eo pipefail "${STEP}"
}

output_of() { sed -n "s/^$1=//p" "${GITHUB_OUTPUT}"; }

pages_fetched() { grep -c '/runs?' "${API}/calls" || true; }

@test "resolves the newest run that ran, from one page, with no search parameter" {
  page 1 30 completed success 500
  run_step
  assert_success
  assert_equal "$(output_of run-id)" "500"
  assert_equal "$(output_of conclusion)" "success"
  assert_equal "$(output_of updated-at)" "updated-500"
  assert_equal "$(output_of run-url)" "https://example.test/runs/500"
  assert_equal "$(output_of resolve-failed)" "false"
  assert_equal "$(pages_fetched)" "1"
  # The regression itself: any of these makes the listing a search capped at 1,000 results.
  run grep -E '[?&](status|branch|event|actor|created|head_sha|check_suite_id)=' "${API}/calls"
  assert_failure
}

@test "a backlog of queued and in-progress runs is paged past" {
  page 1 100 in_progress "" 1000
  page 2 100 queued "" 900
  page 3 5 completed failure 800
  run_step
  assert_success
  assert_equal "$(output_of run-id)" "800"
  assert_equal "$(output_of conclusion)" "failure"
  assert_equal "$(pages_fetched)" "3"
}

# Within what was fetched only. Across pages the step relies on the endpoint serving runs
# newest-first, as any bounded read of a long history must (see latestRun's comment).
@test "the newest run wins even when the API lists an older one first" {
  jq -n '[{id: 1, status: "completed", conclusion: "success", created_at: "2026-09-07T04:47:00Z",
             updated_at: "old", html_url: "u1"},
          {id: 9, status: "completed", conclusion: "failure", created_at: "2026-10-03T04:47:00Z",
             updated_at: "new", html_url: "u9"}]' >"${API}/page1.json"
  run_step
  assert_success
  assert_equal "$(output_of run-id)" "9"
}

@test "skipped runs are paged past to the last run that actually ran" {
  page 1 100 completed skipped 1000
  page 2 3 completed success 900
  run_step
  assert_success
  assert_equal "$(output_of run-id)" "900"
  assert_equal "$(output_of conclusion)" "success"
}

@test "with no run that ran, falls back to the newest completed run" {
  page 1 3 completed skipped 50
  run_step
  assert_success
  assert_equal "$(output_of run-id)" "50"
  assert_equal "$(output_of conclusion)" "skipped"
  assert_equal "$(pages_fetched)" "1"
}

@test "paging stops at 10 pages: nothing completed is reported as no run, not as a failure" {
  local p
  for p in $(seq 1 11); do page "${p}" 100 in_progress "" "$((5000 - p * 100))"; done
  run_step
  assert_success
  assert_equal "$(pages_fetched)" "10"
  assert_equal "$(output_of run-id)" ""
  assert_equal "$(output_of resolve-failed)" "false"
}

@test "a workflow with no runs resolves to no run, not to a failure" {
  run_step
  assert_success
  assert_equal "$(output_of run-id)" ""
  assert_equal "$(output_of conclusion)" ""
  assert_equal "$(output_of resolve-failed)" "false"
}

@test "a page the API never answers is a resolve failure, after 3 attempts" {
  page 1 100 in_progress "" 1000
  touch "${API}/fail2"
  run_step
  assert_success
  assert_equal "$(output_of resolve-failed)" "true"
  assert_equal "$(output_of run-id)" ""
  assert_equal "$(grep -c 'page=2' "${API}/calls")" "3"
}

@test "no workflow by that name warns and is not a resolve failure" {
  export WORKFLOW_NAME="Renamed Warden"
  run_step
  assert_success
  assert_output --partial "::warning::no workflow named 'Renamed Warden'"
  assert_equal "$(output_of resolve-failed)" "false"
  assert_equal "$(pages_fetched)" "0"
}

@test "workflow_run takes the run from the event and calls no API" {
  export EVENT_NAME="workflow_run" WR_ID="42" WR_CONCLUSION="success" \
    WR_URL="https://example.test/runs/42" WR_UPDATED="2026-10-03T04:47:00Z"
  run_step
  assert_success
  assert_equal "$(output_of run-id)" "42"
  assert_equal "$(output_of updated-at)" "2026-10-03T04:47:00Z"
  [[ ! -e "${API}/calls" ]]
}
