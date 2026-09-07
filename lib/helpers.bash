#!/usr/bin/env bash
#
# Shared logging/output helpers, sourced by every script in this repo (and exported to steps by
# the composite-action shims via `set -o allexport`). Descends from the dsb-norge composite
# action helper conventions.

# Log prefix: explicit CW_ACTION_NAME wins (the action shims set it); otherwise the directory
# name of the outermost running script (actions/warden/cert-warden.sh -> "warden").
_action_name="${CW_ACTION_NAME:-$(basename "$(cd -- "$(dirname -- "${BASH_SOURCE[-1]}")" &>/dev/null && pwd)")}"

# Helper functions
function _log { echo "${1}${_action_name}: ${2}"; }
function log-info { _log "" "${*}"; }
function log-debug { _log "DEBUG: " "${*}"; }
function log-warn { _log "WARN: " "${*}"; }
function log-error { _log "ERROR: " "${*}"; }
function start-group { echo "::group::${_action_name}: ${*}"; }
function end-group { echo "::endgroup::"; }
function log-multiline {
  start-group "${1}"
  echo "${2}"
  end-group
}
function mask-value { echo "::add-mask::${*}"; }
# GITHUB_OUTPUT is required by these two — failing loudly beats writing into the void.
function set-output { echo "${1}=${2}" >>"${GITHUB_OUTPUT:?set-output requires GITHUB_OUTPUT}"; }
function set-multiline-output {
  local outputName outputValue delimiter
  outputName="${1}"
  outputValue="${2}"
  # Random delimiter so a value containing a fixed marker can't terminate the heredoc early
  # (output-injection class — see docs/testing.md, pitfall P-10).
  delimiter="EOF-$(dd if=/dev/urandom bs=15 count=1 status=none | base64 | tr -d '=+/')"
  {
    echo "${outputName}<<${delimiter}"
    echo "${outputValue}"
    echo "${delimiter}"
  } >>"${GITHUB_OUTPUT:?set-multiline-output requires GITHUB_OUTPUT}"
}
# ---------------------------------------------------------------------------------------------
# Shared jq definitions.
#
# One place for vocabulary that BOTH the warden and the monitor have to agree on. Prepend it to a
# jq program and the definitions are in scope:
#
#     jq "${CW_JQ_LIB} [.[] | select(cw_is_due)] | length" metrics.json
#
# `cw_is_due` answers "would lego renew this certificate now?" for a metrics record, WITHOUT
# asking lego. That distinction matters: the engine never predicts dueness -- ARI decides inside
# lego and stays authoritative for what actually gets renewed. This is for REPORTING only: an
# `action: deferred` record means "not evaluated this run", which conflates a certificate that is
# genuinely waiting with one that is simply healthy and sorted last by the urgency walk. Counting
# the healthy ones as backlog overstates a wave (a real run reported 38 deferred renewals of which
# 16 were waiting and 22 were four months from needing anything).
#
# The threshold is not a guess at lego's rule -- it IS lego's rule, from cmd_run_renew.go
# (getDueDate): with `--renew-days` unset the due date is `notAfter - lifetime/3`, and
# `notAfter - lifetime/2` when the lifetime is 10 days or less. The record carries no lifetime, but
# days_to_expiry / lifetime_fraction_remaining recovers it, which keeps this duration-independent
# in the same way the monitor's thresholds are.
#
# Where it is approximate: ARI is primary, and its window is a span the CA chooses which lego
# jitters within, so a certificate a hair either side of the point may disagree with lego by hours.
# On a multi-day drain estimate that is noise, and it errs toward counting more as due.
#
# shellcheck disable=SC2016,SC2034 # a jq program, not bash: no expansion wanted, and bash never reads it
CW_JQ_LIB='
  def cw_is_due:
    if (.lifetime_fraction_remaining // null) == null then false
    elif .lifetime_fraction_remaining <= 0 then true
    elif (.days_to_expiry // null) == null then false
    else (.days_to_expiry / .lifetime_fraction_remaining) as $lifetimeDays
      | .lifetime_fraction_remaining < (if $lifetimeDays > 10 then 1 / 3 else 1 / 2 end)
    end;
  def cw_deferred: .action == "deferred";
  def cw_renewed: .action == "renewed" or .action == "forced";
  def cw_holds_cert: (.lifetime_fraction_remaining // null) != null;
'

log-info "'$(basename "${BASH_SOURCE[0]}")' loaded."
