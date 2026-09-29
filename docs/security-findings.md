# Security and Quality Findings

The repository's **Security and quality** tab collects findings from several scanners: CodeQL
code scanning (Default Setup: Actions, JavaScript/TypeScript and Python), zizmor (SARIF uploaded
by `ci.yml`), Dependabot (vulnerabilities and malware; Renovate does the version bumps, Dependabot
only alerts), and secret scanning (default and generic patterns). Code Quality is **not enabled**
for this repository (checked 2026-09-29), and the script says so rather than reporting it clean.

CI gates some of this and not the rest. zizmor fails the PR (see
[security-tooling.md](security-tooling.md#zizmor-workflowaction-security-audit)), but a Dependabot
advisory published against a dependency already on `main` reaches nobody unless someone looks, and
Copilot's PR review doesn't reliably catch what the scanners catch. So these findings are checked
separately, at fixed points.

The routine and [`scripts/security-findings.sh`](../scripts/security-findings.sh) are ported from
[dsb-norge/teams-notifier-function-app](https://github.com/dsb-norge/teams-notifier-function-app),
so the two repositories are checked the same way.

## When to check

- **After merging a PR**, once the scans on the merge commit have finished.
- **Before merging a release-please PR**, so a release doesn't ship with an open finding nobody
  has looked at.

## How to check

```bash
bash scripts/security-findings.sh --wait   # waits for the scans on main's HEAD, then reports
bash scripts/security-findings.sh          # reports now; warns if scans are still running
bash scripts/security-findings.sh --all    # also lists the ignored findings below
bash scripts/security-findings.sh --json   # machine-readable, including URLs
```

The script is read-only. It lists every open finding except those in the
[permanently ignored](#permanently-ignored-findings) table, and it names any entry in that table
that is no longer open so the entry can be removed. It needs `gh` with the `repo` scope and `jq`.
`--wait` waits for CodeQL, the dependency graph and `ci.yml` (whose zizmor job uploads SARIF) on
`main`'s HEAD, which takes about five minutes after a merge.

A source the repository has not enabled is reported as `not enabled for this repository`. Any
other API failure stops the script with gh's error, because a report with a source silently
missing reads exactly like a clean one.

**Code Quality AI findings are not covered.** GitHub has no API for them; they exist only in the
web UI and are not part of this routine.

## How to assess a finding

Treat each finding as a question, not an instruction. A scanner's suggested fix is often wrong
for this codebase. Check it against the house rules first:
[security-tooling.md](security-tooling.md) says which behaviour is deliberate and where its
suppression lives. For each finding, decide:

1. **Fix it** in a follow-up PR. Before a release, decide whether the fix has to land first.
   GitHub closes a fixed finding by itself on the next scan of `main`.
2. **Suppress it at the source** when the tool has a suppression file. zizmor findings go in
   `zizmor.yml` with a justification, like every other suppression here ("suppressions are
   code"). That also keeps the CI gate green, which the table below cannot do.
3. **Ignore it permanently** when there is no such file (Dependabot, CodeQL Default Setup,
   secret scanning) and the code is deliberate or the finding is a false positive that won't
   change. Add a row to the table below with the reason.
4. **Leave it open** when it is real but not worth acting on yet. It will show up again at the
   next check, which is intended.

**Findings are not dismissed or resolved in GitHub.** The table below is the record.

## Permanently ignored findings

Entries are per finding number, not per rule, so a new instance of a known rule is still
assessed. If code changes enough that GitHub opens the same finding under a new number, assess it
again, add the new ID, and remove the old one (the script lists it as no longer open).

The script reads the ID from the first column, so keep it in the form `` `<kind>#<number>` ``,
where `<kind>` is `code-scanning`, `code-quality`, `dependabot` or `secret-scanning`. A unit test
(`tests/unit/security-findings.bats`) fails on a row it could not read.

| ID | Rule | Location (when recorded) | Why it is ignored | Recorded |
|----|------|--------------------------|-------------------|----------|
