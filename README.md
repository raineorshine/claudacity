# claudacity

One Claude, many selves. Swap between Claude accounts (Code + Desktop) on macOS with a single command, and hand the day's work to the next account when one runs out of weekly usage.

Claude Code credentials saved by claudacity live in macOS Keychain. Profile switching also moves and links Claude's existing configuration and Desktop data directories on disk. Optional sharing keeps local skills and user-installed plugins available in another profile while account data stays separate.

## Install

### Option 1 — download binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/raineorshine/claudacity/main/install.sh | bash
```

This downloads the latest release binary for your architecture (arm64 or x86_64) to `~/.local/bin/claudacity`, with a short `cly` symlink beside it.

### Option 2 — build from source

Requires [Zig 0.16.0](https://ziglang.org/download/) (or install via [mise](https://mise.jdx.dev): `mise use zig@0.16.0`).

```bash
git clone https://github.com/raineorshine/claudacity
cd claudacity
zig build -Doptimize=ReleaseSmall
# binary at: zig-out/bin/claudacity
cp zig-out/bin/claudacity ~/.local/bin/claudacity
ln -sf claudacity ~/.local/bin/cly
```

### Option 3 — manual download

Grab the binary for your architecture from [Releases](https://github.com/raineorshine/claudacity/releases), put it somewhere in your `$PATH`, and `chmod +x` it.

---

Make sure `~/.local/bin` is in your `$PATH` (add to `~/.zshrc` if needed):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

You also need [sk](https://github.com/lotabout/skim) or [fzf](https://github.com/junegunn/fzf) for the interactive picker:

```bash
brew install sk
```

## Getting started

You need to save each account as a profile before you can switch between them. Do this once per account:

**1. Save your current account (e.g. work)**

```bash
claudacity save work
```

This saves the session tokens into macOS Keychain and migrates `~/.claude.json` and `~/.claude/` to profile-specific paths (`~/.claude.work.json`, `~/.claude.work/`), leaving symlinks in place. From now on, switching just swaps the symlinks.

**2. Create a slot for the second account and log in**

Sign out of claude.ai in your browser first, or open the sign-in URL that `claude auth login` prints in a private window. `claude auth login` authorizes whichever account the browser is already signed in to, even with `--email`, so a browser still signed in to the first account saves that account a second time under the new name.

```bash
claudacity new personal   # creates ~/.claude.personal.json + ~/.claude.personal/, activates symlinks
claude auth login --email you@personal.com  # logs in as the personal account into the active slot
```

Check the result before saving: `claude auth status` must show the new account's email.

**3. Save the second account**

```bash
claudacity save personal
```

You're set. Switch between accounts instantly:

```bash
claudacity use work
claudacity use personal
# or interactively:
claudacity pick
```

### Open sessions follow you

Each switch, including `claudacity pick`, moves every open local Code session into the
profile you switch to, with its full history, and archives it in the one you
leave, so it stays listed in Claude Desktop on the new account. Desktop's
session processes get up to 30 seconds to finish before they are stopped; a
session still running after that stays behind. Pass `--no-carry-sessions` to
`claudacity use` to leave every session where it is, for example when one account
belongs to an organization whose work should not cross into another.

### Desktop settings follow you

Each switch carries Claude Desktop's app settings (Remote Control, keep-awake,
sidebar and the rest of its preferences) and its MCP server list from the
profile you leave into the one you switch to, so the last change wins in every
profile. Sign-ins, the Remote Control connection and settings Desktop takes
from an account's organization stay with each profile.

### Cloud environments

Claude Code cloud environments (allowed network hosts, environment variables,
setup script) belong to each account, so a host allowed on one is still blocked
on the others. `claudacity envs sync` copies the active profile's environments to every
other profile: matched by name, created when missing, updated when they differ.
Environments only a target has are left alone. `--from <profile>` picks another
source and `--dry-run` shows the plan without writing.

### Skills and plugins in a new profile

`claudacity new` creates an empty `~/.claude.<profile>/` directory. Claude Code user
skills in `~/.claude/skills/` and installed plugins therefore do not appear in
the new profile automatically. The account's conversations and credentials stay
separate too.

To keep **local user skills and installed plugins** from `work` available in `personal`, opt in after
creating both profiles:

```bash
claudacity share work personal
```

The command links local skills that are missing in `personal`. It preserves
same-named skills already there and never links Claude's account-specific
`skills/synced` directory. Edits to linked skills appear in both profiles;
new skills added to `work` are linked automatically the next time you run
`claudacity use personal`. Skills created only in `personal` stay there.

The same sharing relationship copies **user-installed plugins** through Claude's
plugin commands. It adds missing marketplaces and plugins, matches enabled
states, and updates a target plugin when its version differs from the source.
It runs when sharing is enabled and before each switch to `personal`, so newly
installed plugins in `work` arrive on the next switch. Claude keeps each
profile's plugin cache, plugin data, and account-synced plugins separate.
Target-only plugins are preserved. A failed plugin install stops the switch
before Claude Desktop is closed; retry when the marketplace is available.
Plugins whose marketplace requires running an install command may still ask
for explicit confirmation, which claudacity does not bypass.

Run `claudacity unshare personal` to stop future syncing and remove skill links;
already installed plugins remain. The source profile cannot be deleted while
another profile shares from it. `share-skills` and `unshare-skills` remain
aliases for existing setups.

Start a new Claude Code session to load newly installed plugins. Skills uploaded
in Claude's **Customize → Skills** are [tied to the signed-in Claude account](https://support.claude.com/en/articles/12512180-use-skills-in-claude);
these local links do not copy those uploads to another account.

## Usage

```
claudacity save <name>    Save current sessions (Code + Desktop) as a named profile
claudacity use <name>     Switch to a saved profile, moving open local Code sessions with you
claudacity use <name> --no-carry-sessions  Switch and leave open sessions on the old profile
claudacity new <name>     Create a new empty profile slot (then: claude auth login)
claudacity share <source> <target>  Share local skills and user plugins on each switch
claudacity unshare <target>        Stop sharing and remove shared skill links
claudacity delete <name>  Delete a profile and its data
claudacity list           List all saved profiles
claudacity whoami         Show active session info (Code + Desktop + saved profiles)
claudacity pick           Interactive fuzzy picker (sk / fzf) with each profile's weekly usage
claudacity update         Update claudacity to the latest release
claudacity logout-all     Log out of all accounts and remove active symlinks
claudacity usage          Show 5-hour and weekly usage for every profile
claudacity next           Show which profile a switch would move to, and why
claudacity handoff        Move the day's work to the next account (see below)
claudacity schedule       install | uninstall | status — run claudacity handoff nightly at 22:00
claudacity envs sync      Copy cloud environments from the active profile to the others
```

## Nightly account handoff

If you run more than one Claude subscription, `claudacity handoff` moves your work to the next account when the active one is nearly out of weekly usage, so you never watch the percentage or write handoffs by hand.

```bash
claudacity handoff --dry-run   # show what would happen; changes nothing
claudacity schedule install    # run it every night at 22:00
```

When the active profile is at 90% or more of its weekly limit, `claudacity handoff`:

1. Picks the next profile: below 90%, with a valid saved login, whose week resets soonest.
2. Hands off every cloud Code session that is running or was started in the last 24 hours. Each one is downloaded into a throwaway clone with `claude --teleport`, where `/ce-handoff create` (Compound Engineering plugin) writes its handoff. The live session is never messaged or interrupted.
3. Switches accounts. Every open local Code session is carried into the next profile with its full history and archived in the old one, so it stays listed in Claude Desktop, and on your phone through Remote Control, on the new account.
4. Starts one new cloud session per handoff on the new account, so those tasks continue there and are listed in Desktop, on your phone, and on claude.ai.
5. Writes a report and sends one notification, which reminds you to sign the Claude mobile app in to the new account.

What stays behind: chats (Desktop Chat tab and mobile), and cloud sessions older than a day that are not running. They remain on the old account and come back when you switch to it again.

The scheduled run only acts between 22:00 and 06:00. If the Mac is asleep at 22:00, launchd runs it on wake; outside that window it switches nothing and notifies you instead.

`claudacity usage` marks the active profile with `>` and colors each percentage by how full it is: green under 50%, yellow under 75%, orange under 90%, and red from 90%, where handoff treats a profile as full. Colors appear only in a terminal, and never when `NO_COLOR` is set. `claudacity pick` shows each profile's email, then its weekly percentage colored the same way. Reset times read like `Thu Oct 8 @ 1pm EDT`, in the local time zone.

Reading another profile's usage needs its saved login. claudacity refreshes expired logins and saves the renewed one in place, along with the account's current plan, so an upgrade shows in `claudacity whoami` after the next `claudacity usage`; if a login can no longer be renewed, `claudacity usage` says the profile needs signing in again. Sign out of claude.ai in your browser, then run `claudacity use <name>`, `claude auth login --email <address>` and `claudacity save <name>`, in that order: logging in while another profile is active overwrites that profile's login.

## How it works

### Security model

claudacity saves Claude Code session credentials in **macOS Keychain** and moves Claude's local configuration and Desktop data into profile-specific paths. When sharing is enabled, the target profile also contains a `.claudacity-skills-source` file naming the source profile; that relationship governs both local skills and user plugins.

| Data | Where it lives |
|---|---|
| Claude Code tokens | Keychain: `claudacity-code-<profile>` |
| Active Code session | Keychain: `Claude Code-credentials` (managed by Claude) |
| Active Desktop session | Electron SQLite cookie, AES-128-CBC encrypted (managed by Claude Desktop) |
| Desktop encryption key | Keychain: `Claude Safe Storage` (managed by Claude Desktop) |
| Profile configs | `~/.claude.<profile>.json` + `~/.claude.<profile>/` |
| Active profile | `~/.claude.json` → symlink, `~/.claude/` → symlink |
| Handoff reports and cloud handoffs | `~/Library/Application Support/claudacity/handoffs/<date>/` |
| Nightly schedule | `~/Library/LaunchAgents/com.github.raineorshine.claudacity-handoff.plist`, log in `~/Library/Application Support/claudacity/handoff.log` |

- Account switching does not send tokens to a claudacity service.
- `claudacity usage`, `claudacity next`, `claudacity handoff` and `claudacity envs sync` call Anthropic's API directly (usage, plan, login refresh, cloud-session list, cloud environments) with each profile's own saved login. Requests go through `curl` with the request on stdin, so tokens never appear in process arguments.
- Both Claude Code and Claude Desktop are optional — claudacity works with either or both.
- On switch, Claude Desktop is quit automatically and relaunched.

### Profile switching

Switching profiles is instant because `~/.claude.json` and `~/.claude/` are symlinks. Changing them is an atomic filesystem operation — no copying, no rewriting.

Claude Desktop uses real directory renames instead of symlinks (Electron doesn't follow symlinks for its data directory). On switch, claudacity renames `Claude/` → `Claude.<from>/` and `Claude.<to>/` → `Claude/`.

## Development

```bash
git clone https://github.com/raineorshine/claudacity
cd claudacity

# Debug build (fast compile, leak detection)
zig build

# Optimised builds
zig build -Doptimize=ReleaseSafe   # bounds checks on, ~670 KB
zig build -Doptimize=ReleaseSmall  # smallest binary
zig build -Doptimize=ReleaseFast   # max speed

# Run tests
zig build test
```

CI runs on every push: `zig build` (debug) and `zig build test`.

Releases are built automatically when a tag is pushed:

```bash
git tag v0.2.0
git push origin --tags
```

GitHub Actions cross-compiles arm64 and x86_64 binaries (`-Doptimize=ReleaseSmall`) and publishes them to the release.

## License

MIT — see [LICENSE](LICENSE).

## Thanks

claudacity began as a fork of [claude-switch](https://github.com/mtxr/claude-switch) by [Matheus (@mtxr)](https://github.com/mtxr). Thanks for the solid foundation.
