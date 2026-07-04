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
- **Local prevention**: `scripts/install-git-hooks.sh`.

## Renovate

- Bumps SHA-pinned actions, annotated tool versions, and harness images on a schedule.
  `ignoreDeps: ["dsb-norge/cert-warden"]` keeps it off release-please's territory. Review bump
  PRs like any change — CI (including the L2 suite) is the safety net; **lego major bumps**
  additionally need the module-path change in `actions/setup-lego` and a deliberate
  maintainer pass.

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
