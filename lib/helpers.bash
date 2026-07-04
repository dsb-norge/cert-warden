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
log-info "'$(basename "${BASH_SOURCE[0]}")' loaded."
