#!/usr/bin/env bash
#
# A script to manage Let's Encrypt certificates for public DNS zones in a specified Azure resource group using the lego ACME client.
#
# Prerequisites:
#   - Azure CLI installed and user logged in with access to the specified subscription and resource group
#   - jq installed for JSON processing
#   - openssl installed for handling PFX certificates
#   - dig (from bind-utils or dnsutils) installed for DNS queries
#   - lego ACME client installed (https://go-acme.github.io/lego/)
#
# Environment variables to configure the script:
#   Required:
#     - AZ_TENANT_ID:                         Azure Tenant ID
#     - AZ_SUBSCRIPTION_ID:                   Azure Subscription ID
#     - AZ_DNS_RG_NAME:                       Name of the Azure resource group containing the DNS zones
#     - AZ_CERT_KV_NAME:                      Name of the Azure KeyVault to store certificates and Let's Encrypt account details
#     - LE_NEW_ACCOUNT_EMAIL:                 Email to use for new Let's Encrypt account registration
#     - CERT_AZ_RESOURCE_TAG_ApplicationName: Tag value for ApplicationName to apply to certificate secrets in KeyVault
#     - CERT_AZ_RESOURCE_TAG_CreatedBy:       Tag value for CreatedBy to apply to certificate secrets in KeyVault
#     - CERT_AZ_RESOURCE_TAG_Description:     Tag value for Description to apply to certificate secrets in KeyVault
#   Optional:
#     - LE_ENVIRONMENT_NAME:  Let's Encrypt environment to use, either "staging" or "production" (default: "staging")
#     - CERT_FORCE_ALL_NEW:   If set to "true", forces new certificates for all DNS zones (default: "false")
#     - CERT_FORCE_RENEWAL:   If set to "true", forces renewal of existing certificates (default: "false")
#   Test seams (NOT supported for production use — defaults are production behaviour; see docs/contracts.md):
#     - CW_ACME_DIRECTORY_URL:  Override the ACME directory URL (default: derived from LE_ENVIRONMENT_NAME)
#     - CW_LEGO_DNS_PROVIDER:   lego DNS-01 provider (default: "azuredns"; tests use "exec")
#     - CW_LEGO_DNS_RESOLVERS:  Space-separated host:port resolvers for lego's propagation checks
#     - CW_LEGO_EXTRA_ARGS:     Extra args appended to every `lego run` (e.g. propagation flags)
#     - CW_DIG_ARGS:            Extra dig args for the public-delegation NS check, appended after
#                               the query (default: "@1.1.1.1"); tests use "@127.0.0.1 -p 5354"
#
# The script will:
#   - Read all public DNS zones in the specified resource group
#   - For each zone, check if it is publicly delegated by comparing configured NS records with public NS records
#   - For each publicly delegated zone, check if a certificate already exists in the specified KeyVault
#   - If a certificate exists, check if it matches the zone name and A records
#     - If it matches, evaluate if it needs renewal based on expiry and configured settings
#     - If it does not match, request a new certificate
#   - If no certificate exists, request a new certificate
#   - Store the new or renewed certificate in the specified KeyVault
#   - If Let's Encrypt account details do not exist in KeyVault, create a new account and store details in KeyVault
#   - Clean up local files used during the process
#
#
set -euo pipefail
# Command substitution inherits errexit (bash >= 4.4) — closes the class of bug where a
# failing $( ) is silently swallowed. See docs/testing.md (pitfalls P-2).
shopt -s inherit_errexit

# Self-sufficient helpers load: the composite action shim sources lib/helpers.bash (allexport)
# before running this script; standalone runs (tests, scripts/run-local.sh) load it here.
if ! declare -F log-info >/dev/null 2>&1; then
  # shellcheck source=../../lib/helpers.bash
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../../lib/helpers.bash"
fi

start-group "Load"

# =====================================================================================================================
#region Configuration
# =====================================================================================================================

# All configuration is read from the environment inside loadConfig(), NOT at source time, so
# tests can `source` this file without exporting a full production env. Direct execution calls
# loadConfig before main (see the source-guard at the bottom).
function loadConfig() {

  # feature flags
  # ------------------------------------------------------------

  # a forced renewal of all certificates for all DNS zones will be triggered if set to true
  forceNew=${CERT_FORCE_ALL_NEW:-false}

  # if a certificate already exists for a given DNS zone, a forced renewal of the certificate will be triggered if set to true
  #   note: if forceNew=true, this setting is ignored
  forceRenewal=${CERT_FORCE_RENEWAL:-false}

  # azure resource references
  # ------------------------------------------------------------

  tenantId=${AZ_TENANT_ID}
  subId=${AZ_SUBSCRIPTION_ID}
  rgName=${AZ_DNS_RG_NAME}
  certKvName=${AZ_CERT_KV_NAME}

  # Let's Encrypt config
  # ------------------------------------------------------------

  # note:
  #   this is only used when creating a new account with Let's Encrypt
  #   if account details already exist in KeyVault, those will be used
  emailToUseForNewAccountRegistrationWithLetsencrypt=${LE_NEW_ACCOUNT_EMAIL}

  letsencryptEnvironment=${LE_ENVIRONMENT_NAME:-staging}

  letsencryptStagingServer="acme-staging-v02.api.letsencrypt.org"
  letsencryptProdServer="acme-v02.api.letsencrypt.org"

  if [ "${letsencryptEnvironment}" == "production" ]; then
    letsencryptServer="${letsencryptProdServer}"
  else
    letsencryptServer="${letsencryptStagingServer}"
  fi

  # Test seams (see the header + docs/contracts.md): every default is production behaviour.
  acmeDirectoryUrl="${CW_ACME_DIRECTORY_URL:-https://${letsencryptServer}/directory}"
  # lego stores account material under accounts/<host>[_<port>], derived from the directory
  # URL it was given — derive the same path so the account-key sanity checks and the
  # CW_ACME_DIRECTORY_URL seam agree with lego's on-disk layout (port 443/none => bare host).
  acmeAccountsServerDir="${acmeDirectoryUrl#*://}"
  acmeAccountsServerDir="${acmeAccountsServerDir%%/*}"
  acmeAccountsServerDir="${acmeAccountsServerDir%:443}"
  acmeAccountsServerDir="${acmeAccountsServerDir/:/_}"
  legoDnsProvider="${CW_LEGO_DNS_PROVIDER:-azuredns}"
  legoDnsResolvers="${CW_LEGO_DNS_RESOLVERS:-1.1.1.1:53 8.8.8.8:53 9.9.9.9:53}"
  legoExtraRunArgs="${CW_LEGO_EXTRA_ARGS:-}"
  # Word-splitting is intended for digArgs (server + options), hence unquoted at the call site.
  digArgs="${CW_DIG_ARGS:-@1.1.1.1}"

  # where to look for/store Let's Encrypt account details in KeyVault
  letsencryptAccountEmailSecretName="letsencrypt-${letsencryptEnvironment}-account-email"
  letsencryptAccountKeySecretName="letsencrypt-${letsencryptEnvironment}-account-key"
  letsencryptAccountJsonSecretName="letsencrypt-${letsencryptEnvironment}-account-json"

  # certificate configuration common for all certificates
  # ------------------------------------------------------------

  # NOTE: renewal timing is governed by ARI (RFC 9773 renewalInfo), which lego v5 enables by
  # default: lego queries Let's Encrypt's renewalInfo endpoint each run and renews within the
  # CA-suggested window (which LE can move earlier, e.g. for mass revocation). If ARI is ever
  # unreachable, lego falls back to its fixed `--renew-days` threshold (default 30). lego v5.2.2 has
  # no dynamic / fraction-of-lifetime renewal option, so we rely on ARI + that default; revisit
  # `--renew-days` (or adopt a dynamic threshold once a lego release ships one) if Let's Encrypt
  # shortens certificate lifetimes enough that a 30-day fallback would never trigger.
  # See renewExistingCertificate.

  # Azure resource tags for certificate resources in KeyVault
  kvCertSecretTags=(
    "ApplicationName=${CERT_AZ_RESOURCE_TAG_ApplicationName}"
    "CreatedBy=${CERT_AZ_RESOURCE_TAG_CreatedBy}"
    "Description=${CERT_AZ_RESOURCE_TAG_Description}"
    "IssuedBy=${letsencryptServer}"
  )

}

#endregion Configuration

# =====================================================================================================================
#region Error Tracking
# =====================================================================================================================

# Global error counter to track errors for individual certificate actions during execution
certificateActionErrorCount=0

# Log an error message and increment the error counter
# Arguments:
#   1: Error message to log
# Returns:
#   None
function logCertificateActionError() {
  local _message="${1}"
  log-error "${_message}"
  # Assignment form, NOT ((certificateActionErrorCount++)): under `set -e` an arithmetic
  # command whose result is 0 returns exit status 1, so the post-increment aborts the whole
  # script on the FIRST error (when the counter is still 0) -- before the end-of-run metrics
  # artifact and step summary are written. That silent abort is why a run with a single failed
  # cert produced no metrics at all. The assignment always returns 0, so the loop continues,
  # records the failed zone, and still emits metrics. See .github/cert-warden/selftest.sh.
  certificateActionErrorCount=$((certificateActionErrorCount + 1))
}

#endregion Error Tracking

# =====================================================================================================================
#region Functions
# =====================================================================================================================

# Check if a secret exists in a KeyVault
# Arguments:
#   1: KeyVault name
#   2: Secret name
# Returns:
#   0: true (secret exists)
#   1: false (secret does not exist)
function secretExistsInKeyVault() {
  local _kvName="$1"
  local _secretName="$2"

  if az keyvault secret show --name "${_secretName}" --vault-name "${_kvName}" &>/dev/null; then
    return 0 # true
  else
    return 1 # false
  fi
}

# Check if Let's Encrypt account details exist in KeyVault
# Arguments:
#   None, uses global variables:
#     certKvName
#     letsencryptAccountEmailSecretName
#     letsencryptAccountKeySecretName
#     letsencryptAccountJsonSecretName
# Returns:
#   0: true (both email and key exist)
#   1: false (one or both do not exist)
function letsencryptAccountExistsInKeyVault() {
  if secretExistsInKeyVault "${certKvName}" "${letsencryptAccountEmailSecretName}" &&
    secretExistsInKeyVault "${certKvName}" "${letsencryptAccountKeySecretName}" &&
    secretExistsInKeyVault "${certKvName}" "${letsencryptAccountJsonSecretName}"; then
    return 0 # true
  else
    return 1 # false
  fi
}

# Check if a DNS zone is publicly delegated by comparing configured NS records with public NS records
# Arguments:
#   1: DNS zone name
#   2: JSON array of configured name servers for the zone
# Returns:
#   0: true (zone is publicly delegated)
#   1: false (zone is not publicly delegated)
function dns_zone_is_publicly_delegated() {
  local _zoneName="$1"
  local _zoneNsJson="$2"

  log-info "  Checking if zone ${_zoneName} is publicly delegated"

  # Get configured name servers as array
  mapfile -t _configuredNs < <(echo "${_zoneNsJson}" | jq -r '.[]')

  # Get public name servers. A FAILED lookup (timeout/no server, dig exits non-zero) must be
  # distinguished from an empty answer ("really not delegated"): return 2 so the caller records
  # a failure instead of silently skipping the zone. (A SERVFAIL from the resolver still yields
  # exit 0 + empty output and is indistinguishable from non-delegation — accepted gap.)
  local _digOut
  # shellcheck disable=SC2086 # digArgs word-splitting is intended (resolver + options)
  if ! _digOut="$(dig +short +timeout=5 NS "${_zoneName}" ${digArgs})"; then
    log-info "  ERROR: public NS lookup failed for ${_zoneName} (dig error/timeout)"
    return 2
  fi
  mapfile -t _publicNs <<<"${_digOut}"

  # Check if all configured name servers are present in public name servers
  local _ns _pns _found
  for _ns in "${_configuredNs[@]}"; do
    _found=false
    for _pns in "${_publicNs[@]}"; do
      if [[ "${_ns}" == "${_pns}" ]]; then
        _found=true
        break
      fi
    done
    if ! ${_found}; then
      return 1 # false
    fi
  done
  return 0 # true
}

# Install a certificate for a DNS zone from a PFX certificate stored in KeyVault
# Arguments:
#   1: KeyVault name
#   2: KeyVault secret name (PFX)
#   3: Path to store certificate file (PEM)
#   4: Path to store certificate private key file (PEM)
#   5: Path to store certificate issuer file (PEM)
#   6: Password to use for the private key file
# Returns:
#   0: success
#   1: failure
function installZoneCertFromKeyVault() {
  local _kvName="$1"
  local _pfxSecretName="$2"
  local _certPath="$3"
  local _certKeyPath="$4"
  local _certIssuerPath="$5"
  local _pfxCertPassword="$6"

  local _pfxTempFile

  _pfxTempFile="$(mktemp)"

  if ! az keyvault secret show --name "${_pfxSecretName}" --vault-name "${_kvName}" --query value -o tsv | base64 --decode >"${_pfxTempFile}"; then
    return 1 # false
  fi

  # use openssl to extract, blank password when coming from KeyVault
  #   cert.crt is the server certificate (including the CA certificate),
  #   cert.key is the private key needed for the server certificate,
  #   cert.issuer.crt is the CA certificate
  if ! openssl pkcs12 -in "${_pfxTempFile}" -clcerts -nokeys -out "${_certPath}" -passin pass:; then
    rm -f "${_pfxTempFile}" || :
    return 1 # false
  fi
  if ! openssl pkcs12 -in "${_pfxTempFile}" -nocerts -out "${_certKeyPath}" -passin pass: -passout pass:"${_pfxCertPassword}"; then
    rm -f "${_certPath}" || :
    rm -f "${_pfxTempFile}" || :
    return 1 # false
  fi
  if ! openssl pkcs12 -in "${_pfxTempFile}" -cacerts -nokeys -out "${_certIssuerPath}" -passin pass:; then
    rm -f "${_certPath}" || :
    rm -f "${_certKeyPath}" || :
    rm -f "${_pfxTempFile}" || :
    return 1 # false
  fi

  # append issuer to cert, as lego does
  cat "${_certIssuerPath}" >>"${_certPath}"

  # clean up
  rm -f "${_pfxTempFile}" || :

  return 0 # true
}

# Persist lego's per-certificate metadata (.json) to Key Vault.
#
# This is what makes ARI-based renewal possible. Key Vault stores the certificate (PFX) but
# not lego's CertificateResource metadata (the ACME certUrl etc.). Without that .json, `lego
# run` does not recognise the cert on a later run and re-issues every time. We therefore store
# the .json as a per-cert Key Vault SECRET so it can be restored before the next run. It is
# rewritten on every issue/renew because the certUrl changes each time. Scoped per LE-env via
# the secret name (it embeds ${letsencryptEnvironment} through certKvPfxSecretName).
# Arguments:
#   1: lego metadata file path (e.g. ${legoCertificatesPath}/${zoneName}.json)
#   2: Key Vault secret name for the metadata
# Returns: 0 success, 1 failure
function storeLegoMetadataInKeyVault() {
  local _metaPath="$1" _metaSecretName="$2"
  if [ ! -f "${_metaPath}" ]; then
    log-info "  WARNING: lego metadata file not found, cannot persist for ARI: ${_metaPath}"
    return 1
  fi
  local _id
  if _id=$(az keyvault secret set --name "${_metaSecretName}" --vault-name "${certKvName}" --value "$(jq -c . "${_metaPath}")" --query id -o tsv); then
    log-info "    Stored lego metadata (for ARI) in KeyVault secret: ${_id}"
    return 0
  fi
  log-info "  WARNING: failed to store lego metadata in KeyVault secret: ${_metaSecretName}"
  return 1
}

# Restore lego's per-certificate metadata (.json) from Key Vault into the lego store, so that
# `lego run` recognises the existing certificate and lets ARI decide whether to renew.
# Missing secret is NOT an error: a cert issued before metadata persistence existed (or any
# first run) simply has no metadata yet; lego then treats it as a new issuance and we persist
# the metadata afterwards.
# Arguments:
#   1: Key Vault secret name for the metadata
#   2: lego metadata file path to write (e.g. ${legoCertificatesPath}/${zoneName}.json)
# Returns: 0 if restored, 1 if not present (caller continues regardless)
function restoreLegoMetadataFromKeyVault() {
  local _metaSecretName="$1" _metaPath="$2" _val
  if _val=$(az keyvault secret show --name "${_metaSecretName}" --vault-name "${certKvName}" --query value -o tsv 2>/dev/null) && [ -n "${_val}" ]; then
    echo "${_val}" >"${_metaPath}"
    log-info "  Restored lego metadata (for ARI) from KeyVault secret: ${_metaSecretName}"
    return 0
  fi
  log-info "  No lego metadata in KeyVault yet for ${_metaSecretName}; lego will treat this as a new issuance"
  return 1
}

# Append one per-certificate metric record (JSON) to the run's metrics accumulator.
# Cert Warden emits these so monitoring can be built on the certs it manages (managed certs
# only -- orphans/let-expire objects are never recorded, so they generate no alert noise).
# Schema is documented in docs/cert-warden-migration/ (Phase 3 §3.4). All extraction is
# best-effort: a missing/invalid cert file yields null detail fields but still records the
# zone, action and error.
# Arguments:
#   1: action  (issued|renewed|forced|skipped|failed|not_delegated)
#   2: certificate file (PEM) to read details from, or "-" for none
#   3: error message ("" if none)
# Uses globals: zoneName, certKvPfxSecretName, letsencryptEnvironment, metricsFile
function recordCertMetric() {
  local _action="$1" _certFile="$2" _err="${3:-}"
  local _nb="" _na="" _serial="" _issuer="" _keytype="" _sans="[]" _dte="null" _frac="null"
  if [ "${_certFile}" != "-" ] && [ -f "${_certFile}" ] && openssl x509 -in "${_certFile}" -noout &>/dev/null; then
    _nb=$(openssl x509 -in "${_certFile}" -noout -startdate 2>/dev/null | sed 's/notBefore=//')
    _na=$(openssl x509 -in "${_certFile}" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    _serial=$(openssl x509 -in "${_certFile}" -noout -serial 2>/dev/null | sed 's/serial=//')
    _issuer=$(openssl x509 -in "${_certFile}" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')
    # `|| true`: best-effort extraction — grep exits 1 on no match (RSA certs have no ASN1
    # OID line; a cert may lack SANs) and pipefail would otherwise abort the run before the
    # metrics/summary are written (pitfall P-7, same incident class as P-1).
    _keytype=$(openssl x509 -in "${_certFile}" -noout -text 2>/dev/null | grep -oiE "ASN1 OID: [a-zA-Z0-9-]+" | head -1 | sed 's/ASN1 OID: //' || true)
    _sans=$(openssl x509 -in "${_certFile}" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | sed 's/DNS://; s/ //g' | jq -R . | jq -s -c . 2>/dev/null || true)
    [ -z "${_sans}" ] && _sans="[]"
    local _naEpoch _nbEpoch _now
    _naEpoch=$(date -d "${_na}" +%s 2>/dev/null || echo "")
    _nbEpoch=$(date -d "${_nb}" +%s 2>/dev/null || echo "")
    _now=$(date +%s)
    [ -n "${_naEpoch}" ] && _dte=$(((_naEpoch - _now) / 86400))
    if [ -n "${_naEpoch}" ] && [ -n "${_nbEpoch}" ] && [ "${_naEpoch}" -gt "${_nbEpoch}" ]; then
      _frac=$(awk "BEGIN{printf \"%.4f\", (${_naEpoch}-${_now})/(${_naEpoch}-${_nbEpoch})}")
    fi
  fi
  jq -n -c \
    --arg zone "${zoneName}" --arg kv "${certKvPfxSecretName:-}" --arg leenv "${letsencryptEnvironment}" \
    --arg action "${_action}" --arg nb "${_nb}" --arg na "${_na}" --arg serial "${_serial}" \
    --arg issuer "${_issuer}" --arg keytype "${_keytype}" --argjson san "${_sans}" \
    --argjson dte "${_dte}" --arg frac "${_frac}" --arg err "${_err}" \
    '{zone:$zone, kv_cert_name:$kv, le_env:$leenv, action:$action, not_before:$nb, not_after:$na, days_to_expiry:$dte, lifetime_fraction_remaining:(if $frac=="null" then null else ($frac|tonumber) end), serial:$serial, issuer:$issuer, key_type:$keytype, san:$san, error:$err}' \
    >>"${metricsFile}"
}

# Get common lego "run" options as a string.
#
# lego v5 note: `run` and `renew` were unified into a single `lego run` command, and what
# were global options in v4 are now command-level options placed AFTER `run`. This function
# returns those options; callers prefix them with `lego run`.
#
# Arguments:
#   None, uses global variables:
#     legoDirPath
#     letsencryptServer
#     accountEmail
#     zoneName
#     certSanAdditionalDomains (array)
# Returns:
#   String with common lego run options
function getCommonLegoRunOptions() {
  local _args _domain
  _args=" "
  _args+="--path ${legoDirPath} "                     # Directory to use for storing the data ($LEGO_PATH).
  _args+="--server ${acmeDirectoryUrl} "              # ACME server directory URL (CW_ACME_DIRECTORY_URL test seam).
  _args+="--email ${accountEmail} "                   # Email used for registration and recovery contact.
  _args+="--domains ${zoneName} "                     # Primary domain (apex). Repeat --domains for SANs.
  for _domain in "${certSanAdditionalDomains[@]}"; do # additional SAN domains (e.g. *.<zone>)
    _args+="--domains ${_domain} "
  done
  _args+="--accept-tos " # Accept the current CA terms of service.
  _args+="--ipv4only "   # Force IPv4 for all DNS queries: runner firewall egress is IPv4-scoped and IPv6 to the Azure DNS authoritative servers is unreliable, which otherwise stalls lego's propagation check.
  local _resolver
  for _resolver in ${legoDnsResolvers}; do # Recursive resolvers for (CNAME/apex) resolution + propagation checks. Syntax host:port.
    _args+="--dns.resolvers ${_resolver} "
  done
  _args+="--dns ${legoDnsProvider} " # Solve the DNS-01 challenge via this provider (azuredns in production).
  _args+="--key-type EC384 "         # ECDSA P-384. v5 expects upper-case key types (EC256, EC384, RSA2048, ...). Default is EC256.
  _args+="--pfx "                    # Also generate a .pfx (PKCS#12); the password is taken from $LEGO_PFX_PASSWORD.
  _args+="${legoExtraRunArgs} "      # CW_LEGO_EXTRA_ARGS test seam (empty in production).
  echo "${_args}"
}

function getCommonLegoCommandOptions() {
  local _args

  _args=" "

  # acme: error: 400 :: POST :: https://acme-staging-v02.api.letsencrypt.org/acme/new-order
  #   :: urn:ietf:params:acme:error:malformed :: NotBefore and NotAfter are not supported
  # local _7DaysFromNowRfc3339Format
  # if [ "${letsencryptEnvironment}" == "staging" ]; then
  #   # in staging we issue short lived certs
  #   _7DaysFromNowRfc3339Format=$(date -u -d "7 days" +"%Y-%m-%dT%H:%M:%SZ")
  #   _args+="--not-after ${_7DaysFromNowRfc3339Format} "
  # fi

  echo "${_args}"
}

# Request a new certificate using the lego client
# Arguments:
#   None, uses global variables:
#     tenantId
#     subId
#     rgName
#     zoneName
#     pfxCertPassword
#     legoDirPath
#     letsencryptServer
#     accountEmail
#     certSanAdditionalDomains (array)
# Returns:
#   0: success
#   1: failure
function requestNewCertificate() {
  # lego v5: single `lego run` command; all options (incl. all --domains, set in
  # getCommonLegoRunOptions) are placed after `run`. With an empty --path store, `run`
  # obtains a fresh certificate.
  local _legoCommandLine
  _legoCommandLine="lego \
    run \
    $(getCommonLegoRunOptions) \
    $(getCommonLegoCommandOptions)"

  log-info "  Requesting new certificate using lego command:"
  log-info "    ${_legoCommandLine}"

  # lego defaults:
  #   AZURE_PROPAGATION_TIMEOUT=120
  #   AZURE_POLLING_INTERVAL=2
  if AZURE_AUTH_METHOD="cli" \
    AZURE_TENANT_ID="${tenantId}" \
    AZURE_SUBSCRIPTION_ID="${subId}" \
    AZURE_RESOURCE_GROUP="${rgName}" \
    AZURE_ZONE_NAME="${zoneName}" \
    AZURE_PROPAGATION_TIMEOUT="300" \
    AZURE_POLLING_INTERVAL="15" \
    LEGO_PFX_PASSWORD="${pfxCertPassword}" \
    ${_legoCommandLine}; then
    return 0
  else
    return 1
  fi
}

# Renew an existing certificate using the lego client
# Arguments:
#   None, uses global variables:
#     tenantId
#     subId
#     rgName
#     zoneName
#     pfxCertPassword
#     legoDirPath
#     letsencryptServer
#     accountEmail
# Returns:
#   0: success
#   1: failure
function renewExistingCertificate() {
  # ARI-native renewal (set-and-forget). The existing cert (.crt/.key/.issuer.crt) and lego's
  # metadata (.json) have been reconstructed from Key Vault before this is called, so `lego run`
  # recognises the cert and lets **ARI** (RFC 9773 renewalInfo) decide whether to renew: lego
  # fetches Let's Encrypt's suggested renewal window and renews within it (LE can pull the window
  # earlier, e.g. for mass revocation). When not due, lego writes no new files and the caller's
  # "no new PFX -> renewal not needed" path leaves the Key Vault cert untouched.
  #
  # ARI is authoritative here and enabled by default; if it is ever unreachable lego falls back to
  # its fixed `--renew-days` threshold (default 30). ARI also spreads renewals to avoid a
  # fleet-wide thundering herd, and ARI-coordinated renewals are exempt from LE rate limits.
  #
  #   --force-cert-domains : re-issue if the cert's domain set drifts from --domains (e.g. an A
  #                          record was added/removed), instead of renewing the stale SAN set.
  #   --renew-force        : only when an operator forces it (CERT_FORCE_RENEWAL); bypasses ARI.
  # NB: lego v5.2.2 has no `--dynamic` (fraction-of-lifetime) flag — the only renewal knobs on
  # `lego run` are ARI (default) and `--renew-days`. Do not add `--dynamic`; lego rejects it
  # (verified against v5.2.2 AND master, 2026-06 — no such flag, no upstream issue/PR for one).
  #
  # TODO(cert-warden): the ARI-unavailable fallback is lego's fixed `--renew-days` (default 30).
  #   That is correct for today's 90-day certs but would be wrong once LE issues short-lived certs
  #   (a 6-day cert is always "<30 days left"). If/when LE shortens the certificate lifetime for
  #   these zones, set `--renew-days` explicitly to roughly 1/3 of the issued lifetime so the
  #   fallback stays proportionate. ARI stays primary regardless; `--renew-days` only governs the
  #   rare case where the renewalInfo endpoint is unreachable. (If a future lego release adds a
  #   proportional / "dynamic" renewal window, prefer it over hand-tuning `--renew-days`.)
  local _renewControl="--force-cert-domains "
  if [ "${forceRenewal}" = true ]; then
    _renewControl+="--renew-force "
  fi

  local _legoCommandLine
  _legoCommandLine="lego \
    run \
    $(getCommonLegoRunOptions) \
    $(getCommonLegoCommandOptions) \
    ${_renewControl}"

  log-info "  Renew lego command:"
  log-info "    ${_legoCommandLine}"

  # lego defaults:
  #   AZURE_PROPAGATION_TIMEOUT=120
  #   AZURE_POLLING_INTERVAL=2
  # shellcheck disable=SC2046,SC2086
  if AZURE_AUTH_METHOD="cli" \
    AZURE_TENANT_ID="${tenantId}" \
    AZURE_SUBSCRIPTION_ID="${subId}" \
    AZURE_RESOURCE_GROUP="${rgName}" \
    AZURE_ZONE_NAME="${zoneName}" \
    AZURE_PROPAGATION_TIMEOUT="300" \
    AZURE_POLLING_INTERVAL="15" \
    LEGO_PFX_PASSWORD="${pfxCertPassword}" \
    ${_legoCommandLine}; then
    return 0
  else
    return 1
  fi
}

# Resolve additional domains for certificate SAN from A records in the DNS zone
# Arguments:
#   None, uses global variables:
#     rgName
#     zoneName
#     certSanAdditionalDomains (array, output)
#     certSanAdditionalDomainsJsonArray (json array, output)
# Returns:
#   None, modifies global variables:
#     certSanAdditionalDomains (array, output)
#     certSanAdditionalDomainsJsonArray (json array, output)
function resolveCertSanAdditionalDomains() {

  log-info "  Resolving additional domains for certificate SAN field from A records in zone: ${zoneName}"

  # The az call is if-tested at the call site, which disables errexit inside this function
  # (pitfall P-4) — so its failure MUST be tested explicitly here: an empty/failed listing
  # would otherwise fall through as "no A records" and issue a WRONG apex-only certificate.
  local _zoneJson
  if ! _zoneJson="$(az network dns record-set list \
    --zone-name "${zoneName}" \
    --resource-group "${rgName}" \
    -o json)" || [ -z "${_zoneJson}" ]; then
    log-info "  ERROR: failed to list record sets for zone ${zoneName} (az error or empty response)"
    return 1
  fi

  local _zoneARecords _zoneARecordsCount
  # we exclude the apex record "@" as that is already included as primary domain
  _zoneARecords=$(echo "${_zoneJson}" | jq '[.[] | select(.type == "Microsoft.Network/dnszones/A" and .name != "@")]')
  _zoneARecordsCount=$(echo "${_zoneARecords}" | jq 'length')

  # reset global arrays
  certSanAdditionalDomains=()
  certSanAdditionalDomainsJsonArray="[]"

  if [ "${_zoneARecordsCount}" -eq 0 ]; then
    log-info "  No A records found in zone, certificate SAN will include wildcard domain *.${zoneName}"
    certSanAdditionalDomains+=("*.${zoneName}")
    certSanAdditionalDomainsJsonArray=$(echo "${certSanAdditionalDomainsJsonArray}" | jq -n --arg domain "*.${zoneName}" '[$domain]')
  else
    log-info "  Number of A records found: ${_zoneARecordsCount}"
    log-info "  Certificate will include the following in the SAN field:"
    local _aRecordName
    for _aRecordName in $(echo "${_zoneARecords}" | jq -r '.[].name'); do
      log-info "   - ${_aRecordName}.${zoneName}"
      certSanAdditionalDomains+=("${_aRecordName}.${zoneName}")
      certSanAdditionalDomainsJsonArray=$(echo "${certSanAdditionalDomainsJsonArray}" | jq --arg domain "${_aRecordName}.${zoneName}" '. + [$domain]')
    done
  fi
}

#endregion Functions

end-group # Load

# =====================================================================================================================
#region Main
# =====================================================================================================================

# The cert-maintenance flow. Configuration comes from loadConfig(); tests `source` this file
# (which defines config-as-function, error tracking and the functions above WITHOUT running
# anything) and exercise the real functions directly — see the source-guard at the bottom.
function main() {

  start-group "Init"
  log-info "  check if lego ACME client is installed"
  lego --version

  log-info "  Set Azure Subscription to ${subId}"
  az account set --subscription "${subId}"

  # local dir structure for lego
  #   ref. https://github.com/go-acme/lego/blob/master/cmd/accounts_storage.go
  log-info "  Creating local directory structure for lego client"
  legoDirPath="$(mktemp -d)"
  legoCertificatesPath="${legoDirPath}/certificates"
  legoAccountsPath="${legoDirPath}/accounts"
  log-info "    Certificates path: ${legoCertificatesPath}"
  log-info "    Accounts path: ${legoAccountsPath}"

  # Per-cert metrics accumulator (one JSON record per zone, appended via recordCertMetric).
  # Assembled into a JSON array + GitHub step summary at the end of the run.
  metricsFile="$(mktemp)"
  : >"${metricsFile}"

  if ! letsencryptAccountExistsInKeyVault; then
    log-info "  Let's Encrypt account details not found in KeyVault: ${certKvName}"
    log-info "  A new account will be created using email for new registration: ${emailToUseForNewAccountRegistrationWithLetsencrypt}"
    accountEmail="${emailToUseForNewAccountRegistrationWithLetsencrypt}"
    accountKey=
    accountJson=
    creatingLetsEncryptAccount=true
  else
    log-info "  Reading Let's Encrypt account details from KeyVault: ${certKvName}"
    accountEmail=$(az keyvault secret show --name "${letsencryptAccountEmailSecretName}" --vault-name "${certKvName}" --query value -o tsv)
    accountKey=$(az keyvault secret show --name "${letsencryptAccountKeySecretName}" --vault-name "${certKvName}" --query value -o tsv)
    accountJson=$(az keyvault secret show --name "${letsencryptAccountJsonSecretName}" --vault-name "${certKvName}" --query value -o tsv)
    creatingLetsEncryptAccount=false
  fi

  # where to store account key on disk, depends on email and server
  # lego v5 stores the account key directly under the email dir (v4 had a 'keys/' subdir).
  accountKeyPath="${legoAccountsPath}/${acmeAccountsServerDir}/${accountEmail}/${accountEmail}.key"
  accountJsonPath="${legoAccountsPath}/${acmeAccountsServerDir}/${accountEmail}/account.json"
  mkdir -p "$(dirname "${accountKeyPath}")"

  # if we have credentials from KeyVault, store them in local file
  if [ -n "${accountKey}" ] && [ -n "${accountJson}" ]; then
    log-info "  Storing account JSON in local file: ${accountJsonPath}"

    # use jq to pretty print and valdate the JSON
    accountJsonPretty=$(echo "${accountJson}" | jq '.')
    echo "${accountJsonPretty}" >"${accountJsonPath}"
    chmod 644 "${accountJsonPath}"

    log-info "  Storing account key in local file: ${accountKeyPath}"
    echo "${accountKey}" >"${accountKeyPath}"
    chmod 644 "${accountKeyPath}"
  fi

  # TODO: implement debug log flag
  # The environment variable LEGO_DEBUG_CLIENT_VERBOSE_ERROR allows to enrich error messages from some of the DNS clients.
  # LEGO_DEBUG_CLIENT_VERBOSE_ERROR=true
  # The environment variable LEGO_DEBUG_ACME_HTTP_CLIENT allows debug the calls to the ACME server.
  # LEGO_DEBUG_ACME_HTTP_CLIENT=true

  end-group # Init

  start-group "Enumerate"
  log-info "Reading public DNS zones in resource group: ${rgName}"
  publicZonesJson="$(az network dns zone list --resource-group "${rgName}" --output json)"
  publicZonesCount=$(echo "${publicZonesJson}" | jq 'length')
  log-info "Number of public DNS zones found: ${publicZonesCount}"

  end-group # Enumerate

  for zoneName in $(echo "${publicZonesJson}" | jq -r '.[].name'); do
    start-group "Zone: ${zoneName}"
    log-info "Determining certificate operations for DNS zone: ${zoneName}"

    # Extract configured name servers for this zone
    zoneNsJson=$(echo "${publicZonesJson}" | jq -r ".[] | select(.name == \"${zoneName}\") | .nameServers")

    certKvPfxSecretName="" # reset per zone; set below for delegated zones (avoids stale carry-over in metrics)
    delegationRc=0
    dns_zone_is_publicly_delegated "${zoneName}" "${zoneNsJson}" || delegationRc=$?
    if [ "${delegationRc}" -eq 2 ]; then
      logCertificateActionError "public NS lookup failed for ${zoneName}; cannot determine delegation"
      recordCertMetric "failed" "-" "public NS lookup failed (dig error/timeout)"
      continue # to next zone
    elif [ "${delegationRc}" -ne 0 ]; then
      log-info "  Zone not publicly delegated or NS mismatch, ignoring zone"
      recordCertMetric "not_delegated" "-" ""
      continue # to next zone
    else
      log-info "  Zone is publicly delegated, proceeding"

      # random pfx password, used when storing locally, in key vault there is no password
      log-info "  Generating random temporary password for PFX certificate"
      pfxCertPassword="$(openssl rand -base64 48)"

      # a place to store certs
      log-info "  Creating local directory for lego certificates: ${legoCertificatesPath}"
      rm -rf "${legoCertificatesPath}" || :
      mkdir -p "${legoCertificatesPath}"

      # get A records in zone, used to determine additional SANs for the certificate
      declare -a certSanAdditionalDomains
      if ! resolveCertSanAdditionalDomains; then
        logCertificateActionError "Failed to resolve additional domains for certificate SAN"
        recordCertMetric "failed" "-" "failed to resolve SAN additional domains from DNS zone"
        continue
      fi

      # lego will create these files:
      #   ops.dsb.no.crt
      #   ops.dsb.no.issuer.crt
      #   ops.dsb.no.json
      #   ops.dsb.no.key
      #   ops.dsb.no.pfx (if --pfx is used)
      certPath="${legoCertificatesPath}/${zoneName}.crt"
      certIssuerPath="${legoCertificatesPath}/${zoneName}.issuer.crt"
      certKeyPath="${legoCertificatesPath}/${zoneName}.key"
      pfxCertPath="${legoCertificatesPath}/${zoneName}.pfx"
      # lego's per-cert metadata (CertificateResource: certUrl etc.) -- needed for ARI renewal.
      legoCertMetaPath="${legoCertificatesPath}/${zoneName}.json"

      # letsencrypt-certificate-<environment>-<zone>-pfx
      certKvPfxSecretName="le-cert-${letsencryptEnvironment}-${zoneName//./-}-pfx"
      # Key Vault secret holding lego's metadata for this cert (per LE-env, via the name above).
      certKvMetaSecretName="${certKvPfxSecretName}-meta"

      # check if cert already exists in KeyVault
      if secretExistsInKeyVault "${certKvName}" "${certKvPfxSecretName}"; then
        log-info "  Certificate for this zone already exists in KeyVault: ${certKvName}, secret name: ${certKvPfxSecretName}"

        if [ "${forceNew}" = true ]; then
          log-info "  Ignoring existing certificate as 'forceNew' is set to '${forceNew}'"
          renewing=false
        else
          # key vault has the SAN values as well as the domain/subject for the existing certificate
          existingCertMetaJson=$(az keyvault certificate show --vault-name "${certKvName}" --name "${certKvPfxSecretName}" --query policy.x509CertificateProperties -o json)

          # all domains in certificates SAN as json array
          existingCertSanValuesJsonArrayArray=$(echo "${existingCertMetaJson}" | jq -r .subjectAlternativeNames.dnsNames)

          # letsencrypt includes the base domain in SAN field, remove it before comparing
          existingCertSanValuesWithoutZone=$(echo "${existingCertSanValuesJsonArrayArray}" | jq --arg domain "${zoneName}" 'map(select(. != $domain))')

          # Does the existing cert cover the zone apex? We check SAN membership rather than the
          # certificate's CN. lego/Let's Encrypt may set the CN to the wildcard SAN (e.g.
          # CN=*.zone), so a CN==zone check yields false negatives and would re-issue a new cert
          # on every run (and risk the duplicate-certificate rate limit). The apex is always
          # present in the SAN for a correctly-issued cert.
          if ! echo "${existingCertSanValuesJsonArrayArray}" | jq -e --arg z "${zoneName}" 'index($z) != null' &>/dev/null; then
            # the apex zone is not in the existing cert's SAN -> request a new certificate
            log-warn "Existing certificate does not cover the DNS zone apex in its SAN"
            log-warn "  SAN is '$(echo "${existingCertSanValuesJsonArrayArray}" | jq -c .)' vs. DNS zone name '${zoneName}'"
            log-warn "  a new certificate will be requested"
            renewing=false
          elif ! diff <(echo "${existingCertSanValuesWithoutZone}" | jq -r 'sort|.[]') <(echo "${certSanAdditionalDomainsJsonArray}" | jq -r 'sort|.[]') &>/dev/null; then
            # diff in SAN values means we _must_ request a new certificate
            log-info "  Existing certificate subject alternate names (SAN) list does not match A records of DNS zone"
            log-info "    Existing certificates' SAN:"
            for san in $(echo "${existingCertSanValuesWithoutZone}" | jq -r 'sort|.[]'); do
              log-info "     - ${san}"
            done
            log-info "    A records of DNS zone are:"
            for san in $(echo "${certSanAdditionalDomainsJsonArray}" | jq -r 'sort|.[]'); do
              log-info "     - ${san}"
            done
            log-info "  A new certificate will be requested"
            renewing=false
          else
            # no diff found, we can renew the existing cert
            log-info "  Existing certificate matches DNS zone name and A records, proceeding to evaluate renewal of existing certificate"
            renewing=true
          fi
        fi # if not force new cert

      else
        log-info "  Certificate for this zone does not exist in KeyVault: ${certKvName}, secret name: ${certKvPfxSecretName}"
        log-info "  A new certificate will be requested from Let's Encrypt"

        # issuing new certificate
        renewing=false
      fi

      if [ "${renewing}" = false ] || [ "${forceNew}" = true ]; then

        log-info "  Requesting new certificate from Let's Encrypt for ${zoneName}"
        if ! requestNewCertificate; then
          logCertificateActionError "failed to obtain certificate from Let's Encrypt"
          # Record the precise failure and move on, symmetric with the renewal path below. Without
          # this the zone would fall through to the generic "expected certificate file not found"
          # branch, mis-attributing a Let's Encrypt/DNS failure. The account-key sanity checks that
          # follow only apply to a SUCCESSFUL issuance, so skipping them here is correct.
          recordCertMetric "failed" "-" "failed to obtain certificate from Let's Encrypt"
          continue
        fi

      elif [ "${renewing}" = true ]; then

        # download existing cert from KeyVault to local filesystem
        log-info "  Saving existing certificate to local filesystem"
        if ! installZoneCertFromKeyVault "${certKvName}" "${certKvPfxSecretName}" "${certPath}" "${certKeyPath}" "${certIssuerPath}" "${pfxCertPassword}"; then
          logCertificateActionError "Failed to install existing certificate from KeyVault to local filesystem"
          recordCertMetric "failed" "-" "failed to install existing certificate from KeyVault"
          continue
        fi

        # Restore lego's metadata so `lego run` recognises the cert and ARI can decide. If it
        # is missing (cert predates metadata persistence), lego re-issues once and we persist it.
        restoreLegoMetadataFromKeyVault "${certKvMetaSecretName}" "${legoCertMetaPath}" || true

        if [ "${forceRenewal}" = true ]; then
          log-info "  Existing certificate for ${zoneName} will be renewed now (forceRenewal=true)"
        else
          log-info "  Evaluating renewal of existing certificate for ${zoneName} via ARI (fallback: lego --renew-days default)"
        fi

        if ! renewExistingCertificate; then
          logCertificateActionError "failed to renew certificate from Let's Encrypt"
          recordCertMetric "failed" "-" "failed to renew certificate from Let's Encrypt"
          continue
        fi

      else
        logCertificateActionError "Internal error, neither requesting new certificate nor evaluating renewal of existing"
        break
      fi # end if not renewing

      if [ "${creatingLetsEncryptAccount}" = false ] && ! diff -Z <(echo -n "${accountKey}") <(cat "${accountKeyPath}") &>/dev/null; then
        # sanity check: compare account key with that stored in .key file, should be identical but lego could've updated on disk
        logCertificateActionError "Account key was modified on disk during certificate renewal, certificate will not be stored in KeyVault"
        logCertificateActionError "Certificate will not be stored in KeyVault"
        recordCertMetric "failed" "-" "account key modified on disk; certificate not stored"
        continue
      elif [ "${creatingLetsEncryptAccount}" = true ] && [ ! -f "${accountKeyPath}" ]; then
        # sanity check: if we created a new account, the account key file should now exist
        logCertificateActionError "Expected account key file not found after successful certificate request: ${accountKeyPath}"
        logCertificateActionError "Certificate will not be stored in KeyVault"
        recordCertMetric "failed" "-" "account key file missing after issuance; certificate not stored"
        continue
      elif [ "${creatingLetsEncryptAccount}" = true ]; then
        # if creating new account, capture the credentials from disk and store in KeyVault as soon as possible
        log-info "  Capturing newly created Let's Encrypt account details from disk and storing in KeyVault: ${certKvName}"

        # compress and validate json with jq
        accountJsonMinified=$(jq -c . "${accountJsonPath}")

        # save to KeyVault
        accountJsonSecretId=$(az keyvault secret set --name "${letsencryptAccountJsonSecretName}" --vault-name "${certKvName}" --value "${accountJsonMinified}" --query id -o tsv)
        log-info "    Stored account JSON in KeyVault secret: ${accountJsonSecretId}"

        accountEmailSecretId=$(az keyvault secret set --name "${letsencryptAccountEmailSecretName}" --vault-name "${certKvName}" --value "${accountEmail}" --query id -o tsv)
        log-info "    Stored account email in KeyVault secret: ${accountEmailSecretId}"

        accountKeySecretId=$(az keyvault secret set --name "${letsencryptAccountKeySecretName}" --vault-name "${certKvName}" --value "$(cat "${accountKeyPath}")" --query id -o tsv)
        log-info "    Stored account key in KeyVault secret: ${accountKeySecretId}"

        # only do this for the first successful cert request
        creatingLetsEncryptAccount=false

        # make sure no diff is detected in preceding iterations
        accountKey=$(cat "${accountKeyPath}")
        accountJson=$(cat "${accountJsonPath}")
      fi

      # check if expected local file exists
      if [ ! -f "${pfxCertPath}" ] && [ "${renewing}" = false ]; then
        logCertificateActionError "Expected certificate file not found: ${pfxCertPath}"
        recordCertMetric "failed" "-" "expected certificate file not found after issuance"
        continue
      elif [ ! -f "${pfxCertPath}" ] && [ "${renewing}" = true ]; then
        log-info "  No new certificate file found after renewal evaluation operation, assuming certificate renewal was not needed"
        recordCertMetric "skipped" "${certPath}" ""
        continue
      else
        log-info "  Certificate file found: ${pfxCertPath}"
        log-info "  Importing certificate into KeyVault: ${certKvName}, secret name: ${certKvPfxSecretName}"
        if importResultJson=$(
          az keyvault certificate import \
            --vault-name "${certKvName}" \
            --name "${certKvPfxSecretName}" \
            --file "${pfxCertPath}" \
            --password "${pfxCertPassword}" \
            --tags "${kvCertSecretTags[@]}"
        ); then
          log-info "  Successfully imported certificate into KeyVault"

          # output versionless id of the imported secret
          certVersionlessKvId="$(echo "${importResultJson}" | jq -r .sid | sed 's|/[0-9a-fA-F]\{32\}$||')"
          log-info "    Versionless secret id: ${certVersionlessKvId}"

          # Persist lego's metadata for this freshly issued/renewed cert so the NEXT run can
          # restore it and let ARI decide on renewal. The certUrl changes each issuance, so this
          # must run on every successful import. Not fatal if it fails: worst case the next run
          # re-issues once and re-persists.
          storeLegoMetadataInKeyVault "${legoCertMetaPath}" "${certKvMetaSecretName}" || true

          metricAction="issued"
          [ "${renewing}" = true ] && metricAction="renewed"
          [ "${renewing}" = true ] && [ "${forceRenewal}" = true ] && metricAction="forced"
          recordCertMetric "${metricAction}" "${certPath}" ""
        else
          logCertificateActionError "Failed to import certificate into KeyVault"
          recordCertMetric "failed" "-" "failed to import certificate into KeyVault"
        fi
      fi

      # clean up
      log-info "  Cleaning up local lego certificate directory: ${legoCertificatesPath}"
      rm -rf "${legoCertificatesPath}"
      unset pfxCertPassword
    fi # end if zone is publicly delegated

    end-group # end zone

  done

  # =====================================================================================================================
  #region Metrics
  # =====================================================================================================================
  start-group "Metrics"

  # Assemble the per-cert records into a JSON array. This is the artifact monitoring jobs consume
  # (schema + file naming documented in docs/cert-warden-migration/, Phase 3 §3.4). Managed certs
  # only -- orphaned/let-expire objects are never recorded, so they never generate alert noise.
  certMetricsOutputFile="${CERT_METRICS_OUTPUT_FILE:-${GITHUB_WORKSPACE:-.}/cert-warden-metrics-${letsencryptEnvironment}.json}"
  jq -s '.' "${metricsFile}" >"${certMetricsOutputFile}"
  log-info "  Wrote per-cert metrics: ${certMetricsOutputFile}"

  # Run-level rollup. min_lifetime_fraction is the single number the symptom-based alert keys on:
  # it only drops on SUSTAINED renewal failure, is lifetime-relative (works for 90-day or 6-day
  # certs), and ignores transient single-run failures.
  metricsTotal=$(jq 'length' "${certMetricsOutputFile}")
  metricsManaged=$(jq '[.[] | select(.action != "not_delegated")] | length' "${certMetricsOutputFile}")
  metricsFailed=$(jq '[.[] | select(.action == "failed")] | length' "${certMetricsOutputFile}")
  metricsMinFraction=$(jq '[.[] | .lifetime_fraction_remaining // empty] | if length > 0 then min else null end' "${certMetricsOutputFile}")
  log-info "  Summary: zones=${metricsTotal} managed=${metricsManaged} failed=${metricsFailed} min_lifetime_fraction=${metricsMinFraction}"

  # GitHub step summary: a human-readable per-run table (no-op outside GitHub Actions).
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Cert Warden — \`${letsencryptEnvironment}\` run summary"
      echo ""
      log-info "zones: **${metricsTotal}** · managed: **${metricsManaged}** · failed: **${metricsFailed}** · min lifetime remaining: **${metricsMinFraction}**"
      echo ""
      echo "| zone | action | days to expiry | lifetime % left | key type | error |"
      echo "| --- | --- | ---: | ---: | --- | --- |"
      jq -r '.[] | "| \(.zone) | \(.action) | \(.days_to_expiry // "") | \(if .lifetime_fraction_remaining == null then "" else (.lifetime_fraction_remaining * 100 | floor) end) | \(.key_type // "") | \(.error) |"' "${certMetricsOutputFile}"
    } >>"${GITHUB_STEP_SUMMARY}"
    log-info "  Wrote GitHub step summary"
  fi

  end-group # Metrics
  #endregion Metrics

  # clean up
  start-group "Cleanup"
  log-info "  Cleaning up local lego directory: ${legoDirPath}"
  rm -rf "${legoDirPath}"
  rm -f "${metricsFile}"
  end-group # Cleanup

  # Exit with error count if any errors occurred
  if [ "${certificateActionErrorCount}" -gt 0 ]; then
    echo ""
    log-info "Script completed with ${certificateActionErrorCount} error(s). Exiting with non-zero status code."
    exit 1
  else
    echo ""
    log-info "Script completed successfully with no errors."
    exit 0
  fi

}

#endregion Main

# Source-guard: execute only when run directly. Sourcing (tests, tooling) loads the functions
# and loadConfig without side effects — see docs/testing.md.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  loadConfig
  main "$@"
fi
