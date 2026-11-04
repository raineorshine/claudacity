# claudacity (`cly`)

A Zig 0.16 CLI for macOS that swaps Claude Desktop and Claude Code between saved accounts, and can move open work to the next account when the active one runs out of weekly usage. This checkout is `raineorshine/claudacity` (`origin`), a standalone repo that grew out of Raine's fork `raineorshine/claude-switch` (remote `fork`, where it was `csw`) of `mtxr/claude-switch` (`upstream`). Raine is its only user and upstream is inactive, so neither constrains a change: change a default or remove a flag outright, with no compatibility alias or deprecation path. Existing on-disk or Keychain data that a change renames moves by a one-off script handed to the user, never by migration code committed to the repo.

## Gates

- `zig build`, `zig build -Doptimize=ReleaseSmall` and `zig build test` must pass. There is no CI: the GitHub account has no Actions minutes, so nothing here may rely on Actions, and the local run is the gate.
- Judge a test run by its exit code; `zig build test` prints `Build Summary` only on a failure or with `--summary all`. An existing Desktop test prints `❌  Cookies DB não encontrado` and a `failed command:` line on every passing run.
- Run each gate as its own background command and read its output file: compiling `zig build test` alone takes about a minute, so a chain of gates outlasts the Bash tool's foreground timeout.
- `claudacity handoff --dry-run` is the safe end-to-end smoke. It still refreshes expired saved logins, which writes the rotated login to the Keychain.
- `zig-out/bin/claudacity usage` is the smoke for a change to what `usage` or `pick` prints. It reads every profile and refreshes expired logins the same way, and switches nothing.

## Shipping

The [`ship`](.claude/skills/ship/SKILL.md) skill lands a branch on `origin/main` (squashed, no PR) through `scripts/ship.sh`, which rebuilds the installed `~/.local/bin/claudacity` from main, then archives the session. Never squash or push to main by hand: the script squashes only a tree its rebase finished, which a hand-run `git reset --soft origin/main` does not check. The skill runs only when the user asks, or invokes [`ship-at-end`](.claude/skills/ship-at-end/SKILL.md) to implement a change and ship it once it looks good. `📦 ` means the three gates pass on the branch; `🚀 ` means the push landed.

A GitHub release, which `install.sh` and `claudacity update` download, is cut only when the user asks: `scripts/release.sh <version>` from a clean `origin/main` bumps the version, cross-compiles both Mac binaries against the SDK as `--sysroot`, pushes the release commit and tag, and publishes the binaries with `gh`. The ship skill runs it when the ship was asked to release.

To test a change to `scripts/ship.sh`, give it a bare clone as `origin`, a stub `zig` first on `PATH` that writes `zig-out/bin/claudacity`, and `CLAUDACITY_BIN_DIR` pointing into the scratchpad so the install lands there; a `pre-receive` hook in the bare clone that fails once exercises a refused push. To test a change to `scripts/release.sh` without publishing, clone the repo bare into the scratchpad as `origin`, clone a work copy from it, and put a stub `gh` that records its arguments first on `PATH`.
A `ship.sh` fixture needs `zig-out/` in its `.gitignore`, as the repo has: otherwise the script's commit of leftover work picks up the stub's binary, the next gates run rewrites it, and the retry's rebase stops on unstaged changes.
After a real release, curl the asset `install.sh` names and run its `--version`.

## Working rules

- Never run a real switch, carry-over or cloud continuation against the user's profiles to test something. Build the case in temp directories; the first real run is the user's. To see what `claudacity pick` hands the picker without switching, put a stub `sk` first on `PATH` that saves its stdin and prints nothing: an empty selection exits before any switch.
- A unit test of `pick`'s lines cannot show how sk lays them out; render the saved stdin in the real `sk` before shipping a change to what `pick` shows. There is no tmux here: run `sk` under Python's `pty.fork` and feed what it draws to `pyte` (pip-installed in a throwaway venv) to read the screen. sk draws a header (`--header`, `--header-lines`) under the rows unless `--reverse` is set, and drops the tabs in a header line while expanding the tabs in rows to 8-column stops, so `pick` expands its header's tabs itself.
- Reading saved logins (even hashed, to compare them) or calling Anthropic's API with them, rewriting `~/.claude.<profile>.json`, writing Desktop's session records, teleporting cloud sessions, and reading the contents of files in Desktop's data directory (`claude_desktop_config.json` included) are blocked by auto mode until the user approves. Listing that directory is allowed; for a file's shape, hand the user a `jq` command that prints every key path and its type, never a value (`jq -r '[paths(scalars) as $p | ($p | map(if type == "number" then "[]" else . end) | join(".")) + ": " + (getpath($p) | type)] | unique | .[]' <file>`). Ask before relying on them, or hand the user a script to run.
- To find which Desktop file holds a feature without reading any, `grep -rlia` a name the user gave it (an environment's name, say) across `~/Library/Application Support/Claude*`: it prints file names only.
- Creating or changing claude.ai account state (adding a marketplace, for one) on any profile is blocked by auto mode even after cookie reads were approved; hand the user a script that sends a browser `User-Agent` (`docs/claude-internals.md`, Plugin marketplaces).
- Before switching or handing off, check that each profile holds its own account (`claudacity whoami`, `claudacity usage`). A `claude auth login` run under the wrong profile gets saved over that profile's login by the next switch; repair it first (`docs/claude-internals.md`, Logins).
- The outgoing profile's live login is saved in `profile.saveAs` with `.auto`, before `useWith` installs the incoming one; work on the outgoing login at switch time (`renewSaved`) hooks in there.
- Work that runs on every switch goes in `profile.useWith`, which both `use` and `handoff` call; it runs after Desktop's data has swapped and before Desktop relaunches. `claudacity marketplaces sync` exercises the post-switch marketplace sync on the active profile without switching.
- Desktop data that should follow every profile (preferences, MCP servers, local environments) is carried in `src/desktop_settings.zig`, called from `profile.carryDesktopSettings` after the swap; a newly carried item is listed in README's "Desktop settings follow you" and in `docs/claude-internals.md`'s Desktop settings bullet.
- A switch step that can run for seconds shows a live line through `display.Progress` (`src/display.zig`): spinner, step, `done/total` from `tick()`, elapsed seconds; a single line off a terminal. The slow ones today are the open-session carry, which waits up to 30s for Desktop's session processes, and the claude.ai marketplace sync, which polls each marketplace. Nothing else may print between its `start` and `stop`.
- To see what a terminal line draws without a real switch, copy `src/display.zig` beside a small `main.zig` in a temp directory, `zig build-exe main.zig -lc`, and run the binary under Python's `pty.fork` for the escape sequences and once through `| cat` for the off-terminal output.
- To exercise `claudacity login` with no real login, put a stub `claude` first on `PATH` that writes a fake login into `Claude Code-credentials-<hash of $CLAUDE_CONFIG_DIR>` (`oauth.configDirService`), create a throwaway profile (`~/.claude.<name>.json` holding `{}`), and run the binary under Python's `pty.fork`, since it refuses a stdin that is not a terminal. Check `claudacity-code-<name>`, then delete it and the profile file.
- The installed `~/.local/bin/claudacity` is built from `main` by `ship`, so it lacks whatever this branch adds. Use this checkout's `zig-out/bin/claudacity`.
- An overflow account sits on the free plan until its tokens are needed, so a free-plan profile is a normal state, not a broken login: it cannot sign in to Claude Code at all (claude.ai answers "Claude Max, Ultra, or Pro is required"), and its usage reads as HTTP 403 while its saved login keeps refreshing. Ask about the account's plan before telling the user a refusal needs a new sign-in.
- One tool refreshes a given saved login. A second one (for example `claude-swap`) rotates the refresh token out from under claudacity and forces a fresh sign-in.
- `claudacity usage` colors only a terminal (`isatty`, `NO_COLOR` off). Output from the Bash tool or the chat's `!` prefix is captured, so it shows no colors; check colors in the app's Terminal panel. `read_terminal` strips them too, so only the user can confirm them. `sk` and `fzf` show colors only with `--ansi`.
- `security` reads the login Keychain under `$HOME`, so a script tested with a fake `HOME` finds no Keychain items at all. Point only its file paths at the temp directory (a root variable) and use throwaway service names in the real Keychain.
- Secrets never go in process arguments: requests go through `exec.run` with the request on stdin (`src/http.zig`). `std.process.run` always ignores stdin in Zig 0.16, so piping needs `std.process.spawn` with `.stdin = .pipe` (`src/exec.zig`).

## Zig tests

- `usage.collect` reads profiles concurrently through `std.Io.Group`, so code it reaches must keep to its own profile's Keychain entries and files. The wait is network-bound: about one profile's requests, not the sum.
- Tests that spawn a process use `std.testing.io`; `std.Options.debug_io` fails the spawn with `OutOfMemory`.
- Code reached from a test must not write to stdout: the test runner speaks to the build server over stdout, and the run hangs with no error. Guard prints with `builtin.is_test`.
- Times print in the Mac's local zone (`localtime_r`, `%Z`). A test that checks a formatted time pins the zone with `setenv("TZ", …)` and `tzset()` so it passes in any zone; to see another zone from the binary, run it with `TZ=Asia/Tokyo`.
- A new module needs its `_ = @import(...)` line in `main.zig`'s comptime block, or `zig build test` never runs its tests.
- In-process work with no subprocess to kill (`std.http.Client`) is bounded with `std.Io.Select` racing it against `std.Io.sleep` (`http.sendDirect`).
- Background work for the length of a step runs with `io.concurrent`, which returns a `std.Io.Future` and can fail where no concurrency is available, so keep an inline fallback. A loop in it that sleeps with `io.sleep` ends on `Future.cancel`, because the sleep returns `error.Canceled` (`display.Progress`).
- Zig 0.16's `std.time` has no `milliTimestamp`; use `oauth.nowMs()`.
- Zig 0.16 moved most I/O into `std.Io`, so look up a signature in the installed std (`/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Io.zig`) rather than from memory. `zig env` prints ZON (`.lib_dir = "…"`), not JSON.
- Zig refuses a capture that shadows any outer name, file-scope consts included: `profile.zig`'s `const c = @cImport(...)` rules out `|c|` there.
- A build with an explicit `-Dtarget`, even `aarch64-macos`, gets no macOS SDK paths and fails to find sqlite3. Pass `--sysroot "$(xcrun --show-sdk-path)"`, which `build.zig` turns into the SDK's include and library paths. Run the x86_64 binary with `arch -x86_64` to smoke it under Rosetta.
- Under `--sysroot`, Zig resolves a library path inside the sysroot but takes an include path as is: `build.zig` adds `/usr/lib` and `<sdk>/usr/include`. `--search-prefix` with either form leaves one of them broken.
- External effects in orchestration code go through an injected interface (`handoff.Effects`) so ordering is tested with fakes.

## Docs

- `docs/claude-internals.md` — how Claude Desktop, Claude Code and Anthropic's OAuth endpoints behave where claudacity depends on them: login refresh and rotation, the usage and cloud-session APIs, Desktop's session store, unattended CLI runs, launchd quirks, and how to find an endpoint no doc lists.
- `docs/plans/` — unified plans; `2026-09-27-0845-feat-nightly-account-handoff-plan.md` holds the product decisions behind `claudacity handoff` (why no request proxy, what moves and what stays).
