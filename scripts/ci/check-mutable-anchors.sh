#!/usr/bin/env bash
#
# Mutable-anchor watchdog — runs in the weekly drift canary (ci.yml drift-watchdog job).
#
# THREAT MODEL: the repo pins what executes (SHA-pinned actions, digest-pinned images,
# lockfile-hashed npm, git-verified bats). What a pin CANNOT do is tell us when the upstream
# name we pinned FROM starts meaning something else — a re-pushed registry tag, a moved git
# tag, a wheel quietly added to an old PyPI release so future installs prefer it. None of
# those change a byte in this repo. This script checks every such anchor weekly and fails
# the canary on drift, turning "silent" into "Monday-morning red".
#
# ZERO-MAINTENANCE BY DESIGN: expectations are DERIVED from the repo's own pins wherever
# possible (compose file digests, BATS_CORE_REF, tool versions in ci.yml), so Renovate bumps
# never require updating this script. Only underivable values live in
# .github/mutable-anchors.json (vendored-lib provenance, the bashcov gem hash) — and the gem
# check cross-verifies its manifest version against the ci.yml pin so a forgotten manifest
# update fails loudly instead of checking a stale artifact.
#
# Requires: curl, jq, gh (GH_TOKEN for git-tag lookups).
set -euo pipefail
shopt -s inherit_errexit

repoRoot="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="${repoRoot}/.github/mutable-anchors.json"
ciYml="${repoRoot}/.github/workflows/ci.yml"
failures=0

fail() {
  echo "::error::${1}"
  failures=$((failures + 1))
}

ciEnvValue() { # extract a value from ci.yml's env block, e.g. ciEnvValue ZIZMOR_VERSION
  grep -oP "^\s*${1}:\s*\"?\K[^\"]+" "${ciYml}" | head -n 1
}

# --- 1. Harness images: does the upstream tag still resolve to our pinned digest? ---------
# Our digest pin means CI is safe either way; drift here means the upstream tag was
# RE-PUSHED — an upstream-compromise/re-release signal that deserves eyes.
registryTagDigest() { # <name> <tag> -> current digest for the tag, or empty
  local name="${1}" tag="${2}" token
  local accept="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
  if [[ "${name}" == ghcr.io/* ]]; then
    local path="${name#ghcr.io/}"
    token="$(curl -sf "https://ghcr.io/token?scope=repository:${path}:pull" | jq -r .token)"
    curl -sf -D - -o /dev/null -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
      "https://ghcr.io/v2/${path}/manifests/${tag}" |
      grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}'
  else # Docker Hub (no registry host prefix)
    curl -sf "https://hub.docker.com/v2/repositories/${name}/tags/${tag}" | jq -r .digest
  fi
}

while IFS= read -r image; do
  name="${image%%:*}"
  rest="${image#*:}"
  tag="${rest%%@*}"
  pinned="${rest#*@}"
  current="$(registryTagDigest "${name}" "${tag}")" || current=""
  if [[ -z "${current}" ]]; then
    fail "watchdog: could not resolve ${name}:${tag} upstream"
  elif [[ "${current}" != "${pinned}" ]]; then
    fail "watchdog: upstream tag ${name}:${tag} was RE-PUSHED — now ${current}, our pin is ${pinned}"
  else
    echo "ok: ${name}:${tag} still resolves to pinned digest"
  fi
done < <(grep -hoP '^\s*image:\s*\K\S+@sha256:[0-9a-f]{64}' "${repoRoot}"/tests/harness/docker-compose*.yml)

# --- 2. bats-core: does the tag half of BATS_CORE_REF still point at the sha half? --------
githubTagCommit() { # <owner/repo> <tag> -> commit sha (dereferences annotated tags)
  local repo="${1}" tag="${2}" sha type
  sha="$(gh api "repos/${repo}/git/ref/tags/${tag}" --jq .object.sha)"
  type="$(gh api "repos/${repo}/git/ref/tags/${tag}" --jq .object.type)"
  if [[ "${type}" == "tag" ]]; then
    gh api "repos/${repo}/git/tags/${sha}" --jq .object.sha
  else
    echo "${sha}"
  fi
}

batsRef="$(ciEnvValue BATS_CORE_REF)"
batsTag="${batsRef%%@*}"
batsSha="${batsRef##*@}"
current="$(githubTagCommit bats-core/bats-core "${batsTag}")" || current=""
if [[ "${current}" != "${batsSha}" ]]; then
  fail "watchdog: bats-core tag ${batsTag} MOVED — now ${current:-unresolvable}, our pin is ${batsSha}"
else
  echo "ok: bats-core ${batsTag} still points at pinned commit"
fi

# --- 3. Vendored helper libs: upstream tag-move detection (signal only; see manifest) ------
while IFS=$'\t' read -r repo tag commit; do
  current="$(githubTagCommit "${repo}" "${tag}")" || current=""
  if [[ "${current}" != "${commit}" ]]; then
    fail "watchdog: ${repo} tag ${tag} MOVED — now ${current:-unresolvable}, vendored from ${commit}"
  else
    echo "ok: ${repo} ${tag} unmoved"
  fi
done < <(jq -r '."vendored-github-tags"[] | [.repo, .tag, .commit] | @tsv' "${manifest}")

# --- 4. PyPI: a wheel ADDED to an old release would win future installs (version pins do ---
# not foreclose this). Releases upload all files within minutes; any file appearing > 7 days
# after the release's first file is an anomaly.
for name in yamllint zizmor; do
  version="$(ciEnvValue "$(tr '[:lower:]' '[:upper:]' <<<"${name}")_VERSION")"
  spreadDays="$(curl -sf "https://pypi.org/pypi/${name}/${version}/json" |
    jq -r '[.urls[].upload_time_iso_8601 | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601] | if length == 0 then -1 else ((max - min) / 86400 | floor) end')" || spreadDays=""
  if [[ -z "${spreadDays}" || "${spreadDays}" == "-1" ]]; then
    fail "watchdog: could not inspect PyPI files for ${name}==${version}"
  elif ((spreadDays > 7)); then
    fail "watchdog: ${name}==${version} has files uploaded ${spreadDays} days apart — a file was ADDED to an old release; pip may now prefer it"
  else
    echo "ok: ${name}==${version} file set uploaded within ${spreadDays} day(s)"
  fi
done

# --- 5. bashcov gem: exact artifact hash (manifest), cross-checked against the ci.yml pin --
gemVersionPinned="$(ciEnvValue BASHCOV_VERSION)"
gemVersionManifest="$(jq -r '.rubygems[] | select(.gem == "bashcov") | .version' "${manifest}")"
gemShaManifest="$(jq -r '.rubygems[] | select(.gem == "bashcov") | .sha256' "${manifest}")"
if [[ "${gemVersionPinned}" != "${gemVersionManifest}" ]]; then
  fail "watchdog: bashcov manifest lags the pin (${gemVersionManifest} vs ${gemVersionPinned}) — update .github/mutable-anchors.json in the bump PR (sha: rubygems.org/api/v2/rubygems/bashcov/versions/<v>.json)"
else
  gemShaCurrent="$(curl -sf "https://rubygems.org/api/v2/rubygems/bashcov/versions/${gemVersionPinned}.json" | jq -r .sha)" || gemShaCurrent=""
  if [[ "${gemShaCurrent}" != "${gemShaManifest}" ]]; then
    fail "watchdog: bashcov ${gemVersionPinned} gem sha CHANGED at rubygems (${gemShaCurrent:-unresolvable} vs recorded ${gemShaManifest})"
  else
    echo "ok: bashcov ${gemVersionPinned} gem sha unchanged at rubygems"
  fi
fi

if ((failures > 0)); then
  echo "::error::${failures} mutable anchor(s) drifted — see docs/security-tooling.md §mutable-anchor watchdog"
  exit 1
fi
echo "all mutable anchors verified"
