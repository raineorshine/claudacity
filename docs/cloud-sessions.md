# Working from a cloud session

Raine is moving claudacity work to cloud sessions and does not want to build or verify on the Mac.
A cloud session runs on a Linux box even though its paths read `/Users/raine/...`, so check `uname`
before planning any gate or smoke. The repo's gates, smokes and ship flow all assume a Mac. A cloud
session runs the stand-ins below and asks the user only for what needs their real profiles.

## What the box lacks

- `~/Library` is unreadable and holds none of the user's Desktop data, and there is no macOS
  `security`. Nothing about real profiles, Desktop's cookies or the Keychain can be checked here.
- There is no `zig` on `PATH`. A Zig 0.16 toolchain sits at `/tmp/deps/zig-x86_64-linux-0.16.0/zig`,
  a Linux sqlite build at `/tmp/deps/pfx` (`include/`, `lib/libsqlite3.a`), and a stand-in macOS
  sysroot at `/tmp/deps/mac` that holds only sqlite's header and `libsqlite3.tbd`. An earlier session
  left them in `/tmp`, so a fresh box may not have them.

## Stand-ins for the gates

- **Builds.** A native Linux `zig build` of the binary fails at compile time: `std/c/darwin.zig`
  asserts `isDarwin` (reached through `_NSGetExecutablePath`). Cross-compile instead:
  `zig build -Dtarget=aarch64-macos --sysroot /tmp/deps/mac`, with `-Doptimize=ReleaseSmall` for the
  second gate, and `x86_64-macos` as well when a change touches anything architecture-dependent. The
  stand-in sysroot is enough to link; each build gives a Mach-O executable.
- **Tests.** `zig build test --search-prefix /tmp/deps/pfx` compiles and runs natively. Seven tests
  fail on unchanged `main` there (November 2026): the five `keychain.test.*` tests, since there is no
  `security`, and `cloud.test.continueFrom reports a failed send`, which crashes with
  `access of union field 'ok' while field 'failed' is active`. The cloud test has not been looked
  into. Judge a run against a baseline of the same suite on unchanged `HEAD`, run in a temporary
  `git worktree add --detach`: a change passes when it adds no failure to that set.
- **Smokes against real profiles** (`whoami`, `usage`, `handoff --dry-run`) need the Mac. Ask the user
  to run the one command that needs their data and to paste its output.

## Shipping from the cloud

`scripts/ship.sh` calls whatever `zig` is first on `PATH`. A wrapper `zig` there does the following:

- appends `-Dtarget=aarch64-macos --sysroot /tmp/deps/mac` to `zig build`;
- runs `zig build test` natively with `--search-prefix /tmp/deps/pfx`, and passes only when the
  failures are exactly the baseline set;
- exits 1 when its working directory ends in `claudacity-main`, the script's install checkout.

With `CLAUDACITY_BIN_DIR` pointing at a scratch directory, the script gates, squashes and pushes, then
exits 3 ("Shipped, but the install build failed"), which is the expected end. The Mac's installed
`claudacity` stays on the old build until a release reaches it through `claudacity update`.

Making this the repo's own ship flow was put off (November 2026) because claudacity changes rarely.
That would mean `ship.sh` gating on cross-builds plus Linux tests, skipping the macOS-only tests and
the local install off a Mac, and delivering through `scripts/release.sh`.

Say in the commit message which gates ran as cloud stand-ins and whether the user ran the change
against real profiles.

## Switching accounts on the box

claudacity is not built for Linux, and porting it would not switch the box's chats. Supernova starts
each chat's `claude` with `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`, a pipe carrying a
`claude setup-token` token that outranks `$CLAUDE_CONFIG_DIR/.credentials.json`. The token comes from
the server's own `claude-accounts.json`, falling back to `SUPERNOVA_CLAUDE_OAUTH_TOKEN` in root's env
file, and `chat` can neither read nor write either one. Switch the box's account in supernova's
Settings → Claude account; a chat moves to it on its next send. A setup token holds only
`user:inference`, so `usage` and `handoff` could not read those accounts either.

A Linux port was weighed and set aside (November 2026). It would keep logins in `.credentials.json`
and `0600` files instead of the Keychain, skip every Desktop step, replace `launchd` with a systemd
timer, and swap `_NSGetExecutablePath` for `std.fs.selfExePath`. That would switch only a `claude`
run by hand in a shell on the box.
