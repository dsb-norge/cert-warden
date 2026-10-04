#!/usr/bin/env bash
#
# Cert Warden sweeper — soft-deletes orphaned / expired objects from the new web-certs
# Key Vault (kv-cm-net-wcerts-<env>). See docs/cert-warden-migration/04-phase-3-test-cleanup/
# §3.1–§3.3. Deliberately small and obvious: it only ever *deletes* (soft-delete; KV's 7-day
# window keeps everything recoverable), never creates or modifies.
#
# What it targets (and, just as important, what it never touches):
#
#   DELETE — orphan name patterns (objects orphaned by design, see §3.1):
#     - certs  matching  ${TARGET_CERT_PREFIXES}    (default: le-cert-staging-)
#     - secrets matching ${TARGET_SECRET_PREFIXES}  (default: le-cert-staging- , letsencrypt-staging-account-)
#       (the le-cert-staging-*-meta ARI secrets are caught by the le-cert-staging- prefix)
#   DELETE — expiry (the deterministic catch-all):
#     - any cert the warden issued (it carries the IssuedBy tag, docs/contracts.md §3) whose
#       attributes.expires is in the past, UNLESS its name matches a protected prefix. This
#       INCLUDES le-cert-production-* certs: a *live* Cert Warden production cert is never expired
#       (it is renewed well ahead of expiry via ARI), so the only warden certs that ever reach
#       expiry are ORPHANS — e.g. a zone removed from dns_zones whose listener + placeholder TF
#       dropped, leaving its cert to lapse (§3.1). Those SHOULD be reaped, which is why
#       le-cert-production- is deliberately NOT protected (sweeping by expiry, not by name).
#   KEEP — an expired cert WITHOUT the IssuedBy tag. In practice that is a consumer-seeded
#     placeholder (docs/consumer-prerequisites.md), and a placeholder can expire while it is still
#     in service: the warden skips a zone that is not publicly delegated, so it never replaces the
#     placeholder, and a listener keeps referencing it. Deleting it would break that reference,
#     and the consumer's IaC, which manages the object, would recover it on its next apply -- the
#     sweep and the apply undoing each other every week. Removing a placeholder is the IaC's job.
#   DELETE — orphaned lego metadata (follows the certificate it belongs to):
#     - any le-cert-*-pfx-meta secret whose certificate (the same name without -meta) is not in
#       the vault, or is deleted by this run. The warden writes one beside every certificate it
#       issues and never deletes it, so a production zone removed from dns_zones would otherwise
#       leave its -meta behind for good, whether the consumer's IaC purged the certificate or let
#       it lapse for the expiry rule above. Matched by the naming scheme (docs/contracts.md §3)
#       rather than a prefix input. The warden recovers a -meta this rule soft-deleted if the
#       zone comes back while its name is still reserved.
#   NEVER DELETE — protected prefixes (${PROTECTED_PREFIXES}):
#     - cert-                         TF-managed legacy acme imports (Terraform owns their
#                                     lifecycle; under the "accept destruction" route TF drops
#                                     them on 2-drop-acme — the sweeper must not race TF)
#     - letsencrypt-production-account-   the live LE production account secrets (never expire as
#                                     certs; protected by name as belt-and-suspenders)
#   The live le-cert-production-* slot needs NO name protection: it is safe by virtue of never
#   being expired, or, while it holds a placeholder, of not being the warden's. (Edge case: a renewal that fails until the live cert actually lapses would be
#   reaped — but Layer A monitoring pages on shrinking lifetime long before that, §3.4.)
#
# Safety:
#   - LOG_ONLY=true  -> evaluate + log what WOULD be deleted, delete nothing (dev/debug default-safe).
#   - MAX_DELETIONS  -> abort before deleting if the candidate count exceeds this (spike guard;
#                       a sudden jump from the expected handful is a signal something is wrong).
#   - A protected-prefix match always wins over any target/expiry match.
#   - Soft delete keeps each name taken for the retention period. The warden recovers any name it
#     has to write again (a certificate, an account secret, a -meta), so a sweep never blocks its
#     next run -- a staging canary's included.
#
# Requires: az (logged in as an identity with Key Vault Certificates Officer + Secrets Officer on
# the vault — the cert_maintainer identity already has both) and jq. The runner must reach the
# PE-only vault (the same network path Cert Warden imports through).

set -euo pipefail
# Command substitution inherits errexit (bash >= 4.4) — see docs/testing.md (pitfalls P-2).
shopt -s inherit_errexit

# Load shared helpers (log-info / log-warn / log-error / start-group / end-group). The composite
# action shim sources + exports them (set -o allexport) before running this script; source here
# only for standalone/local runs.
if ! declare -F log-info >/dev/null 2>&1; then
  # shellcheck source=../../lib/helpers.bash
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../../lib/helpers.bash"
fi

# --- configuration (env-driven; the workflow sets these) ------------------------------------
KV_NAME="${KV_NAME:?KV_NAME is required (the web-certs Key Vault name)}"
LOG_ONLY="${LOG_ONLY:-true}" # default-safe: dry run unless explicitly disabled
SWEEP_EXPIRED="${SWEEP_EXPIRED:-true}"
MAX_DELETIONS="${MAX_DELETIONS:-120}" # ~ (41 staging certs + 41 -meta + a few account secrets) with headroom; a removed production zone adds one orphaned -meta

# Space-separated name prefixes. Defaults encode the Cert Warden migration's orphan-by-design set.
TARGET_CERT_PREFIXES="${TARGET_CERT_PREFIXES:-le-cert-staging-}"
TARGET_SECRET_PREFIXES="${TARGET_SECRET_PREFIXES:-le-cert-staging- letsencrypt-staging-account-}"
PROTECTED_PREFIXES="${PROTECTED_PREFIXES:-letsencrypt-production-account- cert-}"

# The tag the warden stamps on every certificate it imports, and so what tells a certificate it
# issued from a placeholder at the same name (docs/contracts.md §3). The expiry rule reaps only
# certificates that carry it. Must match wardenIssuedTagName in actions/warden/cert-warden.sh.
wardenIssuedTagName="IssuedBy"

# --- helpers --------------------------------------------------------------------------------

# Return 0 when $1 starts with any of the space-separated prefixes in $2, else 1.
# EXIT CODES, deliberately not stdout: string-returning predicates are the fragility class
# that let a logging refactor silently break this selection logic once (docs/testing.md P-22).
function matches_any_prefix {
  local name="${1}" prefixes="${2}" p
  for p in ${prefixes}; do
    [[ "${name}" == "${p}"* ]] && return 0
  done
  return 1
}

# Guard: a protected prefix always wins. Returns 0 when the name must never be deleted.
function is_protected {
  matches_any_prefix "${1}" "${PROTECTED_PREFIXES}"
}

# Return 0 when $1 equals any of the remaining arguments, else 1.
function in_list {
  local needle="${1}" item
  shift
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

# Return 0 when $1 is lego metadata (le-cert-<le-env>-<zone>-pfx-meta) whose certificate does not
# stay in the vault: it is not listed, or this run deletes it. Reads staying_certs, filled by the
# certificate pass. That list comes from `certificate list` on purpose: `az keyvault secret list`
# leaves out certificate-backing secrets (no --include-managed), so a certificate is never
# visible in the secret listing, and pairing against that would orphan every -meta in the vault.
function is_orphaned_meta {
  [[ "${1}" == le-cert-*-pfx-meta ]] || return 1
  ! in_list "${1%-meta}" "${staying_certs[@]+"${staying_certs[@]}"}"
}

# --- gather deletion candidates -------------------------------------------------------------

log-info "Sweeper starting for vault '${KV_NAME}' (LOG_ONLY=${LOG_ONLY}, SWEEP_EXPIRED=${SWEEP_EXPIRED})."
log-info "Protected prefixes (never deleted): ${PROTECTED_PREFIXES}"

now_epoch="$(date -u +%s)"

# Certs: name + expiry (empty when the cert has no expiry set) + the warden's tag (empty when
# absent: a JMESPath projection of a missing tag is null). The az calls are
# captured and failure-checked explicitly: `mapfile < <(az ...)` swallows the exit status
# (pitfall P-7 class), and a silently-empty listing would turn a scheduled destructive sweep
# into a green no-op — or worse, desynchronize the cert/secret views.
certListJson="$(az keyvault certificate list --vault-name "${KV_NAME}" \
  --query "[].{name:name, exp:attributes.expires, issuedBy:tags.${wardenIssuedTagName}}" -o json)" || {
  log-error "Failed to list certificates in '${KV_NAME}' — aborting sweep."
  exit 1
}
jq -e 'type == "array"' <<<"${certListJson}" >/dev/null 2>&1 || {
  log-error "Certificate listing from az is not a JSON array — aborting sweep."
  exit 1
}
mapfile -t cert_rows < <(jq -r '.[] | "\(.name)\t\(.exp // "")\t\(.issuedBy // "")"' <<<"${certListJson}")

# Secrets: name only.
secretListTsv="$(az keyvault secret list --vault-name "${KV_NAME}" --query "[].name" -o tsv)" || {
  log-error "Failed to list secrets in '${KV_NAME}' — aborting sweep."
  exit 1
}
mapfile -t secret_names < <(printf '%s' "${secretListTsv}")

# staying_certs: every listed certificate this run does not delete (see is_orphaned_meta).
declare -a del_certs=() del_secrets=() staying_certs=()

start-group "Evaluating ${#cert_rows[@]} certificate(s)"
for row in "${cert_rows[@]}"; do
  # Split by hand, not with `read`: tab is IFS whitespace, so an empty field would collapse.
  name="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  exp="${rest%%$'\t'*}"
  issued_by="${rest#*$'\t'}"

  if is_protected "${name}"; then
    log-info "  protect : ${name} (protected prefix)"
    staying_certs+=("${name}")
    continue
  fi

  reason=""
  note=""
  if matches_any_prefix "${name}" "${TARGET_CERT_PREFIXES}"; then
    reason="orphan-name"
  elif [[ "${SWEEP_EXPIRED}" == "true" && -n "${exp}" ]]; then
    # az returns ISO-8601; convert to epoch and compare.
    exp_epoch="$(date -u -d "${exp}" +%s 2>/dev/null || echo 0)"
    if [[ "${exp_epoch}" -gt 0 && "${exp_epoch}" -lt "${now_epoch}" ]]; then
      if [[ -n "${issued_by}" ]]; then
        reason="expired(${exp})"
      else
        note=" (expired ${exp}, but no '${wardenIssuedTagName}' tag: not the warden's, e.g. a seeded placeholder)"
      fi
    fi
  fi

  if [[ -n "${reason}" ]]; then
    log-info "  DELETE  : ${name} [${reason}]"
    del_certs+=("${name}")
  else
    log-info "  keep    : ${name}${note}"
    staying_certs+=("${name}")
  fi
done
end-group

start-group "Evaluating ${#secret_names[@]} secret(s)"
for name in "${secret_names[@]}"; do
  if is_protected "${name}"; then
    log-info "  protect : ${name} (protected prefix)"
    continue
  fi
  if matches_any_prefix "${name}" "${TARGET_SECRET_PREFIXES}"; then
    log-info "  DELETE  : ${name} [orphan-name]"
    del_secrets+=("${name}")
  elif is_orphaned_meta "${name}"; then
    log-info "  DELETE  : ${name} [orphan-meta]"
    del_secrets+=("${name}")
  else
    log-info "  keep    : ${name}"
  fi
done
end-group

# NOTE: deleting a certificate also deletes its backing secret of the same name, and deleting
# that secret again would 404 and abort the sweep half-way. `az keyvault secret list` leaves
# certificate-backing secrets out (we don't pass --include-managed), so in practice there is
# nothing to filter here; it stays as a guard should the listing ever include them.
declare -a del_secrets_filtered=()
for s in "${del_secrets[@]+"${del_secrets[@]}"}"; do
  skip="false"
  for c in "${del_certs[@]+"${del_certs[@]}"}"; do
    if [[ "${s}" == "${c}" ]]; then
      skip="true"
      break
    fi
  done
  [[ "${skip}" == "false" ]] && del_secrets_filtered+=("${s}")
done
del_secrets=("${del_secrets_filtered[@]+"${del_secrets_filtered[@]}"}")

total=$((${#del_certs[@]} + ${#del_secrets[@]}))
log-info "Candidates: ${#del_certs[@]} certificate(s) + ${#del_secrets[@]} secret(s) = ${total} total."

# Generous outputs (D-14): callers can gate/report on the evaluation regardless of mode.
# deleted-count is re-emitted after a destructive pass (last occurrence wins).
# NOTE: machine-read emission — always via set-output, never the log-* helpers (their
# "<tool>: " prefix corrupts GITHUB_OUTPUT keys; bit us once already).
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  set-output "candidates-count" "${total}"
  set-output "candidates-json" "$(jq -nc \
    --argjson certs "$(printf '%s\n' "${del_certs[@]+"${del_certs[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')" \
    --argjson secrets "$(printf '%s\n' "${del_secrets[@]+"${del_secrets[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')" \
    '{certificates: $certs, secrets: $secrets}')"
  set-output "deleted-count" "0"
fi

# --- safety cap -----------------------------------------------------------------------------
if [[ "${total}" -gt "${MAX_DELETIONS}" ]]; then
  log-error "Candidate count ${total} exceeds MAX_DELETIONS=${MAX_DELETIONS} — aborting without deleting."
  log-error "This is a spike guard. Inspect the list above; raise MAX_DELETIONS only if the spike is expected."
  exit 1
fi

# --- step summary (audit trail) -------------------------------------------------------------
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Cert Warden sweeper — \`${KV_NAME}\`"
    echo ""
    echo "- Mode: **$([[ "${LOG_ONLY}" == "true" ]] && echo "log-only (dry run)" || echo "destructive")**"
    echo "- Certificates to delete: **${#del_certs[@]}**"
    echo "- Secrets to delete: **${#del_secrets[@]}**"
    # shellcheck disable=SC2016 # literal backticks for markdown; %s is a printf placeholder, not a shell expansion
    [[ "${#del_certs[@]}" -gt 0 ]] && printf '  - cert: `%s`\n' "${del_certs[@]}"
    # shellcheck disable=SC2016
    [[ "${#del_secrets[@]}" -gt 0 ]] && printf '  - secret: `%s`\n' "${del_secrets[@]}"
  } >>"${GITHUB_STEP_SUMMARY}"
fi

# --- act ------------------------------------------------------------------------------------
if [[ "${LOG_ONLY}" == "true" ]]; then
  log-info "LOG_ONLY=true — nothing deleted. Re-run with LOG_ONLY=false to soft-delete the ${total} object(s) above."
  exit 0
fi

if [[ "${total}" -eq 0 ]]; then
  log-info "Nothing to delete. Done."
  exit 0
fi

deleted=0
# Keep the emitted deleted-count truthful even if a delete fails mid-loop (set -e aborts):
# the trap re-emits the running total on ANY exit (last occurrence wins in GITHUB_OUTPUT).
emit_deleted_count() {
  [[ -z "${GITHUB_OUTPUT:-}" ]] || set-output "deleted-count" "${deleted}"
}
trap emit_deleted_count EXIT
start-group "Soft-deleting ${total} object(s)"
for name in "${del_certs[@]+"${del_certs[@]}"}"; do
  log-info "  deleting cert  : ${name}"
  az keyvault certificate delete --vault-name "${KV_NAME}" --name "${name}" >/dev/null
  deleted=$((deleted + 1))
done
for name in "${del_secrets[@]+"${del_secrets[@]}"}"; do
  log-info "  deleting secret: ${name}"
  az keyvault secret delete --vault-name "${KV_NAME}" --name "${name}" >/dev/null
  deleted=$((deleted + 1))
done
end-group

log-info "Soft-deleted ${deleted} object(s) from '${KV_NAME}' (recoverable for the KV soft-delete window)."
# (final deleted-count is emitted by the EXIT trap)
