---
name: ship
description: "Finish a change in the claudacity repo: run the gates, then land it with scripts/ship.sh (rebase on origin/main, squash, push, move the local main, rebuild the installed claudacity from main), extract the session's learnings, and archive the session. Use only when the user explicitly asks for the change to be shipped, landed, or pushed to main — never because a change looks finished."
---

# Ship (finish a change → land it on origin/main → install it)

Solo-developer workflow: squash the current branch, usually in a worktree, to a single commit and
push it to `origin/main` (`raineorshine/claudacity`). No PR, and no merge commits.

**Shipping is asked for, never inferred.** A change that is finished, gated and clean is a change
ready to ship, not one to ship — say so and stop. Only the user saying to ship, land, merge or push it
starts this procedure, or a skill the user invoked whose own procedure ends in one, `ship-at-end`,
`learn` and `learn-organize` among them.

`origin/main` is the source of truth, not the local `main` ref, which can be behind what another
session pushed. Pushing from the worktree keeps shipping independent of the main checkout, which is
often on some other branch.

## Procedure

### 1. Run the gates (must pass before committing)

```bash
zig build && zig build -Doptimize=ReleaseSmall && zig build test
```

Judge `zig build test` by its exit code, not its output (AGENTS.md "Gates"). Fix
every failure and re-run until clean.

### 2. Bring the writing level and write the message

Bring the writing level with the change first, so it lands in this ship rather than a follow-up:

- **`README.md`**, for anything a user would notice: a command, a flag, the schedule, what a switch or
  handoff moves.
- **`docs/claude-internals.md`**, for anything the change learned or assumed about how Claude Desktop,
  Claude Code or Anthropic's endpoints behave.
- **`AGENTS.md` and this skill**, where the change made something they say untrue.

Leave `CHANGELOG.md` alone: `scripts/release.sh` writes it from the commit messages.

Then generate the message from the diff: Conventional Commits — `feat:`, `fix:`, `docs:`, `chore:` —
with a lower-case subject under about 60 characters, and a body that says why rather than what. The
body also says, in a line of its own, whether the change never ran against real profiles — a thing
nothing else will record, since the gates run only on temp directories.

### 3. Land it with `scripts/ship.sh`

Write the message to a file in the scratchpad and run:

```bash
scripts/ship.sh <message-file>                      # add --release <version> only when asked
```

The script commits anything uncommitted, fetches, rebases on `origin/main`, runs the gates on the
rebased tree, squashes to one commit with the message, and pushes it to `origin/main`
(`raineorshine/claudacity`; never `fork` or `upstream`). A refused push makes it fetch and rebase
again, up to three times. Then it moves the local main wherever it is checked out, and rebuilds the
installed `~/.local/bin/claudacity` (and its `cly` symlink) from `origin/main` in a throwaway checkout.

**Never squash or push by hand.** `git reset --soft origin/main` keeps the worktree's files as they
are, so on a tree the rebase did not finish it ships the removal of everything that landed since, as
an ordinary commit no push refuses. That is how a ship once took `cly login` out of main an hour after
it landed. The script squashes only when `origin/main` is an ancestor of `HEAD`.

| Exit | Means | Do |
| ---- | ----- | -- |
| 0 | Shipped and installed | Go on to step 4 |
| 1 | Not shipped (gates failed, nothing to ship, three refused pushes) | Fix what it printed and rerun |
| 2 | The rebase stopped on conflicts | Resolve them (below), `git rebase --continue`, rerun |
| 3 | Shipped; the install build failed, the installed claudacity is unchanged | One line in the report |

**Resolving a conflict, prefer the branch's changes, not its copy of whole files.** A worktree cut
before something landed holds the old copy of every file that change touched. Before resolving a
conflict in a file this branch did not set out to change, list what landed in it, and keep it:

```bash
git log --oneline $(git merge-base HEAD origin/main)..origin/main -- <file>
```

**Read what landed in `AGENTS.md`, `docs/` and `README.md` before running the script.** Another
session can have written a claim this branch makes untrue, and a clean rebase flags none of it:
`git fetch origin && git diff HEAD...origin/main -- AGENTS.md docs/ README.md`. Correct what the change
falsifies first, so it lands in this ship.

**A release** (`--release <version>`, only when the user asked: "ship and release", "cut 1.1.0") runs
`scripts/release.sh` after the push and before the rebuild, so the installed build has the bumped
version. Take the version the user named; otherwise bump by the commits since the last `v*` tag —
major for a `!`, minor for a `feat:`, patch for the rest.

**The install build failing on a full disk** (`No space left on device`): this checkout's own
`zig-out/bin/claudacity` is the ReleaseSmall build of the shipped tree when `git diff --quiet HEAD
origin/main` holds; copy it to `~/.local/bin/claudacity.new`, `mv -f` it over
`~/.local/bin/claudacity`, and `ln -sf claudacity ~/.local/bin/cly`.

### 4. Put `🚀 ` on the title

The push in step 3 is what counts as shipped, whatever the install managed, so the prefix goes on here and
not at the start. Until then the title keeps what was already true — usually `📦 `. Say nothing about
it in the response.

Read the title with `mcp__ccd_session_mgmt__get_session` (`"self"`) and set it with
`mcp__ccd_session_mgmt__set_session_title`, replacing the existing prefix rather than stacking. In a
cloud session, where those do not exist, `mcp__claude-code-remote__get_session` with no `session_id`
describes this session (`ccr.id`, `ccr.title`), and `mcp__claude-code-remote__set_session_title`
takes that id. Skip only when neither tool exists. Step 5's `🚀 ` goes back the same way.

### 5. Extract the learnings

Invoke the `learn` skill. Whatever the session learned about claudacity, Claude's internals or the workflow
is still in context now and in nobody's an hour later, so this is the last stage of shipping and needs
no ask. Skip it when the ship was itself the last step of `learn` or `learn-organize`.

`learn` puts `📚 ` on the title; put `🚀 ` back when it finishes. If it finds nothing worth recording,
say so in one line.

### 6. Print the completion message

Print `🚀 Shipped` as the last line of the response, after the learn report. Write it before step
7's call, in the same response: nothing after the archive reaches the user.

### 7. Archive the session

Last of all, after `learn` has landed its commit and `🚀 ` is back on the title, archive this
session: `mcp__ccd_session_mgmt__archive_session` with `"self"`, or in a cloud session
`mcp__claude-code-remote__archive_session` with this session's `ccr.id`, and a reason naming the ship. It is
the final tool call of the ship. Asking to ship is the agreement to archive; do not ask again.

Skip it when the ship was the last step of `learn` or `learn-organize` invoked on their own: the
session goes on after that ship. A ship that fell over short of the push in step 3 is still work in
progress and keeps its session.

**The archive refuses while anything of this session is still pending** — a background task, an armed
waiter, a scheduled wakeup left as a fallback. Stop each one first (a pending wakeup is cancelled with
`ScheduleWakeup` and `stop: true`); if it still refuses, the user archives from the sidebar.

Archiving removes this worktree. The branch outlives it, and the session is reopened from the Archived
list if it is ever needed again.
