# Vendored bats helper libraries

Committed copies of the two bats helper libraries the suites load — deliberately vendored,
not downloaded at test time.

**Why vendored:** these used to be fetched in CI by `bats-core/bats-action`, which downloads
GitHub tarballs **by mutable tag name with no checksum**. A moved tag in any of those upstream
repos would have delivered arbitrary bash into CI with no visible diff here — bypassing the
repo's SHA-pin discipline. The libraries are tiny, pure bash, and effectively frozen upstream
(the consumed tags date from 2016 and 2022), so committing them removes the runtime download,
the checksum machinery, and a cache dependency in one move. Review happens once, at vendor
time, in a normal PR diff. (bats-core itself — the test *runner* — is still installed at CI
time, but by commit SHA with cryptographic verification: see `scripts/ci/install-bats.sh`.)

| Library | Upstream | Vendored tag | Commit |
|---|---|---|---|
| bats-support | github.com/bats-core/bats-support | v0.3.0 | `24a72e14349690bcbf7c151b9d2d1cdd32d36eb1` |
| bats-assert | github.com/bats-core/bats-assert | v2.1.0 | `78fa631d1370562d2cd4a1390989e706158e7bf0` |

Only `load.bash`, `src/` and `LICENSE` are vendored; upstream docs and self-tests are
omitted. `bats-file` is not vendored because no suite loads it.

**Licensing:** both libraries are **CC0 1.0 Universal** — a public-domain dedication, so
redistribution here (a public MIT repo) is unconditionally permitted and attribution is not
legally required. We keep the upstream `LICENSE` files and in-file dedication headers
byte-identical anyway, and this README records provenance — more than CC0 asks, deliberately.
(bats-core itself is MIT but is *not* vendored — CI fetches it at run time, so this repo
never redistributes it.)

**Re-vendoring** (rarely needed — upstream is dormant): pick the new tag, resolve its commit
(`gh api repos/bats-core/<lib>/commits/<tag> --jq .sha`), then fetch **over the git protocol
at that commit** (`git init && git fetch --depth 1 <url> <sha> && git checkout <sha>`) — git
verifies the object hashes, which a tarball download does not. Copy `load.bash` + `src/` +
`LICENSE` over the directory here, update the table above, and read the diff — the diff
review is the supply-chain control. (Verification of the current copies: `diff -r` against
such a fetch-by-commit clone came back byte-identical, 2026-08-14.)
