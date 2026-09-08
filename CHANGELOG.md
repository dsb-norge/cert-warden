# Changelog

## [1.1.1](https://github.com/dsb-norge/cert-warden/compare/v1.1.0...v1.1.1) (2026-09-08)


### Bug Fixes

* **deps:** bump azure/login to v3.0.2 ([d0f1b43](https://github.com/dsb-norge/cert-warden/commit/d0f1b436ccfc210fb0efc02b84429d360acb88ad))
* **deps:** bump lego to v5.4.1 ([47691b3](https://github.com/dsb-norge/cert-warden/commit/47691b3f065bd74545a215dd42f493f4cfed2abe))

## [1.1.0](https://github.com/dsb-norge/cert-warden/compare/v1.0.4...v1.1.0) (2026-09-07)


### Features

* **actions:** budget inputs take none | unlimited | a number ([96a991d](https://github.com/dsb-norge/cert-warden/commit/96a991d96da48c9c6e614031dfbbffc111495fdf))
* **actions:** expose max-new-issuance-per-run ([7860ec3](https://github.com/dsb-norge/cert-warden/commit/7860ec37fef9e8abbfbbde778b0e6b895f321ead))
* **actions:** expose the renewal cap on the warden action and workflow ([a42be57](https://github.com/dsb-norge/cert-warden/commit/a42be5709b53fe2ba0aef685942d71ade00ff767))
* **lib:** share one definition of "due" between the warden and the monitor ([ba2cdd6](https://github.com/dsb-norge/cert-warden/commit/ba2cdd6d70690fca13bbf667d00fb62a1f6475eb))
* **monitor:** report the numbers that move during a drain ([2207448](https://github.com/dsb-norge/cert-warden/commit/220744807e30359236c044ea3a31ec7b98e1b979))
* **warden:** budget renewals and first issuance separately ([97ab6ea](https://github.com/dsb-norge/cert-warden/commit/97ab6ea5b44684175cb557d3d815e4bb99909c88))
* **warden:** budgets take none | unlimited | a number, and reject 0 ([463082d](https://github.com/dsb-norge/cert-warden/commit/463082dbf533f222f20c4b35d66628d7007c6fd6))
* **warden:** cap the mutating certificate actions per run ([30fadd0](https://github.com/dsb-norge/cert-warden/commit/30fadd063cc15dd47dd5e06bc406c247ddce4eff))
* **warden:** warn when a renewal cap cannot drain before the monitor alerts ([8c174c0](https://github.com/dsb-norge/cert-warden/commit/8c174c035639bd26b16ffd167365d3cf376d3b16))


### Bug Fixes

* **ci:** make a preview commit safe to pin ([43cb74d](https://github.com/dsb-norge/cert-warden/commit/43cb74d7a21111c8983b8e63e4adb9ac440cf5b3))
* **ci:** pin preview refs to a self-referential per-push tag ([1183004](https://github.com/dsb-norge/cert-warden/commit/11830045c74ce77ac8c684d0dcc9490a0984f199))
* **warden:** size the undersized-cap advisory from due renewals only ([c2ab97a](https://github.com/dsb-norge/cert-warden/commit/c2ab97a608e7f29d59f037ea4ef2158213739b21))

## [1.0.4](https://github.com/dsb-norge/cert-warden/compare/v1.0.3...v1.0.4) (2026-09-01)


### Bug Fixes

* **monitor:** report UNKNOWN instead of a false cert alert when nothing was evaluated ([898c609](https://github.com/dsb-norge/cert-warden/commit/898c609b55f2bb85879c51c4b86a832eb0496830))
* **monitor:** stop alerting on a GitHub API blip as if it were a certificate finding ([#28](https://github.com/dsb-norge/cert-warden/issues/28)) ([4ab946d](https://github.com/dsb-norge/cert-warden/commit/4ab946d2ea84f3b5300b98c3d28b4fbd42aad641))
* **monitor:** tell a dead API apart from an empty answer when resolving the run ([ec19049](https://github.com/dsb-norge/cert-warden/commit/ec1904961413788ff22d74787c981addd2eed2c7))

## [1.0.3](https://github.com/dsb-norge/cert-warden/compare/v1.0.2...v1.0.3) (2026-08-26)


### Bug Fixes

* **monitor:** default warn threshold below the ARI renewal point ([3ba1edc](https://github.com/dsb-norge/cert-warden/commit/3ba1edcf5f31461c091d1100c23fba344561455c))
* **monitor:** default warn threshold below the ARI renewal point ([#24](https://github.com/dsb-norge/cert-warden/issues/24)) ([f07d911](https://github.com/dsb-norge/cert-warden/commit/f07d911f74eb571837c9c2c6ff9940b531cf852a))

## [1.0.2](https://github.com/dsb-norge/cert-warden/compare/v1.0.1...v1.0.2) (2026-08-13)


### Bug Fixes

* **deps:** bump lego to v5.3.1 ([c450f23](https://github.com/dsb-norge/cert-warden/commit/c450f2346c92af57ad5d3294019c9126b287f570))

## [1.0.1](https://github.com/dsb-norge/cert-warden/compare/v1.0.0...v1.0.1) (2026-07-04)


### Bug Fixes

* emit GITHUB_OUTPUT via set-output; regression-test machine-clean emission ([cdf3f83](https://github.com/dsb-norge/cert-warden/commit/cdf3f83eb62c02ca2aae03d256594073ab1cef6d))
* GITHUB_OUTPUT emission via set-output + machine-clean regression tests ([1526cf9](https://github.com/dsb-norge/cert-warden/commit/1526cf9afd139720646286795a918b222a4aba0d))

## 1.0.0 (2026-07-04)


### Features

* add composite actions and reusable workflows ([10eed6e](https://github.com/dsb-norge/cert-warden/commit/10eed6e8f9b7e3b77adcdab9b917ecefd6996424))
* add CW_DIG_ARGS seam and derive lego account paths from the ACME directory URL ([3a1ef5a](https://github.com/dsb-norge/cert-warden/commit/3a1ef5a553ac00a2e886d07a59e6ebd6210574a9))
* port cert-warden scripts with library-mode refactor and test seams ([16c7245](https://github.com/dsb-norge/cert-warden/commit/16c72455ed061949cbd34eeb30c42c171a0effab))


### Bug Fixes

* harden failure paths found by adversarial review ([1e22f76](https://github.com/dsb-norge/cert-warden/commit/1e22f760e40fafa272ff942ce400b68ec9bf995c))
* harden failure paths found by adversarial review ([0f9bd6e](https://github.com/dsb-norge/cert-warden/commit/0f9bd6e2b37aa98386a76204b5d88fa53ff0f932))
* push preview tags with the release App token ([347883d](https://github.com/dsb-norge/cert-warden/commit/347883d8b27b6b956ae00fd70c8301380cf38a11))
