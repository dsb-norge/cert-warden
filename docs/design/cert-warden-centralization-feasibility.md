# Cert Warden centralization — feasibility assessment

> **Imported design-history document.** Written during DSB-internal planning before this
> repository existed; imported at repo bring-up (July 2026). Some file paths and repository
> names it references are DSB-internal and not publicly accessible. Where this document and
> the implemented repository differ, the repository and its living docs under `docs/` win.

> Assesses whether and how to extract Cert Warden (+ Sweeper + Monitor) into its own repo with
> reusable workflows / composite actions. **Bring-up cost (scaffolding a new repo, CI, docs) is
> explicitly out of scope** per the framing — this evaluates the steady state: should it be
> centralized, which shape, and what the ongoing maintenance effort and risks look like.
>
> **Status: decided.** The verdict below was accepted with amendments — public repo in `dsb-norge`
> (not private in `dsb-infra`), standalone, ownership as for `github-actions-terraform`, CODEOWNERS
> deferred. The follow-up design is in
> [`cert-warden-repo-design-spec.md`](cert-warden-repo-design-spec.md), which supersedes this
> document where they differ.
>
> Inputs: this repo's `.github/cert-warden/` + `.github/workflows/cert-*.yml`, the origin copy in
> `azure-terraform-ikt-operations`, and a structural review of `dsb-norge/github-actions-terraform`
> (the org's existing central TF actions repo) plus `dsb-norge/github-actions`.

---

## 1. Verdict up front

**Yes, centralize — as a dedicated repo shipping composite actions as the unit of logic, with
thin packaged reusable workflows on top (hybrid, Strategy C below). But time the extraction to
land *after* the Phase 5 prod rollout stabilizes in this repo.**

The compressed reasoning:

- **Drift is not hypothetical — it already happened.** The ops copy and this repo's copy of
  `cert-warden.sh` differ by ~373 diff lines. Ops is still on lego **v4** with a fixed 60-day
  renewal threshold; this repo is on lego **v5** with ARI, per-cert metrics, monitoring, a sweeper,
  and a CI selftest. Ops has none of the `set -e` metrics-loss class of fixes beyond the one that
  was manually double-ported (#779 here / ops #359 — a fix that had to be applied twice is the
  copy-model tax in miniature).
- **The maintenance load is recurring by nature, not one-off.** Cert Warden tracks moving
  externals: lego releases (the v4→v5 move changed the module path *and* the renewal model), ACME
  protocol evolution (ARI/RFC 9773), and Let's Encrypt policy (cert lifetimes are being shortened
  industry-wide; the scripts already carry comments anticipating this). Every one of these will
  need doing again — once per copy, or once centrally.
- **The extraction interface already exists.** The scripts take *all* configuration via
  environment variables; every org/env-specific value (subscription IDs, UAMI client IDs, KV
  names, runner labels) lives in the consumer workflow's matrix. `helpers.sh` is byte-identical to
  the one in `dsb-norge/github-actions` composite actions, and even carries the
  `GITHUB_ACTION_PATH` / `helpers_additional.sh` hook — this code is composite-action-shaped
  already. There are **no secrets** anywhere (pure OIDC), which removes the most painful part of
  reusable-workflow plumbing (`secrets: inherit` threading).
- **The org has done this twice and both LZs already consume it.** Both this repo and ops call
  `dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v0` today.
  The consumption model, release discipline, and contributor muscle memory exist.
- **The stated direction ("offer it to others in the org") only works centralized.** Nobody
  onboards a 1,600-line bash vendoring exercise; they will onboard a documented
  `uses: …/cert-warden.yml@v1` with ~100 lines of caller config.

The honest counterweights, addressed in §7: N=2 consumers today (payoff is modest until #3),
extraction mid-migration adds churn, and a central repo without a named owning team rots into
something *worse* than vendored copies.

---

## 2. What exists today — the extraction surface

### 2.1 Inventory

| Piece | Lines | Generic? | Notes |
|---|---:|---|---|
| `cert-warden.sh` | 961 | ✅ fully | All config via env vars (`AZ_*`, `LE_*`, `CERT_*`). Zero DSB-specifics in code. |
| `monitor.sh` | 226 | ✅ fully | Bot endpoint/audience/alias/thresholds all via env vars. Assumes the Teams-notifier bot API contract (`POST /v1/notify/{alias}`, Adaptive Card) — a DSB-internal but already-shared component. |
| `sweeper.sh` | 209 | ✅ fully | Prefix lists (`TARGET_*`, `PROTECTED_PREFIXES`) overridable; defaults encode the Cert Warden naming scheme, which is part of the product, not the consumer. |
| `selftest.sh` | 105 | ✅ | Hermetic (no Azure/network). Becomes the central repo's CI — and *disappears from consumers entirely*. |
| `helpers.sh` | 40 | ✅ | Byte-identical to `dsb-norge/github-actions` action helpers. |
| `run-locally.sh` | 45 | ✅ | Laptop wrapper; works from a clone of any repo. |
| `cert-warden.yml` | 187 | ⚠️ mixed | Steps (login → checkout → cache/install lego → run → upload artifact) are generic; the **matrix includes** (sub IDs, client IDs, KV/DNS names, runner labels, LE env/email, schedules, `workflow_run` chain) are consumer-specific. |
| `cert-warden-monitor.yml` | 185 | ⚠️ mixed | The run-resolution logic (`workflow_run` vs latest-completed lookup, skip-skipped semantics) is generic and subtle — high value to centralize. Bot config + matrix are consumer-specific. |
| `cert-sweeper.yml` | 92 | ⚠️ mixed | Same split. Note the deliberate shared concurrency group with the warden (`cert-warden-maintain-certificates-<env>`) — a behavioural contract to preserve. |
| `cert-warden-selftest.yml` | 42 | ✅ | Moves wholesale to the central repo. |

Roughly: **~1,600 lines of bash, 100% generic**, and **~500 lines of workflow YAML of which
~60–70% is generic step logic** and the rest is per-LZ configuration that must remain with the
consumer under any strategy.

### 2.2 The two existing consumers differ only in configuration

The ops caller and this repo's caller are structurally the same workflow: same step sequence, same
env-var contract, different matrix values (`tf-ikt-operations-<env>` vs
`tf-app-platform-<env>-infra` runner labels, different subs/UAMIs/KV names, `workflow_run` chained
to "Terraform CI/CD" vs "IAC deploy test"). That is exactly the profile that parameterizes cleanly
into `workflow_call` inputs. There is also a recorded standing preference for this direction:
`docs/cert-warden-migration/phase-3.5-retrospective.md` kept the teams-notifier deploy workflow
byte-identical to ops' "so both can later be promoted to a single org-level reusable workflow."

### 2.3 The internal version contract

`cert-warden.sh` (producer) and `monitor.sh` (consumer) are coupled through the **metrics JSON
schema** and the **artifact naming convention** (`cert-warden-metrics-<env>-<run>-<attempt>`), and
warden/sweeper are coupled through the **KV object naming scheme** (`le-cert-<le-env>-<zone>-pfx`,
`letsencrypt-<le-env>-account-*`, the `-meta` ARI secrets). Today these co-version implicitly
because they live in one repo. Centralization must keep them co-versioned: **one repo, one release
tag covering all three tools** — never separate repos or independent versions per tool.

---

## 3. GitHub platform constraints that shape any design

These are facts, not choices; every strategy has to work within them.

1. **Triggers cannot be centralized.** `schedule`, `workflow_dispatch` inputs, `workflow_run`
   chaining, `concurrency`, `runs-on` selection and the env matrix always live in the *caller's*
   workflow file. Even maximal centralization leaves an irreducible per-consumer caller (~80–120
   lines, almost all static IDs). This is the ceiling on centralization — and it is fine, because
   that residue is exactly the stuff that legitimately differs per LZ.

2. **How shared code reaches the runner differs by mechanism, and it matters for private repos.**
   - A **composite action** is fetched by the Actions runtime via `uses:`; its bundled scripts
     ride along and are reachable via `${{ github.action_path }}`. Access to a *private* actions
     repo is granted by a repo setting ("Accessible from repositories in the organization" /
     enterprise) — **no tokens involved**.
   - A **reusable workflow** brings only its own YAML. If its `run:` steps need scripts, it must
     either `actions/checkout` its own repo (which does **not** go through the Actions access
     mechanism — for a private repo that means provisioning a PAT/App token in every consumer) or
     get the scripts via composite actions (back to the clean path).
   - **Consequence: for a private central repo, composite actions are the only friction-free
     carrier for the bash.** A reusable workflow that only *calls* those actions stays clean.

3. **`uses:` refs are static strings** — no `${{ }}` interpolation. A reusable workflow that calls
   sibling actions must hardcode a ref for them. This is the root of the reference repo's biggest
   quirk: `terraform-ci-cd-default.yml` contains 27 hardcoded `…@v0` action refs, so (a) a
   consumer pinning the workflow at `@v0.21` still gets *floating* `@v0` actions — pinning doesn't
   actually freeze behaviour — and (b) testing a branch requires a documented find/replace
   "dev-tag swap" ritual across the whole file. **Cert Warden can dodge this entirely** because it
   is small: make each action self-contained (zero cross-action `uses:`), and have the reusable
   workflows reference actions at an immutable ref rewritten at release time (or accept the
   rolling-major with eyes open — see §5.2).

4. **Sharing scope depends on placement.** Today's cross-org consumption (private `dsb-infra`
   repos calling `dsb-norge` workflows) works because `dsb-norge/github-actions-terraform` is
   **public**. A **private** repo's workflows/actions are shareable org-wide via a setting, and on
   GitHub Enterprise Cloud there is an enterprise-wide access option (verify DSB's enterprise
   groups both orgs before relying on it). So: private-in-`dsb-infra` covers today's two consumers
   and any future `dsb-infra` LZ; going cross-org private needs the enterprise setting; public
   in `dsb-norge` matches existing convention but publishes the code.

5. **A matrix in the caller fans out over a reusable-workflow call just fine** (`strategy.matrix`
   on the job that `uses:` the workflow). The existing per-env matrix shape survives unchanged;
   `max-parallel: 1` (LE rate-limit hygiene) also stays caller-side.

---

## 4. Strategies

### Strategy 0 — status quo plus a drift guard

Keep vendored copies; add CI that diffs each copy against a designated upstream (or a shared
`git subtree`/`vendir`-style pull).

- **Fix propagation:** manual, per-copy PRs. The double-port of the `set -e` fix is the template
  for every future fix. Effort scales linearly with N consumers.
- **Churn per consumer:** zero when idle; a full review cycle per fix.
- **Risks:** the guard only *detects* drift, it doesn't resolve it; divergence pressure is real
  because copies get locally patched under incident pressure (exactly how ops fell behind).
  A third consumer copies whichever version they found first.
- **Assessment:** cheapest today, most expensive the moment anything needs fixing everywhere.
  Does not serve "offer it to the org" at all. **Reject** as an end-state; it is only defensible
  as "do nothing until Phase 5 lands" (which is the recommended *timing* anyway).

### Strategy A — composite actions only

Central repo ships `cert-warden`, `cert-warden-monitor`, `cert-sweeper` actions (each bundling its
scripts + `helpers.sh`). Consumers keep writing their own full workflows, replacing the inline
steps with `uses: dsb-infra/github-actions-cert-warden/cert-warden@v1`.

- **Fix propagation:** all bash and step logic central. But the *workflow-level* logic that is
  genuinely subtle — the monitor's run-resolution (`workflow_run` payload vs `gh run list`
  fallback, skip-skipped semantics), the lego cache keying, `if: always()` artifact upload, the
  shared concurrency-group contract between warden and sweeper — stays copy-pasted per consumer
  and *will* drift, the same way the scripts did.
- **Churn per consumer:** Renovate bumps one ref per action per release; caller YAML rarely
  changes.
- **Flexibility:** highest — consumers with a weird shape compose the actions freely.
- **Assessment:** necessary but not sufficient. It centralizes the 1,600 lines of bash but leaves
  ~300 lines of load-bearing YAML per consumer. Good floor, wrong ceiling.

### Strategy B — reusable workflows as the only interface

Central repo ships `cert-warden.yml`, `cert-warden-monitor.yml`, `cert-sweeper.yml` (all
`on: workflow_call`, inputs for every per-env value). Consumers have thin callers: triggers +
matrix + one `uses:` line. Scripts reach the runner via one of the mechanisms in §3.2 —
realistically via internal (possibly undocumented) composite actions anyway, or self-checkout
(which forces the repo public or tokens everywhere).

- **Fix propagation:** maximal — step logic, run-resolution, cache keys, artifact contracts all
  central. A release fixes every consumer after a one-line bump.
- **Churn per consumer:** minimal (a ref bump; occasionally a new input).
- **Risks:** the all-or-nothing interface. A consumer whose shape doesn't fit (e.g. wants a
  different artifact retention, an extra step between login and run, or no monitor) needs an
  upstream feature/input for everything — input sprawl is how `terraform-ci-cd-default.yml` got to
  17 inputs and 1,200 lines. Debugging is also one level more indirect for consumers.
- **Assessment:** right default interface, wrong *only* interface.

### Strategy C — hybrid: actions as the unit of logic, packaged reusable workflows on top ⭐

The `dsb-norge/github-actions-terraform` model, minus its self-inflicted quirks:

```
dsb-infra/github-actions-cert-warden        (working name)
├── cert-warden/            action.yml + cert-warden.sh + helpers.sh
├── cert-warden-monitor/    action.yml + monitor.sh + helpers.sh
├── cert-sweeper/           action.yml + sweeper.sh + helpers.sh
├── setup-lego/             action.yml   (go install + actions/cache, LEGO_VERSION input)
├── .github/workflows/
│   ├── cert-warden.yml             on: workflow_call   — login→setup-lego→warden→artifact
│   ├── cert-warden-monitor.yml     on: workflow_call   — login→resolve-run→download→monitor
│   ├── cert-sweeper.yml            on: workflow_call   — login→sweeper
│   └── ci.yml                      selftest + shellcheck + actionlint on PR
└── docs/  (consumer how-to incl. the full identity/KV/network prerequisites per LZ)
```

- Consumers **default to the reusable workflows** (thin caller, one pinned ref per repo).
- Consumers with divergent shapes **drop down to the actions** without forking anything — the
  escape hatch that keeps input sprawl out of the workflows.
- Each action is **self-contained** (its scripts local, `helpers.sh` duplicated per action dir —
  accept the org's known trade-off, enforce identity with a cheap CI check instead of hoping).
- Zero cross-action `uses:` refs inside actions; the reusable workflows are the only place with
  internal refs, handled per §5.2.
- **Fix propagation:** same as B for the default path.
- **Churn per consumer:** same as B.
- **Risks:** two consumption levels to document and keep coherent; slightly more repo machinery.
  Both are bounded and the reference repo proves the org can operate this shape.
- **Assessment: recommended.** It is also the only strategy where the *selftest and future tests
  run once, centrally* while consumers retain composition freedom.

### Strategy D — template/sync distribution (rendered copies pushed by automation)

Central repo is the source of truth; automation (a sync workflow, `copier`, or Renovate-style bot
PRs) regenerates the vendored files in each consumer on release. A runtime-fetch variant (the
`dsb-tf-proj-helpers.sh` `gh api | eval` pattern) also exists in the org.

- **Fix propagation:** automated PRs per consumer per release — review churn for every consumer on
  every release, which is *worse* churn than a Renovate ref bump because the diff is the whole
  file set, not one line.
- **Risks:** consumers can still hand-edit between syncs (drift returns through the side door);
  sync tooling is itself a maintained artifact; runtime-fetch variants have no pinning and an
  availability/supply-chain surface — reject those outright for something that touches production
  certs and Key Vaults.
- **Redeeming quality:** works with zero GitHub sharing configuration and full in-repo
  auditability (some security postures require seeing all executed code in-repo).
- **Assessment:** only preferable if a policy constraint forbids cross-repo `uses:` for this class
  of automation. Otherwise dominated by C.

### Comparison

| Dimension | S0 copies | A actions | B workflows | **C hybrid** | D sync |
|---|---|---|---|---|---|
| Bash fix reaches all consumers | ✗ manual ×N | ✅ ref bump | ✅ ref bump | ✅ ref bump | ⚠️ bot PR ×N |
| Workflow-logic fix reaches all | ✗ | ✗ manual ×N | ✅ | ✅ | ⚠️ bot PR ×N |
| Residual per-consumer YAML | ~500 lines | ~300 lines | ~100 lines | ~100 lines | ~500 lines (generated) |
| Drift risk | high (proven) | medium (YAML) | low | low | medium |
| Blast radius of a bad release | none | opt-in per bump | opt-in per bump | opt-in per bump | bot-PR gated |
| Consumer flexibility | total | high | low | high | total |
| Onboarding LZ #3 | copy 2,100 lines | copy ~300 YAML | ~100-line caller | ~100-line caller | install sync |
| Central testability (selftest/lint) | ✗ ×N | ✅ once | ✅ once | ✅ once | ✅ once |
| Debugging indirection | none | one hop | two hops | one–two hops | none |
| Governance overhead | none | medium | medium | medium | medium + tooling |

---

## 5. Cross-cutting design decisions (they apply to A, B and C)

### 5.1 Placement and visibility

| Option | Reach | Notes |
|---|---|---|
| **`dsb-infra`, private, org-wide Actions access** ⭐ | both current consumers + any future `dsb-infra` LZ | Least friction, nothing published. Blocks `dsb-norge`-org consumers unless the enterprise-wide access setting is available and enabled — check before committing if that matters. |
| `dsb-norge`, public | everyone incl. other orgs | Matches the existing convention (`github-actions`, `github-actions-terraform` are public). The code contains no secrets/IDs (all consumer-side), so publishing is *safe* — it's an org-policy call, not a technical one. Public also trivially enables the self-checkout pattern and community reuse. |
| Inside `dsb-norge/github-actions` (no new repo) | as its host | Rejected: cert-warden's release cadence and reviewers differ from app-CI actions; a shared version line means cert-warden bumps force unrelated consumers to re-pin, and vice versa. Same argument that keeps `github-actions-terraform` separate. |

A dedicated repo is warranted either way: the co-versioning contract (§2.3) wants one tag line
that means exactly "the cert-warden suite."

### 5.2 Versioning and release discipline — deviate from the reference repo deliberately

The reference repo's model (rolling `v0` force-moved on every release, annotated-tag-as-changelog,
27 internal floating refs, dev-tag swap ritual) *works* but produces its three worst quirks. For a
tool that renews production TLS certs, choose the stricter variant:

- **Immutable release tags** (`v1.0.0`, `v1.1.0`…) + GitHub Releases with real changelogs. A
  rolling `v1` major tag *may* be offered, but the documented default for consumers is **pinning
  an exact tag, updated by Renovate**. Both LZ repos already run Renovate with the org's shared
  config; its `github-actions` manager turns every release into a small, reviewable, per-consumer
  PR. This converts "central repo broke both LZs simultaneously overnight" (the rolling-tag
  failure mode — real, because cert-warden runs on `schedule`, not on PRs) into "a bump PR failed
  in one LZ and was not merged elsewhere."
- **Staged rollout by convention:** merge the bump in the least critical consumer first (this
  repo's dev/test matrix), let the scheduled runs prove it, then ops/prod. With Renovate this is
  just merge ordering — no machinery.
- **Internal refs:** the reusable workflows' `uses:` refs to sibling actions are rewritten to the
  release tag by the release script (a 5-line sed in a repo this size), so a consumer pinning
  `cert-warden.yml@v1.2.0` gets *actions* at `v1.2.0` — behaviour actually frozen, unlike the
  reference repo. Branch-testing works by pointing a caller at `@my-branch` and having a tiny CI
  check that internal refs match the tag at release time.
- **Breaking changes** (metrics schema, KV naming, input renames) = major bump + migration note.
  The naming scheme (`le-cert-<le-env>-<zone>-pfx`) is *state* in every consumer's KV and the name
  the AGW reads — treat it as the most breaking-change-averse part of the contract.

### 5.3 What stays in each consumer forever (the irreducible caller)

Per consumer repo, regardless of strategy: triggers (`schedule` crons, `workflow_dispatch` knobs,
`workflow_run` chain naming — note the monitor must take the warden **workflow name** as an input
since names are caller-owned), the env matrix with its IDs (tenant/sub/UAMI client IDs, KV + DNS
RG names, runner labels, LE environment + account email, bot alias/audience), `max-parallel: 1`,
and the concurrency groups. Sketch of the end-state caller (this repo):

```yaml
# .github/workflows/cert-warden.yml (consumer)
on:
  workflow_dispatch:
  schedule: [{cron: "34 4 * * *"}, {cron: "34 16 * * *"}]
  workflow_run: {workflows: ["IAC deploy test"], types: [completed], branches: [main]}
jobs:
  warden:
    strategy: {fail-fast: false, max-parallel: 1, matrix: {…as today…}}
    uses: dsb-infra/github-actions-cert-warden/.github/workflows/cert-warden.yml@v1.2.0
    permissions: {id-token: write, contents: read}
    with:
      environment:        ${{ matrix.environment }}
      runs-on:            ${{ matrix.vars.runs-on }}
      azure-client-id:    ${{ matrix.vars.azure-client-id }}
      # …kv-name, dns-rg, le-environment, le-account-email, tags…
```

Everything the caller carries is static configuration a new LZ *must* provide anyway (it maps 1:1
to their Terraform outputs). A future refinement — generating this block from TF outputs — becomes
*possible* once the interface is pinned, and impossible under the copy model.

### 5.4 CI and testing in the central repo

- **Moves centrally on day one:** `selftest.sh` (already hermetic, already CI-shaped — its
  workflow transplants almost verbatim), plus `shellcheck` and `actionlint`. Consumers *lose* a
  workflow (`cert-warden-selftest.yml` is deleted from every consumer) — a rare centralization
  that shrinks consumer surface immediately.
- **The e2e gap is structural and shared by every strategy:** a real run needs an Azure DNS zone,
  a PE-only KV, a UAMI with a `main`-ref FIC and a VNet-integrated self-hosted runner. The central
  repo cannot reproduce that hermetically, and the reference repo has the same gap (its
  action-tests are unit-level; the ARG_MAX class of bug ships to consumers). Accept it and
  compensate with the staged Renovate rollout (§5.2): the dev/test matrix in this repo *is* the
  canary, on a twice-daily schedule, with the monitor alerting to Teams when a release breaks
  renewal — a better e2e harness than anything a sandbox could offer. Optionally, grow a
  LE-staging integration job in a sandbox sub later; do not gate the extraction on it.

### 5.5 Governance

Name an owning team in CODEOWNERS and agree the review bar *before* offering it org-wide. This is
the single biggest determinant of whether centralization nets positive: a central repo that stops
being maintained is worse than copies, because consumers assume pinned = maintained, and a
security-relevant fix (this code holds LE account keys and writes to production KVs) now has a
bottleneck. The flip side: the same sensitivity is an argument *for* one well-reviewed
implementation over N casually-diverging ones.

---

## 6. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Bad release breaks cert renewal in all consumers at once | High | Exact-tag pinning + Renovate PRs (no floating major as default); staged merge order; monitor already pages on the *symptom* (lifetime fraction), giving days-to-weeks of buffer — renewal failures are slow-burning by design. |
| Warden/monitor/sweeper version skew across the artifact + KV-naming contracts | Medium | One repo, one tag for the suite; consumers pin a single version for all three callers (document: bump together). |
| Central repo goes unowned | High | CODEOWNERS + named team up front; if no team will own it, prefer S0 and *say so* rather than half-centralizing. |
| Input sprawl turns the reusable workflows into a second `terraform-ci-cd-default.yml` | Medium | The hybrid escape hatch: divergent consumers drop to actions; hold a hard line on workflow inputs (config, not behaviour flags). |
| Private-repo sharing scope surprises (cross-org consumer appears) | Low | Decide placement with §5.1 eyes open; moving private→public later is trivial for this code (no secrets); the reverse is not. |
| Debugging indirection for consumers (failure in a pinned workflow they don't own) | Low–Med | Small, single-purpose workflows (not one mega-workflow); scripts keep their verbose grouped logging; `run-locally.sh` still works from a clone. |
| Extraction churn collides with Phase 5 prod rollout | Medium | Sequence it: finish Phase 5 with vendored copies (they are proven and prod is the wrong place to debut an interface), then extract, then onboard ops as the second consumer — which back-delivers ARI/metrics/monitor/sweeper to ops as a side effect. |
| `workflow_run` name coupling breaks silently if a consumer renames a workflow | Low | Make names explicit inputs; document the contract in the consumer how-to. |

---

## 7. Should it be centralized? — the balanced answer

**Yes.** The question is really "is N=2-going-on-3 enough to pay the governance overhead," and the
tie-breakers all point the same way: drift already cost real money (ops runs a materially worse
Cert Warden today — no ARI, no metrics, no monitoring, no sweeper, lego v4); the maintenance
driver is external protocol/tooling churn that recurs regardless of consumer count; the interface
is already clean (env-var scripts, no secrets, config-only callers); and the org demonstrably
operates this model. The copy model's only advantage — zero coupling — is a liability the moment
you *want* propagation, which is exactly what "offer it to the org" means.

**Shape: Strategy C** (composite actions as the logic carrier + packaged reusable workflows), in a
**dedicated repo**, defaulting to **`dsb-infra` private with org-wide Actions access** (go public
in `dsb-norge` only as a deliberate policy choice — the code is publishable), with **immutable
tags + Renovate-driven exact pinning** and a staged dev→prod-LZ rollout convention, explicitly
avoiding the reference repo's floating internal refs and rolling-tag-as-default.

**Timing:** after Phase 5. Extracting mid-migration would freeze the interface at its
highest-churn moment and make prod's first Cert Warden run depend on a brand-new distribution
mechanism. The natural sequence is: Phase 5 lands vendored → extract → this repo becomes consumer
#1 (a behaviour-neutral swap, verifiable step-for-step against the vendored runs) → ops becomes
consumer #2 and inherits three phases of improvements — which is both the payoff and the proof
that the interface generalizes, *before* offering it to a third LZ.

### Open questions for the humans

1. Who owns the central repo (team, review bar, on-call expectations for a bad release)?
2. Private-in-`dsb-infra` or public-in-`dsb-norge`? (Does the DSB enterprise setting for
   cross-org private sharing exist/matter?)
3. Does the monitor's Teams-notifier bot contract count as part of the product (inputs assume the
   DSB bot API) or should notification be pluggable? (Suggest: keep the bot contract — it is
   itself a shared org component — and revisit only when a consumer without the bot appears.)
4. Should the sweeper ship enabled-by-schedule or dispatch-only by default for new consumers?
   (Suggest: dispatch-only + `LOG_ONLY` until each consumer validates, mirroring how this repo
   rolled it out.)
