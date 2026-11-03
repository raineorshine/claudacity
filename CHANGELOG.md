# Changelog

## [1.0.0](https://github.com/raineorshine/claudacity/compare/v0.2.6...v1.0.0) (2026-11-03)

* fix: doctor header says claudacity; release from this mac (1ed0f20)
* feat: cly login, renew outgoing login at switch (adb3e3a)
* feat: share mirrors user-scoped mcp servers (b47cc7f)
* feat: live progress line for slow switch steps (69b5b1f)
* feat: header row and 5h usage in cly pick (e69d5fc)
* fix: a switch keeps each profile on its own account (3897910)
* feat: keep claude code logins alive across switches (06ff3b2)
* feat: show the 5h reset in cly usage as time left (132278d)
* feat: re-sync claude.ai plugin marketplaces on every switch (2627432)
* feat!: rename csw to claudacity (09722b0)
* feat: csw envs sync copies cloud environments across profiles (db299f1)
* feat: email before usage in csw pick, readable reset times (c487653)
* feat: show weekly usage in csw pick (3374dc7)
* feat: carry open sessions on every switch by default (a7ffe2f)
* fix: refresh a saved login's plan from the account's current plan (06353f2)
* feat: carry Desktop settings and MCP servers across switches (ce61fe8)
* fix: show a missing usage window as a placeholder, not -1% (b5503c5)
* fix: reopen Claude Desktop after switching to its live profile (e660ebc)
* feat: color csw usage percentages by how full they are (39f7c36)
* feat: mark the active profile in csw usage with a leading arrow (#5) (9ccafd5)
* feat: move work to the next account automatically when weekly usage runs out (#2) (efbcbf1)
* feat: show account email next to profile name in picker (f75a2ec)
* feat: sync plugins across shared profiles (ad2b02b)
* feat: share local skills across profiles (7ddd5b9)
* fix: hide desktop session token in whoami (c64cd79)

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
