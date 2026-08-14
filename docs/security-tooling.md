# Security tooling — the maintainer guide

Every security tool in this repo's pipeline, and — more importantly — what to do when one
blocks you. The standing rule: **suppressions are code**. Each one lives in a config file with
a written justification and gets reviewed like any change. A tool that's inconvenient gets a
scoped, justified suppression — never a disabled job.

## zizmor (workflow/action security audit)

- **What**: static audits of `.github/workflows/*` and `action.yml` files — template
  injection, excessive permissions, credential persistence (artipacked), cache poisoning,
  unpinned actions, env-file abuse.
- **Where findings appear**: fails the `zizmor` CI job (the gate) and uploads SARIF to the
  repo's **Security → Code scanning** tab (the record).
- **Responding**: prefer fixing (env-var indirection for expressions, tighter `permissions:`,
  `persist-credentials: false`). When the flagged behaviour is the design, suppress in
  `zizmor.yml` with a justification comment. Current deliberate suppressions:
  - `artipacked` for `pr-preview.yml`/`release-please.yml` (they push tags — that's their job);
  - `unpinned-uses` policy: internal `dsb-norge/cert-warden/*` refs are **tag**-pinned by
    design (release-please + preview rewriting own them); everything else must be SHA-pinned;
  - `github-env` for `action.yml` (setup-lego appends a runner-temp dir to `GITHUB_PATH`).
- **Escalation**: a finding you can neither fix nor confidently justify → treat as a blocker,
  not a nuisance; raise it with the maintainer group.

## pinact (pin enforcement)

- **What**: verifies every third-party `uses:` (workflows AND composite actions) is pinned to
  a full-length SHA with a version comment. Internal refs are exempted in `.pinact.yaml`
  (same design reason as above).
- **Responding to a failure**: run `pinact run` locally to pin what you added, commit the
  result. Never hand-type a SHA — resolve it (`gh api repos/<r>/commits/<tag> --jq .sha`).
  Bumping existing pins is `pinact run -u`; the full procedure is in
  [dependency-bumps.md](dependency-bumps.md).

## The private-reference guard

- **What**: `scripts/ci/check-private-references.sh` greps the tree AND the PR's commit
  messages for deny-listed patterns (`.github/private-ref-patterns.txt`). This repo is public;
  links that resolve to private DSB repositories must never appear — including in commit
  messages, which surface in the public changelog.
- **Responding**: rewrite the file content; for commit messages, `git rebase -i` + reword.
  There is no suppression path — extend the deny-list when new private hosts appear, never
  shrink it casually.

## commitlint

- **What/why**: conventional commits drive release-please (versions + public changelog); this
  repo merges with merge commits, so every commit must parse. Failures post a sticky PR
  comment with per-commit reasons and the reword recipe.
- **How**: `scripts/ci/lint-commits.mjs` + the root `package.json`/`package-lock.json`
  (`npm ci --ignore-scripts` — the lockfile's integrity hashes pin the whole dependency
  tree; `--ignore-scripts` blocks npm install hooks). It deliberately replaced
  `wagoid/commitlint-github-action`: that action's `action.yml` pulled a **mutable** Docker
  Hub tag at runtime, so our SHA pin froze the wrapper but not the executed code — the one
  thing a pin is for. The script uses the same `@commitlint/*` libraries the action wrapped
  and emits the same per-commit `results` output.
- **Local prevention**: `scripts/install-git-hooks.sh` (the hook runs the same lockfile-pinned
  install).

## Mutable-anchor watchdog

- **What/why**: a SHA or digest pin freezes what executes, but it cannot tell you when the
  upstream *name* you pinned from starts meaning something else — a re-pushed registry tag,
  a moved git tag, a wheel quietly added to an old PyPI release (which pip would prefer on
  the next install despite the version pin). None of those change a byte in this repo. The
  2026-08 dependency assessment found this "mutable anchor" pattern was the one systematic
  gap in an otherwise strong pin discipline, so it gets a systematic control:
  `scripts/ci/check-mutable-anchors.sh` verifies every such anchor in the weekly drift
  canary (`drift-watchdog` job) and fails on drift.
- **Zero-maintenance by design**: expectations are derived from the repo's own pins
  (compose digests, `BATS_CORE_REF`, tool versions), so Renovate bumps never touch it. Only
  underivable values live in `.github/mutable-anchors.json` — and those checks cross-verify
  against the ci.yml pin so a forgotten manifest update fails loudly.
- **Responding to a red watchdog**: drift is *upstream* news, not necessarily our breakage
  (our pins still protect CI). Treat a re-pushed tag or moved git tag as a potential
  upstream compromise: check the project's advisories/commits before bumping anything, and
  prefer waiting over fast-forwarding into an unexplained re-release.

## Renovate

- Bumps SHA-pinned actions, annotated tool versions, and harness images on a schedule.
  `ignoreDeps: ["dsb-norge/cert-warden"]` keeps it off release-please's territory. Review bump
  PRs like any change — CI (including the L2 suite) is the safety net; **lego major bumps**
  additionally need the module-path change in `actions/setup-lego` and a deliberate
  maintainer pass.
- Reviewing a Renovate PR, or doing a sweep by hand: [dependency-bumps.md](dependency-bumps.md).

## Planned (adopt deliberately, not by drift)

- **OpenSSF Scorecard**: weekly action + code-scanning results; adds an outside-in check on
  the pinning/permissions posture.
- **step-security/harden-runner**: egress audit mode on all CI jobs first; move to
  `egress-policy: block` per-job once the baselines are stable (CI egress is small and
  knowable: GitHub, GHCR, the Go module proxy, PyPI). Allow-list changes are reviewed like
  code.

## Repo/settings posture (for completeness)

Default-deny `permissions: {}` per workflow with per-job grants; `defaults.run.shell: bash`;
checkout with `persist-credentials: false` except the two tag-pushing jobs; immutable releases
(once enabled) with the floating `v1` as a plain tag; tag ruleset protecting `v*` from
update/delete; branch ruleset requiring PRs + `ci-conclusion`. The release GitHub App is the
only credential beyond `GITHUB_TOKEN`, scoped to this repo.
