# Dependency bumps — the maintainer runbook

Renovate does the routine bumps. This is the manual procedure, for when you need a full sweep,
a security response, or simply to review what Renovate proposed with your eyes open.

The standing rule: **a version string you bumped but never executed is not a bump, it's a
guess.** Every step below exists to make you run the new thing before you ask anyone to merge
it.

## 1. The surface

Six kinds of external dependency. The common principle: pin the thing that *executes*, not
just the name it goes by — a tag or version string alone can be re-pointed upstream without
any diff appearing here.

| Surface | Lives in | Pinned as | Owner |
|---|---|---|---|
| Third-party actions | `.github/workflows/*.yml`, `**/action.yml` | full 40-char SHA + `# vX.Y.Z` comment | pinact / Renovate |
| CI tool versions | the `env:` block of `ci.yml` | value under a `# renovate:` annotation | Renovate |
| commitlint (npm) | root `package.json` + `package-lock.json` | exact versions + lockfile integrity hashes | Renovate |
| bats-core | `BATS_CORE_REF` in the `env:` block of `ci.yml` | tag`@`commit-SHA, git-verified at install | Renovate |
| bats helper libs | `tests/vendor/` | vendored copies ([tests/vendor/README.md](../tests/vendor/README.md)) | maintainer |
| lego (consumer-facing) | `actions/setup-lego/action.yml` and `reusable-warden.yml` input defaults | value under a `# renovate:` annotation | Renovate + maintainer |
| Harness images | `tests/harness/docker-compose*.yml` | exact tag `@sha256:` digest | Renovate |
| Internal refs | `dsb-norge/cert-warden/...@vX.Y.Z` | tag + `# x-release-please-version` | **release-please only** |

Two things follow from the table:

- **Never bump an internal `dsb-norge/cert-warden` ref by hand.** They belong to
  release-please (`ignoreDeps` keeps Renovate off them too); the PR preview mechanism rewrites
  them per-PR. Touching them by hand desynchronises both. `check-release-annotations.sh`
  fails the PR if you do.
- **Everything else third-party must be SHA-pinned**, enforced by pinact and by zizmor's
  `unpinned-uses` policy.

Not pinned, deliberately: the tools the hosted runner provides (`az`, `jq`, `openssl`, `dig`,
`go`, Ruby, `shellcheck`). Drift there is caught by the weekly scheduled CI run acting as a
canary, not by pinning ([testing.md](testing.md) P-21).

## 2. Resolving "latest"

| datasource | How |
|---|---|
| `go` | `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name`; confirm the module resolves: `curl -s https://proxy.golang.org/<module>/@v/<version>.info` |
| `pypi` | `curl -s https://pypi.org/pypi/<pkg>/json \| jq -r .info.version` |
| `rubygems` | `curl -s https://rubygems.org/api/v1/gems/<gem>.json \| jq -r .version` |
| `github-releases` | `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name` |
| docker images | `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name` for the upstream project, then `docker compose … pull` |

`releases/latest` has a trap this repo actually walks into:

- **`github/codeql-action`** publishes `codeql-bundle-*` as its newest release. The tag you
  want is the `v4.x` action tag — `gh api repos/github/codeql-action/tags`.

That is why step 3 uses pinact rather than a shell loop: pinact resolves the correct action
tag.

## 3. Bumping

Branch off `main` as usual, then:

**Third-party actions** — let pinact do it, across workflows *and* composite actions:

```bash
GITHUB_TOKEN="$(gh auth token)" pinact run -u   # bump to latest, re-resolving SHA + comment
GITHUB_TOKEN="$(gh auth token)" pinact run      # pin anything newly added, without bumping
```

**Never hand-type a SHA.** If you must resolve one yourself:
`gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`. A version comment that disagrees with
its SHA is worse than no comment — it is the thing a reader trusts.

**commitlint (npm)** — bump in `package.json` (exact versions, no ranges) and regenerate the
lockfile: `npm install --ignore-scripts && npm ci --ignore-scripts`. Never edit
`package-lock.json` by hand; its integrity hashes are the actual pin. Renovate's npm manager
does this automatically on its schedule.

**Annotated tool versions** — edit only the *value*; leave the `# renovate:` line untouched.
The annotation is what keeps Renovate able to bump it later, and `renovate.json`'s custom
regex manager requires the annotation to sit on the line immediately above:

```yaml
# renovate: datasource=pypi depName=zizmor
ZIZMOR_VERSION: "1.29.0"
```

**Harness images** — edit the tag in the compose file, then refresh the digest to match:
`docker buildx imagetools inspect <image>:<tag>` prints the manifest-list digest. The digest
is the real pin — registry tags are mutable, so a tag-only line can silently change what CI
pulls; Renovate maintains the pair automatically (`pinDigests` rule in `renovate.json`).

## 4. Verification — run the gates *at the new versions*

This is the step people skip. Bumping `SHFMT_VERSION` and then running your system's old
shfmt proves nothing about what CI will do.

Install each bumped tool at its new version first — a throwaway prefix keeps it off your
normal `PATH`:

```bash
GOBIN=/tmp/cw-tools go install mvdan.cc/sh/v3/cmd/shfmt@<new>
GOBIN=/tmp/cw-tools go install github.com/rhysd/actionlint/cmd/actionlint@<new>
python3 -m venv /tmp/cw-venv && /tmp/cw-venv/bin/pip install --only-binary :all: "yamllint==<new>" "zizmor==<new>"
export PATH="/tmp/cw-tools:$PATH"
```

Then the full local gate — the same set `ci.yml` runs:

```bash
shellcheck $(git ls-files '*.sh' '*.bash' '*.bats')
shfmt -d .
actionlint
yamllint --strict .
zizmor --no-progress .
GITHUB_TOKEN="$(gh auth token)" pinact run --check
bash scripts/ci/check-private-references.sh
bash scripts/ci/check-release-annotations.sh
bats tests/unit
bats tests/integration        # docker + lego on PATH; see testing.md §7
```

What each bumped tool can newly break:

- **shfmt** — minor releases change formatting rules; `shfmt -d .` must come back empty, and
  if it doesn't, the reformat belongs in the same commit.
- **zizmor** — new releases ship new audits. A new finding is a real signal: fix it, or add a
  scoped suppression *with a justification* to `zizmor.yml`
  (see [security-tooling.md](security-tooling.md)).
- **actionlint / yamllint** — new rules, same deal.
- **bats / bashcov** — run both suites, not just the unit one.
- **harness images** — `docker compose -f tests/harness/docker-compose.pebble.yml pull` then
  the L2 suite; a CoreDNS or Pebble major can reject the existing config.
- **lego** — see §5. The L2 suite is mandatory, not optional.

### 4b. Hand-built dist bundles — rebuild and diff

A node action executes its committed `dist/` bundle, not the `src/` you reviewed; upstreams
without a dist-verification CI can ship a bundle that differs from source. Three actions in
our list are in that category — at every bump of one of them, prove src == dist:

```bash
scripts/ci/verify-dist.sh googleapis/release-please-action <new-sha>  # gate: byte-identical or fail
scripts/ci/verify-dist.sh Azure/login <new-sha>                       # review: read the printed diff
scripts/ci/verify-dist.sh actions/create-github-app-token <new-sha>   # review: read the printed diff
```

azure/login is review-mode because its tags are known to ship *cosmetically* stale bundles
(at v3.0.1: a stale user-agent marker + CRLF noise) — a hard gate would false-fail forever.
Anything in the printed diff beyond that pattern is a stop-and-investigate signal.
create-github-app-token is review-mode until byte-reproducibility is established; it deserves
the strictest reading of the three — it is the only action handling a persistent credential
(the release App private key).

lego needs no equivalent: the Go module proxy + sum.golang.org transparency log already
guarantee the consumed artifact matches the tag (§5 covers the human checks).

## 5. lego bumps specifically

lego is the only dependency whose version reaches consumers, so it gets extra care.

- **The L2 suite is mandatory.** `bats tests/integration` runs real ACME issuance against
  Pebble; it is the only thing that proves the new client still works end to end.
- **Diff the CLI surface against the warden.** `lego help run` lists the flags; check every
  flag `actions/warden/cert-warden.sh` passes still exists. A silently-removed flag is the
  realistic failure mode, and it would surface in production, not in a lint.
- **Majors change the Go module path.** `…/lego/v5` is part of the `go install` line in
  `actions/setup-lego/action.yml` — a v6 needs that edit too, not just a version string.
- **Bump both defaults together**: `actions/setup-lego` (the action input) and
  `reusable-warden.yml` (the workflow input). They are separate strings.
- **Refresh version anchors in comments.** `cert-warden.sh` documents lego behaviour against a
  named version ("lego vX.Y.Z has no `--dynamic` flag"). If you re-verified the claim, update
  the version it names; if you didn't, don't.
- **Run govulncheck against the new binary and read the delta** —
  `govulncheck -mode=binary "$(command -v lego)"`. The weekly canary runs this warn-only
  (lego links every DNS provider into the binary, so symbol-presence findings routinely
  include code the azuredns path never calls); at a bump, *you* are the reachability
  assessment. A finding in lego core, the ACME paths, or the azure-sdk chain blocks the
  bump; a finding in some other provider's SDK is bump-with-next-release material.

## 6. Commit typing decides whether consumers get a release

release-please reads commit types, so this is not cosmetic:

- **`chore(deps):`** — CI-internal only: linters, test tooling, harness images, and actions
  used solely by our own workflows. No release.
- **`fix(deps):`** — anything that changes what a *consumer* receives. Today that means the
  lego default in `actions/setup-lego` / `reusable-warden.yml`. Cuts a patch release, which
  is what makes the new default reachable through a version tag.

A full sweep touches both kinds, so **split it into two commits** rather than picking one type
for the lot. Where a single file holds both (e.g. `reusable-warden.yml` carries an
`azure/login` pin *and* the lego default), stage the two hunks into their respective commits.

Put the from → to table in the commit body and the PR description. The next person doing a
security assessment reads exactly that.

## 7. Traps worth knowing

- **CI-green is not local-green.** Test tooling can change a default that CI happens to
  override, leaving CI passing while local development breaks. bats 1.14.0 did this: it began
  pre-seeding `BATS_LIB_PATH=/usr/lib/bats`, which killed the `${BATS_LIB_PATH:-…}` fallback
  in `tests/test_helper.bash`. CI sets that variable explicitly and never noticed. Run the
  suites **without** your usual environment overrides at least once per tooling bump.
- **A tool bump can change what "clean" means.** Formatters and linters that gate CI are also
  dependencies of your diff; treat a reformat or a new finding as part of the bump, not as an
  unrelated cleanup to defer.
- **`pinact run -u` also touches composite actions**, not only workflows. Review the whole
  diff, including `actions/*/action.yml`.
- **Renovate's schedule is not a substitute for reading the diff.** Bump PRs get reviewed like
  any change; CI, including L2, is the safety net.
