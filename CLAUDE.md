# Cert Warden: notes for AI assistants

Start with [CONTRIBUTING.md](CONTRIBUTING.md). The docs index is in
[README.md](README.md#documentation). This file only holds what an assistant needs on top of
those.

## Check the Security tab after every merge and before every release

Copilot's PR review is supposed to catch what the scanners catch, and it often doesn't. So:

- **After merging a PR**, and **before merging a release-please PR**, run
  `bash scripts/security-findings.sh --wait`. Run it in the background: it waits for the
  CodeQL, dependency-graph and `ci.yml` runs on `main`'s HEAD before reporting. It covers code
  scanning (CodeQL and zizmor), Dependabot vulnerabilities and malware, and secret scanning,
  including generic patterns. Code Quality is not enabled here, and the script says so. Code
  Quality AI findings have no API and are out of scope.
- **Assess each finding; don't just apply its recommendation.** Check it against
  [docs/security-tooling.md](docs/security-tooling.md) first. Then choose one: propose a fix (a
  follow-up PR; before a release, say whether it must land first); propose a suppression in
  the tool's own file (zizmor findings go in `zizmor.yml`); propose a permanent ignore; or
  leave it open with a reason. Report the outcome in chat.
- **Don't dismiss or resolve anything in GitHub.** Permanent ignores are recorded in the
  table in
  [docs/security-findings.md](docs/security-findings.md#permanently-ignored-findings), one row
  per finding ID with the reason. The script skips them, and flags rows whose finding has
  closed so they can be pruned.

## Pull requests and the Copilot review loop

- **PRs here are opened ready for review, not as drafts.** This is the maintainer's decision
  for this repository (2026-09-29), and it overrides a user-level "draft PR" default. Don't ask
  before marking a cert-warden PR ready, and don't open one as a draft. The reason is that
  Copilot's automatic review (a `main` ruleset) only runs on ready PRs. Being ready is not
  permission to merge: merging still waits for the maintainer.
  Hand a PR to the maintainer only once every thread is resolved. Each push triggers a fresh
  review, so loop: push, wait for the review, answer every thread. Stop when a review leaves
  nothing open, or when a thread needs the maintainer's decision.
- **A review can come back empty-handed.** Copilot's review is charged to the account that
  triggered it. When that account is out of Copilot quota, the "review" is a single comment:
  "Copilot was unable to review this pull request because the user who requested the review has
  reached their quota limit." There are no threads. Report that and hand the PR over. Don't keep
  pushing or re-requesting to get a review; each attempt fails the same way until the quota
  resets.
- **Every review thread gets an answer before it is resolved.** `main`'s rulesets block
  merging on any unresolved thread, and `--admin` does not bypass it. Answer each thread with
  the proposed change, a different fix, or a rationale; recurring false positives go under
  "Review findings rejected on sight" in
  [docs/development-and-ci.md](docs/development-and-ci.md#review-threads-every-one-gets-an-answer).
  Reply saying which one it is, with the fixing commit, *then* resolve. Reviews that land
  after merge are fixed in the next PR and answered on the old thread.
- **Mechanics** (replace `N` with the PR number):
  - List threads:
    `gh api graphql -f query='{repository(owner:"dsb-norge",name:"cert-warden"){pullRequest(number:N){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{databaseId path body}}}}}}}'`
  - Reply: `gh api repos/dsb-norge/cert-warden/pulls/N/comments/<databaseId>/replies -f body=…`
  - Resolve:
    `gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"<id>"}){thread{isResolved}}}'`

## Things that bite

- **This repo is public.** Never name a private repository in files, commit messages or PR
  text. The private-reference guard fails CI on it
  ([security-tooling.md](docs/security-tooling.md#the-private-reference-guard)).
- **Local tools must match CI's pins.**
  - A lego v4 on `PATH` fails most of `bats tests/integration` with
    `flag provided but not defined: -path`. [testing.md](docs/testing.md) has the v5 install
    command.
  - An shfmt older than `SHFMT_VERSION` in `ci.yml` accepts formatting that CI rejects. Install
    the pinned one with `go install mvdan.cc/sh/v3/cmd/shfmt@<SHFMT_VERSION>`.
  - Install both into a directory of their own, and put it first on `PATH` only for the run.
- **Part of the L2 suite runs against a chaos-configured Pebble.** From e2e-7 on, Pebble
  rejects 20% of nonces, and lego gives up after two attempts. So a failure reading
  `badNonce ... giving up after 2 attempt(s)` can be that alone. Rerun the failed job once
  before debugging; if it fails the same way again, treat it as real.
- **Don't filter a workflow-run listing when you need the newest run.** `gh run list --status …`
  and the other filters turn the listing into a search capped at 1,000 results, which then
  serves stale pages. That made the monitor evaluate a weeks-old warden run. Pitfall P-27 in
  [testing.md](docs/testing.md#5-the-pitfalls-catalogue) has the details and the safe pattern
  (`latestRun` in `reusable-monitor.yml`). A `head_sha` filter on one commit matches only a few
  runs, so it stays well under the cap.
