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
