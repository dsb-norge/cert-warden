#!/usr/bin/env bash
#
# lego `exec` DNS provider hook -> challtestsrv management API. This is the same pattern
# lego's own e2e suite uses (its fixtures/update-dns.sh). Default exec mode:
#   $1 = present|cleanup, $2 = record FQDN, $3 = TXT value
#
# CW_CHALLTESTSRV_URL overrides the management endpoint (default http://127.0.0.1:8055).
set -euo pipefail

mgmt="${CW_CHALLTESTSRV_URL:-http://127.0.0.1:8055}"

case "${1:-}" in
  present)
    curl -fsS -X POST -d "{\"host\":\"${2}\", \"value\":\"${3}\"}" "${mgmt}/set-txt" >/dev/null
    ;;
  cleanup)
    curl -fsS -X POST -d "{\"host\":\"${2}\"}" "${mgmt}/clear-txt" >/dev/null
    ;;
  *)
    echo "usage: challtestsrv-hook.sh present|cleanup <fqdn> [value]" >&2
    exit 1
    ;;
esac
