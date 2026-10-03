# claude-switch (csw)

A Zig 0.16 CLI for macOS that swaps Claude Desktop and Claude Code between saved accounts, and can move open work to the next account when the active one runs out of weekly usage. This checkout is Raine's fork (`raineorshine/claude-switch`); upstream is `mtxr/claude-switch`. Raine is the fork's only user and upstream is inactive, so neither constrains a change: change a default or remove a flag outright, with no compatibility alias or deprecation path.

## Gates

- `zig build`, `zig build -Doptimize=ReleaseSmall` and `zig build test` must pass. CI runs the same three, but Actions have not run on the fork, so the local run is the gate.
- Judge a test run by its exit code and `Build Summary`. An existing Desktop test prints `❌  Cookies DB não encontrado` and a `failed command:` line on every passing run.
- `csw handoff --dry-run` is the safe end-to-end smoke. It still refreshes expired saved logins, which writes the rotated login to the Keychain.

## Shipping

The [`ship`](.claude/skills/ship/SKILL.md) skill lands a branch on `origin/main` (squashed, no PR) and rebuilds the installed `~/.local/bin/csw` from main, then archives the session. It runs only when the user asks, or invokes [`ship-at-end`](.claude/skills/ship-at-end/SKILL.md) to implement a change and ship it once it looks good. `📦 ` means the three gates pass on the branch; `🚀 ` means the push landed.

## Working rules

- Never run a real switch, carry-over or cloud continuation against the user's profiles to test something. Build the case in temp directories; the first real run is the user's.
- Reading saved logins (even hashed, to compare them) or calling Anthropic's API with them, rewriting `~/.claude.<profile>.json`, writing Desktop's session records, teleporting cloud sessions, and reading the contents of files in Desktop's data directory (`claude_desktop_config.json` included) are blocked by auto mode until the user approves. Listing that directory is allowed; for a config's shape, hand the user a keys-only `jq` command (`jq -r '.preferences | keys[]'`). Ask before relying on them, or hand the user a script to run.
- Before switching or handing off, check that each profile holds its own account (`csw whoami`, `csw usage`). A `claude auth login` run under the wrong profile gets saved over that profile's login by the next switch; repair it first (`docs/claude-internals.md`, Logins).
- The installed `~/.local/bin/csw` is built from `main` by `ship`, so it lacks whatever this branch adds. Use this checkout's `zig-out/bin/csw`.
- One tool refreshes a given saved login. A second one (for example `claude-swap`) rotates the refresh token out from under csw and forces a fresh sign-in.
- `csw usage` colors only a terminal (`isatty`, `NO_COLOR` off). Output from the Bash tool or the chat's `!` prefix is captured, so it shows no colors; check colors in the app's Terminal panel.
- Secrets never go in process arguments: requests go through `exec.run` with the request on stdin (`src/http.zig`). `std.process.run` always ignores stdin in Zig 0.16, so piping needs `std.process.spawn` with `.stdin = .pipe` (`src/exec.zig`).

## Zig tests

- Tests that spawn a process use `std.testing.io`; `std.Options.debug_io` fails the spawn with `OutOfMemory`.
- Code reached from a test must not write to stdout: the test runner speaks to the build server over stdout, and the run hangs with no error. Guard prints with `builtin.is_test`.
- External effects in orchestration code go through an injected interface (`handoff.Effects`) so ordering is tested with fakes.

## Docs

- `docs/claude-internals.md` — how Claude Desktop, Claude Code and Anthropic's OAuth endpoints behave where csw depends on them: login refresh and rotation, the usage and cloud-session APIs, Desktop's session store, unattended CLI runs, launchd quirks.
- `docs/plans/` — unified plans; `2026-09-27-0845-feat-nightly-account-handoff-plan.md` holds the product decisions behind `csw handoff` (why no request proxy, what moves and what stays).
