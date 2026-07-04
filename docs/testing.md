# Testing — the implementation spec

How this repo is tested, how to write tests, and the catalogue of bash-on-runner pitfalls each
guarded by a regression test. The guiding rule, in one line:

> **Unit-test logic, integration-test flows, self-test packaging; mock only at the declared
> boundary — and make the mock validate what it receives.**

## 1. The layer model

| Layer | What runs | Where | Gate |
|---|---|---|---|
| L0 static | shellcheck, shfmt, actionlint, yamllint, zizmor, pinact, commitlint, private-reference guard | `ci.yml` | required |
| L1 unit | bats suites over sourced functions / scripts-as-processes | `tests/unit/` | required |
| L2 integration | the real scripts + real lego + real ACME (Pebble) | `tests/integration/` | required |
| L3 packaging | composite actions via `uses: ./`, asserted outputs | `ci.yml` (`action-smokes`, `integration-tests`) | required |
| L3b remote-fetch | the suite consumed at a preview tag through GitHub's remote `uses:` path | `preview-consume.yml`, dispatched by `pr-preview.yml` | required |
| L4 canary | staged consumer rollout via version-bump PRs | consumer repos | consumer-side |
| coverage | kcov over L1 (advisory — see §6) | `ci.yml` | warn-only |

What is deliberately NOT tested in CI: real Azure and real Let's Encrypt. That risk is held by
the consumers' staged rollout (bump PRs merged dev-first) and their monitoring — and optionally
the caller-side staging canary (see `reference-usage-canary.md`).

## 2. The mock boundary (L2)

| Dependency | Real or fake | How |
|---|---|---|
| ACME protocol + issuance | **real** | Pebble `-strict` (`tests/harness/docker-compose.pebble.yml`) |
| lego (client, ARI, retries) | **real** | the pinned production binary |
| DNS-01 challenge write | seam | lego `exec` provider → `challtestsrv-hook.sh` → challtestsrv |
| DNS propagation check | **real** (test DNS) | `--dns.resolvers 127.0.0.1:8053` (challtestsrv) |
| Delegation check (`dig NS`) | **real** (test DNS) | CoreDNS zone files (challtestsrv can't serve NS) |
| PFX handling | **real** | production `openssl` code paths |
| `az` CLI / Key Vault | **fake** | `tests/harness/az-shim/az` (stateful; see below) |
| Teams bot | **fake** | `tests/harness/bot-sink/sink.py` (asserting HTTP sink) |

**The shim validates at the boundary**: its `keyvault certificate import` parses the PFX with
real openssl (password included), extracts the real SANs/expiry, verifies the chain against
Pebble's per-boot root (`CW_TEST_VERIFY_CHAIN_ROOT`), and re-packages the backing secret
**password-less** — because that is what real Key Vault does, and the renewal path depends on
it. When a script grows a new `az` call, the shim fails loudly (`unhandled command`) so
extending it is a conscious, reviewed act.

**No rate limits anywhere in CI**: Pebble explicitly implements none ("It is not presently an
appropriate tool for testing that your client handles Boulder/Let's Encrypt rate limits
correctly" — Pebble README). A real LE `rateLimited` error is therefore untestable here, but
its *handling* is the generic failed-issuance path, which is covered. Real LE limits apply
only where real LE is touched: consumer runs and the staging canary.

**Determinism**: `PEBBLE_VA_NOSLEEP=1`, `PEBBLE_WFE_NONCEREJECT=0`, `PEBBLE_AUTHZREUSE=0`
(authz reuse would let scenarios dodge injected DNS faults). A dedicated chaos scenario with
nonce rejection enabled is a known gap (tracked; requires a second Pebble instance or a
restart, since the knob is boot-time).

## 3. Writing unit tests (L1)

- bats-core + bats-assert/support (installed by `bats-core/bats-action` in CI; locally clone
  them and `export BATS_LIB_PATH`). Load `tests/test_helper.bash`.
- The warden is **sourced** (its source-guard means no side effects); call `loadConfig` after
  exporting config (`export_dummy_warden_env`), then exercise functions directly.
- monitor/sweeper are **run as processes** (their production invocation); assert on output,
  exit code, `GITHUB_STEP_SUMMARY`/`GITHUB_OUTPUT` files pointed at tmp paths.
- Mock external commands with PATH shims in `$BATS_TEST_TMPDIR/bin` (see the sweeper suite's
  inline `az` stub — fixtures **captured from real CLI output**, never hand-written).
- Suite-top shellcheck directives (`SC1090,SC2154,SC2034,SC2030,SC2031`) are the accepted
  relaxation for bats suites; nothing else gets blanket disables.
- bats gotchas that already bit or will: `run` never fails a test by itself (assert on
  status/output); `run cmd | grep` pipes the wrapper, not the command; background processes
  must not inherit fd 3 (see the sink launch in the e2e suite).

## 4. Writing integration scenarios (L2)

`tests/integration/warden-e2e.bats` is the template. Structure:

- `setup_file` brings up the compose stack (skips cleanly when docker/lego are absent),
  fetches Pebble's **per-boot** issuance root from `:15000/roots/0` (the static
  `pebble.minica.pem` is only the WFE TLS trust — two different anchors!), and seeds the shim
  state dir.
- Scenarios **build on each other in file order** (shared state dir = the "vault"); the
  metrics file is file-scoped so later scenarios evaluate earlier scenarios' output.
- Fault injection via challtestsrv's management API (`:8055`): `set-txt`, `clear-txt`,
  `set-servfail`, `clear-servfail`, plus `dns-request-history` to assert what was queried.
- Every seam override is in one place (`setup()`); see [contracts.md](contracts.md) §CW_*.

The metrics-survive-partial-failure scenario (e2e-4) is the suite's reason to exist: the
incident class where one failed zone aborted the run before metrics were written. Do not
weaken it.

## 5. The pitfalls catalogue

Each entry: the trap, and where its regression test lives. When you find a new one, add the
row AND the test — that's the review bar.

| # | Pitfall | Guarded by |
|---|---|---|
| P-1 | `((count++))` returns 1 when the result is 0 → instant death under `set -e`. Use `x=$((x+1))`. **Bit this suite in production** (the metrics-loss incident) | `tests/unit/warden.bats` (child-process probe), e2e-4 |
| P-2 | `$( )` doesn't propagate a `set -e` abort (so probes must run in a child *process*); fixed by `shopt -s inherit_errexit` in every script | `tests/unit/warden.bats` |
| P-3 | `local var=$(cmd)` masks `cmd`'s failure — declare and assign separately | review bar |
| P-4 | errexit is disabled inside any function used as a condition (`if f`, `f \|\| x`) | review bar |
| P-5 | unspecified step shell on Linux = `bash -e` **without pipefail**; always `shell: bash` (composite steps require it explicitly anyway) | actionlint + review |
| P-6 | `--noprofile --norc`: no interactive-shell PATH/env on self-hosted runners | docs |
| P-7 | `pipefail` × `grep`: no-match exit 1 can be a valid answer — handle explicitly | review bar |
| P-8 | step outcome = last command's exit code; a trailing `\|\| log-warn` greens a failure | review bar |
| P-9 | `set -o allexport` + large values → 128 KiB/var / ~2 MiB ARG_MAX exec failures; big payloads go to `$RUNNER_TEMP` files | review bar |
| P-10 | fixed heredoc delimiters in `GITHUB_OUTPUT` are injectable (CVE-2022-35954); use random delimiters | `lib/helpers.bash` + `tests/unit/helpers.bats` |
| P-11 | stdout lines matching `::command::` are executed by the runner — guard untrusted multi-line output with `::stop-commands::` | review bar |
| P-12 | `${{ }}` interpolation into `run:` bodies = template injection; env-var indirection only | zizmor (`template-injection`) |
| P-13 | composite actions: no `INPUT_*` autoexport; map inputs via `env:` explicitly | action shims |
| P-14 | CRLF from Windows-side edits (`$'\r': command not found`) | `.gitattributes` |
| P-15 | assoc-array keys containing dashes must be quoted: `${opt["vault-name"]}` — unquoted parses as arithmetic. **Bit the az shim** | az shim + shfmt |
| P-16 | "next arg starts with `--` means boolean flag" heuristics corrupt PEM values (`-----BEGIN…`). **Bit the az shim** | e2e-2 (account round-trip) |
| P-17 | lego stores accounts under `accounts/<host>[_<port>]` derived from the directory URL — derive paths the same way | e2e-1/e2e-2 |
| P-18 | real KV strips the import password: cert-backing secrets come back as password-less PKCS#12 (and Go's pkcs12 needs `-legacy` under OpenSSL 3) | az shim + e2e-2 |
| P-19 | Pebble authz reuse (default 50%) lets repeat issuances skip challenges — fault injection silently misses | compose (`PEBBLE_AUTHZREUSE=0`) |
| P-20 | kcov's PS4/xtrace instrumentation pollutes bats `run` captures → assertions fail only under coverage | coverage job (advisory by design) |
| P-21 | hosted-image drift (az/jq/openssl versions) and missing kcov in Ubuntu 24.04 | pinned tool versions; coverage on ubuntu-22.04 |

## 6. Coverage policy

kcov + a local `jq` threshold, **advisory**: kcov's bash parser has heredoc blind spots and
the P-20 interaction, so the number is a trend signal — the scenario tables above are the
completeness instrument. The job never fails the build; promote to a hard gate only if it
proves stable over time.

## 7. Running locally

```bash
# unit
export BATS_LIB_PATH=~/tools/bats-libs   # clones of bats-support/bats-assert
bats tests/unit

# integration (docker + lego v5 on PATH)
bats tests/integration

# everything CI runs statically
shellcheck ... && shfmt -d . && yamllint --strict . && actionlint && zizmor . && pinact run --check
```
