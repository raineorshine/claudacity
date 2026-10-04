# Changelog

## [1.0.0](https://github.com/raineorshine/claudacity/compare/v0.2.6...v1.0.0) (2026-10-04)


### ⚠ BREAKING CHANGES

* rename csw to claudacity

### Features

* carry Desktop settings and MCP servers across switches ([ce61fe8](https://github.com/raineorshine/claudacity/commit/ce61fe858e9812a5c8540ffa52c52fc5bf06006e))
* carry open sessions on every switch by default ([a7ffe2f](https://github.com/raineorshine/claudacity/commit/a7ffe2f6814736937e7b701e83c6f8bee6651bfa))
* color csw usage percentages by how full they are ([39f7c36](https://github.com/raineorshine/claudacity/commit/39f7c363dda07962b079fc56620d9a501f7d624f))
* csw envs sync copies cloud environments across profiles ([db299f1](https://github.com/raineorshine/claudacity/commit/db299f14243c972c0d9cef897eed442269e7b70f))
* email before usage in csw pick, readable reset times ([c487653](https://github.com/raineorshine/claudacity/commit/c487653d71802bd2108bf3b4b4754e6b935a0548))
* mark the active profile in csw usage with a leading arrow ([#5](https://github.com/raineorshine/claudacity/issues/5)) ([9ccafd5](https://github.com/raineorshine/claudacity/commit/9ccafd58b83650a806dc88f28cab0435dfb62871))
* move work to the next account automatically when weekly usage runs out ([#2](https://github.com/raineorshine/claudacity/issues/2)) ([efbcbf1](https://github.com/raineorshine/claudacity/commit/efbcbf1384c6759e8adddfe6adfcdb644abdaf5c))
* re-sync claude.ai plugin marketplaces on every switch ([2627432](https://github.com/raineorshine/claudacity/commit/2627432c3a4c6cfadf11330ef64ed31e075bb20a))
* rename csw to claudacity ([09722b0](https://github.com/raineorshine/claudacity/commit/09722b0c1857cc70db3846f057b964f138c64c0e))
* share local skills across profiles ([7ddd5b9](https://github.com/raineorshine/claudacity/commit/7ddd5b9aa6e4f20c721258f70ad2218f705f0952))
* show account email next to profile name in picker ([f75a2ec](https://github.com/raineorshine/claudacity/commit/f75a2ecd6bfd58b7aa40f2e7cc67ee0674bdb3c5))
* show weekly usage in csw pick ([3374dc7](https://github.com/raineorshine/claudacity/commit/3374dc7d451d30696c20ded6483abf136789c5e4))
* sync plugins across shared profiles ([ad2b02b](https://github.com/raineorshine/claudacity/commit/ad2b02b3da230ce1283529b31191f9d80bcec6c9))


### Bug Fixes

* hide desktop session token in whoami ([c64cd79](https://github.com/raineorshine/claudacity/commit/c64cd79881b7fa58335f222a3bfa033d7b9d2b10))
* refresh a saved login's plan from the account's current plan ([06353f2](https://github.com/raineorshine/claudacity/commit/06353f201b0dd714da894df468e01c0de462ba5e))
* reopen Claude Desktop after switching to its live profile ([e660ebc](https://github.com/raineorshine/claudacity/commit/e660ebcc3735fc76e26d10529d76ddb57cadfc54))
* show a missing usage window as a placeholder, not -1% ([b5503c5](https://github.com/raineorshine/claudacity/commit/b5503c535944fe504a03f0c243b39d77438373b0))

## [0.2.6](https://github.com/mtxr/claude-switch/compare/v0.2.5...v0.2.6) (2026-06-11)


### Bug Fixes

* bump VERSION to 0.2.5 and wire release-please to src/main.zig ([#12](https://github.com/mtxr/claude-switch/issues/12)) ([cd4210e](https://github.com/mtxr/claude-switch/commit/cd4210e4ed6d786dd9df11867c590ad8d08cb192))

## [0.2.5](https://github.com/mtxr/claude-switch/compare/v0.2.4...v0.2.5) (2026-06-11)


### Bug Fixes

* correct release asset name and add --verbose flag to update ([#10](https://github.com/mtxr/claude-switch/issues/10)) ([19091a6](https://github.com/mtxr/claude-switch/commit/19091a6af3c34b8f89787806fc48a03d717891e9))

## [0.2.4](https://github.com/mtxr/claude-switch/compare/v0.2.3...v0.2.4) (2026-06-11)


### Bug Fixes

* build arch-specific binaries in release workflow ([#8](https://github.com/mtxr/claude-switch/issues/8)) ([d81d617](https://github.com/mtxr/claude-switch/commit/d81d6172893d26198badcba8b1c9e6ce4b380220))

## [0.2.3](https://github.com/mtxr/claude-switch/compare/v0.2.2...v0.2.3) (2026-06-10)


### Bug Fixes

* use native runners per arch to fix sqlite3 cross-compilation ([#6](https://github.com/mtxr/claude-switch/issues/6)) ([e63cb60](https://github.com/mtxr/claude-switch/commit/e63cb60e6b3df52127b9a9b61df758198ae9a004))

## [0.2.2](https://github.com/mtxr/claude-switch/compare/v0.2.1...v0.2.2) (2026-06-10)


### Bug Fixes

* correct release-please tag format and build trigger ([#4](https://github.com/mtxr/claude-switch/issues/4)) ([51509d2](https://github.com/mtxr/claude-switch/commit/51509d218c6e785322e9c72fce3516570cc342bd))
* use-after-free in profile switch + doctor command + background update check ([#1](https://github.com/mtxr/claude-switch/issues/1)) ([1cf109e](https://github.com/mtxr/claude-switch/commit/1cf109e89d6654c4a596e01110750fbd44868282))

## [0.2.1](https://github.com/mtxr/claude-switch/compare/csw-v0.2.0...csw-v0.2.1) (2026-06-10)


### Bug Fixes

* use-after-free in profile switch + doctor command + background update check ([#1](https://github.com/mtxr/claude-switch/issues/1)) ([1cf109e](https://github.com/mtxr/claude-switch/commit/1cf109e89d6654c4a596e01110750fbd44868282))
