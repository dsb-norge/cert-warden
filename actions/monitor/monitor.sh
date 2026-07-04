#!/usr/bin/env bash
#
#  Cert Warden monitoring — Layer A (managed-cert health) + Layer C (job health).
#
#  Reads a Cert Warden per-run metrics artifact (cert-warden-metrics-<env>.json, schema in
#  docs/cert-warden-migration/04-phase-3-test-cleanup/ §3.4) and decides whether to raise an
#  operational alert, then posts it to the DSB Teams Notifier Bot.
#
#  Design principle (short-lived / ARI model): alert on the *symptom* — a managed cert's
#  remaining lifetime shrinking (min_lifetime_fraction) — not on a single failed run, which is
#  normal and self-heals. The signal is lifetime-relative, so the same thresholds work for
#  90-day or 6-day certs and never fire on transient blips.
#
#  Inputs (environment variables):
#    METRICS_FILE             Path to the downloaded metrics JSON. May be missing/empty.
#    BOT_API_BASE             e.g. https://func-iap-teams-notifier.azurewebsites.net/api
#    BOT_API_AUDIENCE         Token audience, e.g. api://4ae764cb-...
#    BOT_ALIAS                Notify alias, e.g. from-test-env
#    ENV_NAME                 Azure env (test/dev/prod) — for labelling
#    WARN_THRESHOLD           min_lifetime_fraction warn level (default 0.40)
#    PAGE_THRESHOLD           min_lifetime_fraction page level (default 0.15)
#    CERT_WARDEN_CONCLUSION   Triggering Cert Warden run conclusion (success/failure/"")
#    CERT_WARDEN_RUN_URL      Link to the triggering run (optional)
#    METRICS_AGE_HOURS        Age of the metrics (hours) for the liveness check (optional)
#    LIVENESS_WINDOW_HOURS    Max tolerated metrics age before alerting (default 36)
#    FORCE_NOTIFY             "true" to post even when status is OK (manual test)
#    DRY_RUN                  "true" to evaluate + log but never POST
#
#  Exit code is always 0 on a completed evaluation (monitoring must not fail the workflow);
#  notification-delivery failures are logged and surfaced via the step summary.
#
set -o errexit
set -o nounset
set -o pipefail
# Command substitution inherits errexit (bash >= 4.4) — see docs/testing.md (pitfalls P-2).
shopt -s inherit_errexit

# Self-sufficient helpers load (log-info / start-group / ...): the composite action shim
# sources lib/helpers.bash (allexport) before running this script; standalone runs (tests,
# scripts/run-local.sh) load it here. helpers derives the log prefix ("monitor") from this
# script's directory.
if ! declare -F log-info >/dev/null 2>&1; then
  # shellcheck source=../../lib/helpers.bash
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../../lib/helpers.bash"
fi

# region: setup ---------------------------------------------------------------------------------

WARN_THRESHOLD="${WARN_THRESHOLD:-0.40}"
PAGE_THRESHOLD="${PAGE_THRESHOLD:-0.15}"
LIVENESS_WINDOW_HOURS="${LIVENESS_WINDOW_HOURS:-36}"
FORCE_NOTIFY="${FORCE_NOTIFY:-false}"
DRY_RUN="${DRY_RUN:-false}"
ENV_NAME="${ENV_NAME:-unknown}"
# Bot delivery config — defaulted so a DRY_RUN can be exercised without it; the workflow always
# provides real values, and the live POST path below fails loudly if any are empty.
BOT_API_BASE="${BOT_API_BASE:-}"
BOT_API_AUDIENCE="${BOT_API_AUDIENCE:-}"
BOT_ALIAS="${BOT_ALIAS:-}"
CERT_WARDEN_CONCLUSION="${CERT_WARDEN_CONCLUSION:-}"
CERT_WARDEN_RUN_URL="${CERT_WARDEN_RUN_URL:-}"
METRICS_AGE_HOURS="${METRICS_AGE_HOURS:-}"

summaryFile="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
# endregion -------------------------------------------------------------------------------------

# region: evaluate metrics ----------------------------------------------------------------------
# A "managed" cert is one Cert Warden actually maintains: it has a KV cert name and the zone was
# delegated. Non-delegated zones never produce a served cert, so they are excluded from the SLO.
minLifetimeFraction="null"
worstZone=""
worstDays=""
managedCount=0
failedCount=0
failedZones=""

# jq empty: a truncated/corrupt artifact (e.g. the warden died mid-write) must degrade to the
# absent-metrics path — the monitor NEVER fails the workflow (its core contract).
if [[ -n "${METRICS_FILE:-}" && -s "${METRICS_FILE}" ]] && jq empty "${METRICS_FILE}" 2>/dev/null; then
  start-group "metrics evaluation"

  managedCount=$(jq '[.[] | select((.kv_cert_name // "") != "" and .action != "not_delegated")] | length' "${METRICS_FILE}")
  # failed zones deliberately do NOT require a kv_cert_name: early failures (e.g. SAN
  # resolution, NS lookup) record before the name is assigned and must still alert.
  failedCount=$(jq '[.[] | select(.action != "not_delegated") | select(.action == "failed" or ((.error // "") != ""))] | length' "${METRICS_FILE}")
  failedZones=$(jq -r '[.[] | select(.action != "not_delegated") | select(.action == "failed" or ((.error // "") != "")) | .zone] | join(", ")' "${METRICS_FILE}")

  # The single SLO number: lowest remaining-lifetime fraction across managed certs (ignoring
  # nulls, which are failed issuances with no cert yet — counted separately above).
  minLifetimeFraction=$(jq '[.[] | select((.kv_cert_name // "") != "" and .action != "not_delegated") | .lifetime_fraction_remaining | select(. != null)] | (min // null)' "${METRICS_FILE}")

  if [[ "${minLifetimeFraction}" != "null" ]]; then
    worstZone=$(jq -r --argjson m "${minLifetimeFraction}" 'first(.[] | select((.kv_cert_name // "") != "" and .lifetime_fraction_remaining == $m)) | .zone' "${METRICS_FILE}")
    worstDays=$(jq -r --argjson m "${minLifetimeFraction}" 'first(.[] | select((.kv_cert_name // "") != "" and .lifetime_fraction_remaining == $m)) | (.days_to_expiry // "?")' "${METRICS_FILE}")
  fi

  echo "${_action_name}: managed=${managedCount} failed=${failedCount} min_lifetime_fraction=${minLifetimeFraction} worst_zone=${worstZone} worst_days=${worstDays}"
  end-group
else
  echo "${_action_name}: metrics file '${METRICS_FILE:-<unset>}' missing, empty or unparsable."
fi
# endregion -------------------------------------------------------------------------------------

# region: decide severity -----------------------------------------------------------------------
# Severity precedence: CRITICAL > WARNING > OK. Layer A (lifetime symptom) is the primary,
# paging signal. Layer C (run failure / no metrics / staleness) is informational and only warns
# — a single red run self-heals on the next renewal attempt.
severity="OK"
declare -a reasons=()

# Layer A — managed-cert lifetime SLO (lifetime-relative, scales to any cert duration).
if [[ "${minLifetimeFraction}" != "null" ]]; then
  if awk "BEGIN { exit !(${minLifetimeFraction} < ${PAGE_THRESHOLD}) }"; then
    severity="CRITICAL"
    reasons+=("min_lifetime_fraction ${minLifetimeFraction} < page threshold ${PAGE_THRESHOLD} (worst: ${worstZone}, ~${worstDays}d left)")
  elif awk "BEGIN { exit !(${minLifetimeFraction} < ${WARN_THRESHOLD}) }"; then
    severity="WARNING"
    reasons+=("min_lifetime_fraction ${minLifetimeFraction} < warn threshold ${WARN_THRESHOLD} (worst: ${worstZone}, ~${worstDays}d left)")
  fi
fi

# Layer C — job health (informational; never escalates above WARNING on its own).
if [[ "${managedCount}" -eq 0 && "${failedCount}" -eq 0 ]]; then
  [[ "${severity}" == "OK" ]] && severity="WARNING"
  if [[ "${CERT_WARDEN_CONCLUSION}" == "failure" ]]; then
    reasons+=("Cert Warden run failed and produced no managed-cert metrics")
  else
    reasons+=("no managed-cert metrics found (no delegated zones, or metrics artifact absent)")
  fi
elif [[ "${failedCount}" -gt 0 ]]; then
  # A few failed renewals are tolerable while lifetime is healthy; note them, warn at most.
  [[ "${severity}" == "OK" ]] && severity="WARNING"
  reasons+=("${failedCount} managed zone(s) reported a cert error: ${failedZones}")
fi

# Liveness — metrics older than the window (scaled to cert lifetime) means Cert Warden may have
# stopped running entirely. Informational/WARNING.
if [[ -n "${METRICS_AGE_HOURS}" ]] && awk "BEGIN { exit !(${METRICS_AGE_HOURS} > ${LIVENESS_WINDOW_HOURS}) }"; then
  [[ "${severity}" == "OK" ]] && severity="WARNING"
  reasons+=("latest Cert Warden metrics are ${METRICS_AGE_HOURS}h old (> ${LIVENESS_WINDOW_HOURS}h liveness window)")
fi

echo "${_action_name}: severity=${severity}"
# endregion -------------------------------------------------------------------------------------

# region: step summary --------------------------------------------------------------------------
{
  echo "### Cert Warden monitor — ${ENV_NAME} — ${severity}"
  echo ""
  echo "| Metric | Value |"
  echo "| --- | --- |"
  echo "| Managed certs | ${managedCount} |"
  echo "| Failed | ${failedCount}${failedZones:+ (${failedZones})} |"
  echo "| min_lifetime_fraction | ${minLifetimeFraction} |"
  echo "| Worst zone | ${worstZone:-n/a}${worstDays:+ (~${worstDays}d left)} |"
  echo "| Cert Warden run | ${CERT_WARDEN_CONCLUSION:-n/a} |"
  if ((${#reasons[@]})); then
    echo ""
    echo "**Alert reasons:**"
    for r in "${reasons[@]}"; do echo "- ${r}"; done
  fi
} >>"${summaryFile}"
# endregion -------------------------------------------------------------------------------------

# region: outputs -------------------------------------------------------------------------------
# Generous outputs (design decision D-14): everything a caller needs to build its own delivery
# or gating on top of the evaluation. Emitted at every exit path; notified/notify-http-status
# are re-emitted after a delivery attempt (last occurrence wins in GITHUB_OUTPUT).
notified="false"
notifyHttpStatus=""
emitOutputs() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  {
    log-info "severity=${severity}"
    log-info "min-lifetime-fraction=${minLifetimeFraction}"
    log-info "managed-count=${managedCount}"
    log-info "failed-count=${failedCount}"
    log-info "worst-zone=${worstZone}"
    log-info "reasons-json=$(printf '%s\n' "${reasons[@]:-}" | jq -R . | jq -sc 'map(select(. != ""))')"
    log-info "notified=${notified}"
    log-info "notify-http-status=${notifyHttpStatus}"
  } >>"${GITHUB_OUTPUT}"
}
# endregion -------------------------------------------------------------------------------------

# region: notify --------------------------------------------------------------------------------
if [[ "${severity}" == "OK" && "${FORCE_NOTIFY}" != "true" ]]; then
  echo "${_action_name}: status OK — no notification sent (set FORCE_NOTIFY=true to test delivery)."
  emitOutputs
  exit 0
fi

# Adaptive Card colour by severity (Attention=red, Warning=amber, Good=green).
case "${severity}" in
  CRITICAL)
    cardColor="Attention"
    title="🔴 Cert Warden CRITICAL (${ENV_NAME})"
    ;;
  WARNING)
    cardColor="Warning"
    title="🟠 Cert Warden warning (${ENV_NAME})"
    ;;
  *)
    cardColor="Good"
    title="🟢 Cert Warden OK (${ENV_NAME})"
    ;;
esac

reasonsText=$(printf '%s\n' "${reasons[@]:-no issues}" | sed 's/^/- /')
factsJson=$(jq -n \
  --arg env "${ENV_NAME}" \
  --arg managed "${managedCount}" \
  --arg failed "${failedCount}" \
  --arg minlf "${minLifetimeFraction}" \
  --arg worst "${worstZone:-n/a}${worstDays:+ (~${worstDays}d)}" \
  --arg run "${CERT_WARDEN_CONCLUSION:-n/a}" \
  '[
     {title: "Environment", value: $env},
     {title: "Managed certs", value: $managed},
     {title: "Failed", value: $failed},
     {title: "min_lifetime_fraction", value: $minlf},
     {title: "Worst zone", value: $worst},
     {title: "Cert Warden run", value: $run}
   ]')

card=$(jq -n \
  --arg title "${title}" \
  --arg color "${cardColor}" \
  --arg reasons "${reasonsText}" \
  --arg url "${CERT_WARDEN_RUN_URL}" \
  --argjson facts "${factsJson}" \
  '{
    type: "AdaptiveCard",
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    version: "1.4",
    body: ([
      {type: "TextBlock", text: $title, weight: "Bolder", size: "Medium", color: $color, wrap: true},
      {type: "TextBlock", text: $reasons, wrap: true},
      {type: "FactSet", facts: $facts}
    ] + (if $url != "" then [{type: "TextBlock", text: ("[Cert Warden run](" + $url + ")"), wrap: true}] else [] end))
  }')

payload=$(jq -n --argjson card "${card}" --arg env "${ENV_NAME}" \
  '{format: "adaptive-card", message: $card, metadata: {environment: $env, source: "cert-warden-monitor"}}')

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "${_action_name}: DRY_RUN — would POST to ${BOT_API_BASE}/v1/notify/${BOT_ALIAS}:"
  echo "${payload}" | jq .
  emitOutputs
  exit 0
fi

if [[ -z "${BOT_API_BASE}" && -z "${BOT_API_AUDIENCE}" && -z "${BOT_ALIAS}" ]]; then
  # Evaluate-only mode (documented, first-class): no bot config at all — outputs carry the result.
  echo "${_action_name}: evaluate-only mode (no bot configuration) — severity=${severity}, no delivery attempted."
  emitOutputs
  exit 0
elif [[ -z "${BOT_API_BASE}" || -z "${BOT_API_AUDIENCE}" || -z "${BOT_ALIAS}" ]]; then
  # PARTIAL bot config is a misconfiguration worth shouting about.
  echo "::error::${_action_name}: partial bot configuration — BOT_API_BASE / BOT_API_AUDIENCE / BOT_ALIAS must all be set to deliver."
  emitOutputs
  exit 0
fi

start-group "notify bot"
if ! token=$(az account get-access-token --resource "${BOT_API_AUDIENCE}" --query accessToken -o tsv); then
  echo "::warning::${_action_name}: could not acquire a token for ${BOT_API_AUDIENCE} — notification not delivered (evaluation stands)."
  echo "::endgroup::"
  emitOutputs
  exit 0
fi
# --max-time: a black-holed endpoint must not hang the job. On connect failure curl itself
# prints 000 via -w; `|| true` only guards errexit (no duplicated fallback output).
httpStatus=$(curl -sS --max-time 30 -o /tmp/notify-resp.json -w '%{http_code}' \
  -X POST "${BOT_API_BASE}/v1/notify/${BOT_ALIAS}" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -d "${payload}" || true)
echo "${_action_name}: bot responded HTTP ${httpStatus}"
cat /tmp/notify-resp.json 2>/dev/null || true
end-group

notifyHttpStatus="${httpStatus}"
if [[ "${httpStatus}" != "202" && "${httpStatus}" != "200" ]]; then
  echo "::warning::${_action_name}: notification delivery failed (HTTP ${httpStatus})."
else
  notified="true"
fi
emitOutputs
# endregion -------------------------------------------------------------------------------------
