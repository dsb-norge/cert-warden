# Contributing

Start with **[docs/development-and-ci.md](docs/development-and-ci.md)** — the golden path
(conventional commits, the PR preview mechanism, how releases happen) — and
**[docs/testing.md](docs/testing.md)** for the test layers and how to run them locally.

The short version:

1. `scripts/install-git-hooks.sh` (catches commit-message problems before CI does).
2. Branch, commit conventionally, open a PR. CI posts a preview ref you can consume from any
   repo; nothing merges without green `ci-conclusion` + `preview-consume-e2e`.
3. Merge commits only (never squash). Never reference private repositories anywhere —
   including commit messages (they surface in the public changelog); CI enforces this.

Security tooling and how to respond to its findings: [docs/security-tooling.md](docs/security-tooling.md).
