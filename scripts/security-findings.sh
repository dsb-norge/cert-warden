#!/usr/bin/env bash
#
# security-findings.sh
#
# Lists the open findings on the repository's "Security and quality" tab: code scanning (CodeQL
# Default Setup, zizmor), Code Quality standard findings, Dependabot vulnerability and malware
# alerts, and secret scanning default and generic alerts. Findings recorded as permanently
# ignored in docs/security-findings.md are left out; entries there that are no longer open are
# reported so they can be pruned.
#
# A source the repository has not enabled (Code Quality, at the time of writing) is reported as
# such rather than failing the run. Any other API failure does fail it: a report with a source
# silently missing would read as a clean one.
#
# Code Quality AI findings are not covered: GitHub has no API for them.
# Read-only: nothing is dismissed or changed on GitHub.
#
# Ported from dsb-norge/teams-notifier-function-app (scripts/security-findings.sh); the routine
# around it is in docs/security-findings.md.
#
# Usage:
#   bash scripts/security-findings.sh [--repo <owner/name>] [--wait] [--all] [--json]
#
#   --repo   repository to query (default: dsb-norge/cert-warden)
#   --wait   first wait until the scans on main's HEAD commit have finished
#   --all    also list the permanently ignored findings, marked "(ignored)"
#   --json   print one JSON object instead of the text report
#
# Requires gh (authenticated, `repo` scope) and jq.
#
set -euo pipefail
shopt -s inherit_errexit

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ignoreDoc="${scriptDir}/../docs/security-findings.md"

repo="dsb-norge/cert-warden"
branch="main"
wait=false
showIgnored=false
json=false

# Workflow runs that feed the Security tab, matched against the run's `path`: CodeQL Default
# Setup (and Code Quality, should it be enabled), the dependency graph, and ci.yml, whose zizmor
# job uploads SARIF on every push to main.
scanRunPattern='^dynamic/github-code-(scanning|quality)/|^dynamic/dependency-graph/|/ci\.yml$'
waitInterval=20
waitTimeout=1800

# Generic secret types are not returned unless asked for by name.
# https://docs.github.com/en/code-security/secret-scanning/introduction/supported-secret-scanning-patterns
genericSecretTypes="ec_private_key,generic_private_key,http_basic_authentication_header,http_bearer_authentication_header,mongodb_connection_string,mysql_connection_url,openssh_private_key,pgp_private_key,postgres_connection_string,rsa_private_key,password"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --wait)
      wait=true
      shift
      ;;
    --all)
      showIgnored=true
      shift
      ;;
    --json)
      json=true
      shift
      ;;
    -h | --help)
      echo "Usage: $(basename "$0") [--repo <owner/name>] [--wait] [--all] [--json]"
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      exit 1
      ;;
  esac
done

errFile="$(mktemp)"
trap 'rm -f "${errFile}"' EXIT

# --- Helpers ---

# Every page of a list endpoint, merged into one array. Prints `null` for a source the repository
# has not enabled -- GitHub answers "... is not enabled" or "... disabled" (403/404), or "no
# analysis found" for code scanning that has never run -- so the report can say so. Any other
# failure is fatal.
api_list() {
  local _out
  if _out="$(gh api --paginate "$1" 2>"${errFile}")"; then
    jq -s 'add // []' <<<"${_out}"
  elif grep -qiE 'not enabled|disabled|no analysis found' "${errFile}"; then
    echo null
  else
    echo "Error: gh api $1 failed: $(cat "${errFile}")" >&2
    return 1
  fi
}

scan_runs() {
  gh api "repos/${repo}/actions/runs?head_sha=$1&per_page=100" |
    jq --arg p "${scanRunPattern}" \
      '[.workflow_runs[] | select(.path | test($p)) | {name, status, conclusion}]'
}

# --- Scan freshness ---
headSha="$(gh api "repos/${repo}/commits/${branch}" -q .sha)"
runs="$(scan_runs "${headSha}")"

if ${wait}; then
  waited=0
  until jq -e 'length > 0 and all(.status == "completed")' <<<"${runs}" >/dev/null; do
    if ((waited >= waitTimeout)); then
      echo "Error: scans on ${headSha:0:7} not finished after ${waitTimeout}s" >&2
      exit 2
    fi
    sleep "${waitInterval}"
    waited=$((waited + waitInterval))
    runs="$(scan_runs "${headSha}")"
  done
fi

# --- Permanently ignored findings ---
# Table rows in the ignore doc start with the finding ID in backticks.
ignored='[]'
if [[ -f "${ignoreDoc}" ]]; then
  # shellcheck disable=SC2016  # the backticks are literal Markdown
  ignored="$(grep -oE '^\| *`(code-scanning|code-quality|dependabot|secret-scanning)#[0-9]+`' "${ignoreDoc}" |
    grep -oE '[a-z-]+#[0-9]+' |
    jq -R -s 'split("\n") | map(select(length > 0)) | unique' || true)"
  [[ -n "${ignored}" ]] || ignored='[]'
fi

# --- Fetch and normalise ---
# Each source is an array of findings, or null when the repository has not enabled it.
codeScanning="$(api_list "repos/${repo}/code-scanning/alerts?state=open&per_page=100" | jq '
  if . == null then null else map({
    id: "code-scanning#\(.number)",
    tool: .tool.name,
    severity: (.rule.security_severity_level // .rule.severity),
    rule: .rule.id,
    location: "\(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)",
    title: .rule.description,
    url: .html_url
  }) end')"

codeQuality="$(api_list "repos/${repo}/code-quality/findings?state=open&per_page=100" | jq '
  if . == null then null else map({
    id: "code-quality#\(.number)",
    tool: "CodeQL",
    severity: .rule.severity,
    rule: .rule.id,
    location: "\(.location.path):\(.location.start_line)",
    title: .rule.title,
    url: null
  }) end')"

dependabot="$(api_list "repos/${repo}/dependabot/alerts?state=open&classification=malware,general&per_page=100" | jq '
  if . == null then null else map({
    id: "dependabot#\(.number)",
    tool: (if .security_advisory.classification == "malware" then "Dependabot malware" else "Dependabot" end),
    severity: .security_advisory.severity,
    rule: .security_advisory.ghsa_id,
    location: "\(.dependency.package.ecosystem):\(.dependency.package.name) (\(.dependency.manifest_path))",
    title: (.security_advisory.summary
      + (if .security_vulnerability.first_patched_version.identifier
         then " (fixed in \(.security_vulnerability.first_patched_version.identifier))" else "" end)),
    url: .html_url
  }) end')"

# hide_secret keeps secret values out of the output.
secret_alerts() {
  api_list "repos/${repo}/secret-scanning/alerts?state=open&hide_secret=true&per_page=100$1" | jq --arg tool "$2" '
    if . == null then null else map({
      id: "secret-scanning#\(.number)",
      tool: $tool,
      severity: "secret",
      rule: .secret_type,
      location: (if .first_location_detected.path
                 then "\(.first_location_detected.path):\(.first_location_detected.start_line)" else null end),
      title: .secret_type_display_name,
      url: .html_url
    }) end'
}
secretsDefault="$(secret_alerts "" "Secret scanning")"
secretsGeneric="$(secret_alerts "&secret_type=${genericSecretTypes}" "Secret scanning (generic)")"
secrets="$(jq -n --argjson a "${secretsDefault}" --argjson b "${secretsGeneric}" \
  'if $a == null and $b == null then null else ($a // []) + ($b // []) | unique_by(.id) end')"

report="$(jq -n \
  --arg repo "${repo}" --arg branch "${branch}" --arg sha "${headSha}" \
  --argjson runs "${runs}" --argjson ignored "${ignored}" \
  --argjson cs "${codeScanning}" --argjson cq "${codeQuality}" \
  --argjson dep "${dependabot}" --argjson sec "${secrets}" '
  (($cs // []) + ($cq // []) + ($dep // []) + ($sec // [])
    | map(.id as $id | .ignored = any($ignored[]; . == $id))) as $all
  | {
      repo: $repo,
      branch: $branch,
      head_sha: $sha,
      scans_complete: ($runs | length > 0 and all(.status == "completed")),
      scan_runs: $runs,
      sources: {
        "code-scanning": ($cs != null),
        "code-quality": ($cq != null),
        "dependabot": ($dep != null),
        "secret-scanning": ($sec != null)
      },
      findings: $all,
      stale_ignores: ($ignored - ($all | map(.id)))
    }')"

if ${json}; then
  echo "${report}"
  exit 0
fi

# --- Text report ---
jq -r --argjson show_ignored "${showIgnored}" '
  def section($prefix; $label):
    if .sources[$prefix] | not then
      "\n\($label): not enabled for this repository"
    else
      [.findings[] | select(.id | startswith($prefix + "#"))] as $f
      | ($f | map(select(.ignored | not))) as $open
      | ($f | map(select(.ignored))) as $ign
      | "\n\($label): \($open | length) to assess"
        + (if ($ign | length) > 0 then ", \($ign | length) ignored" else "" end),
        ( ($open + (if $show_ignored then $ign else [] end))[]
          | "  \(.id)  \(.severity // "-")  \(.tool): \(.rule)  \(.location // "")"
            + (if .ignored then "  (ignored)" else "" end),
            (if .title then "      \(.title)" else empty end) )
    end;

  "Security and quality findings for \(.repo) (\(.branch) at \(.head_sha[0:7]))",
  ( if (.scan_runs | length) == 0 then
      "WARNING: no scan runs found for \(.head_sha[0:7]) yet; results may predate it. Rerun with --wait."
    elif .scans_complete then
      "Scans on \(.head_sha[0:7]): \(.scan_runs | length) runs, all completed."
    else
      "WARNING: scans on \(.head_sha[0:7]) still running (\([.scan_runs[] | select(.status != "completed") | .name] | join(", "))). Rerun with --wait."
    end ),
  section("code-scanning"; "Code scanning"),
  section("code-quality"; "Code Quality (standard findings)"),
  section("dependabot"; "Dependabot"),
  section("secret-scanning"; "Secret scanning"),
  ( if (.stale_ignores | length) > 0 then
      "\nNo longer open, prune from docs/security-findings.md: \(.stale_ignores | join(", "))"
    else empty end ),
  "\nTotal: \([.findings[] | select(.ignored | not)] | length) to assess, \([.findings[] | select(.ignored)] | length) permanently ignored.",
  "Not covered: Code Quality AI findings (no API; UI only)."
' <<<"${report}"
