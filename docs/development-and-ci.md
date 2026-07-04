# Development and CI — how to change things, how the machinery behaves

## The golden path

1. Branch from `main`; make changes with **conventional commits** (see §Commits — CI posts an
   explainer if a commit doesn't parse).
2. Open a PR. CI runs the full layer stack ([testing.md](testing.md)); the PR immediately gets
   a **preview ref** in a sticky comment (see §Preview refs) — use it to test from a calling
   repo with zero manual steps.
3. Merge (merge commit — this repo never squashes). Nothing preview-related lands on `main`.
4. release-please accumulates merged changes into a single **release PR**; merging that PR
   tags `vX.Y.Z`, publishes the (immutable) GitHub Release, moves the floating `v1` tag, and
   the annotated internal refs + docs bump themselves.

## Commits

Commit messages are load-bearing: release-please derives versions and the public
`CHANGELOG.md` from them, and merge commits mean every PR commit lands on `main` verbatim.

- `feat:` → minor, `fix:` → patch, `feat!:`/`BREAKING CHANGE:` footer → major,
  `docs/test/ci/chore/refactor/build/perf:` → no release.
- CI lints every PR commit; on failure a sticky comment lists the offending commits, the rule,
  a cheat-sheet, and the fix (`git rebase -i` + reword). Install the local hook to catch it at
  commit time: `scripts/install-git-hooks.sh`.
- **Never reference private repositories** in commit messages — they end up in the public
  changelog. The private-reference guard fails the PR if you do.

## Preview refs (the no-ritual test mechanism)

On every same-repo PR, `pr-preview.yml`:

1. rewrites all internal `uses: dsb-norge/cert-warden/...@vX.Y.Z` refs to `preview/pr-<N>`
   (`scripts/ci/rewrite-internal-refs.sh`),
2. creates a **detached generated commit** of that tree (parent = the PR head; the PR branch
   is never touched),
3. force-pushes tag `preview/pr-<N>` and upserts a sticky comment with copy-paste `uses:`
   lines,
4. **dispatches `preview-consume.yml` at that tag** and awaits it — the suite consumed through
   GitHub's real remote-fetch path, as a calling repo would (this is also the continuous proof
   that the shared `lib/helpers.bash` resolves in remotely-fetched actions),
5. deletes the tag when the PR closes.

Invariants: `main` never contains preview scaffolding; consumers can use the preview ref
immediately; fork PRs get tests but no preview (the job needs `contents: write`).

## Releases

- `release-please.yml` authenticates as the org's **`dsb-norge-cert-warden-releaser`**
  GitHub App (`RELEASE_APP_ID` repo variable + `RELEASE_APP_PRIVATE_KEY` secret; the job
  no-ops if unset). The App — not `GITHUB_TOKEN` — is required because the release PR edits
  files under `.github/workflows/` (needs the App's `workflows: write`) and because
  App-created PRs trigger CI.
- Internal refs carry `# x-release-please-version` annotations: **exactly one semver string
  per annotated line**. release-please rewrites them in the release PR (config:
  `release-please-config.json`, `extra-files` with `"type": "generic"` — mandatory for YAML
  paths).
- The floating major tag (`v1`) is a **plain git tag**, force-moved by the release workflow.
  Never create a GitHub Release named `v1` — with immutable releases enabled that would freeze
  it permanently.
- Rollback story: immutable tags can't move; re-release forward (revert commit → new release).
  Consumers pinning exact versions simply don't bump.
- First release: land a commit with a `Release-As: 1.0.0` footer when the suite is ready.

## Reusable-workflow inputs: configuration, not behaviour

New inputs on `reusable-*.yml` need a justification in the PR description. A consumer needing
different *behaviour* composes the actions (`dsb-norge/cert-warden/actions/*`) in their own
workflow — that escape hatch is what keeps the packaged workflows small.

## CI at a glance

`ci.yml` — one aggregated required check, **`ci-conclusion`**; extend its `needs` when adding
jobs. Also required on PRs: **`preview-consume-e2e`** (in `pr-preview.yml`). Tool versions are
pinned in the workflow `env` block with `# renovate:` annotations; third-party actions are
SHA-pinned (enforced by pinact; internal tag-pins are exempted in `.pinact.yaml` and
`zizmor.yml` — both by design, see [testing.md](testing.md) and the design docs).

## Local development

- Unit/integration suites: see [testing.md](testing.md) §7.
- Run the real thing against a real environment from a laptop:
  `scripts/run-local.sh <env-file> [warden|sweeper|monitor]` (see
  [consumer-prerequisites.md](consumer-prerequisites.md) for the identity/network you need).
- `act` can iterate on workflow YAML locally but is **never** a merge gate — hosted-runner CI
  is the truth.

## Dependency management

Renovate bumps: SHA-pinned third-party actions (with version comments), the `# renovate:`
annotated tool versions (shfmt/actionlint/yamllint/zizmor/pinact/bats/lego), and the harness
container images. It must never touch internal `dsb-norge/cert-warden` refs
(`ignoreDeps`) — those belong to release-please. lego majors additionally change the Go module
path in `actions/setup-lego` and get validated against the L2 suite by a maintainer.
