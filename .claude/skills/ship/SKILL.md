---
name: ship
description: "Finish a change in the claude-switch repo: run the gates, commit, rebase on origin/main, squash, push to origin/main, move the local main, rebuild the installed csw from main, extract the session's learnings, and archive the session. Use only when the user explicitly asks for the change to be shipped, landed, or pushed to main — never because a change looks finished."
---

# Ship (finish a change → land it on origin/main → install it)

Solo-developer workflow: squash the current branch, usually in a worktree, to a single commit and
push it to `origin/main` on the fork. No PR, and no merge commits.

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

Judge `zig build test` by its exit code and `Build Summary`, not its output (AGENTS.md "Gates"). Fix
every failure and re-run until clean.

### 2. Commit all staged and unstaged changes

Bring the writing level with the change first, so it lands in this ship rather than a follow-up:

- **`README.md`**, for anything a user would notice: a command, a flag, the schedule, what a switch or
  handoff moves.
- **`docs/claude-internals.md`**, for anything the change learned or assumed about how Claude Desktop,
  Claude Code or Anthropic's endpoints behave.
- **`AGENTS.md` and this skill**, where the change made something they say untrue.

Leave `CHANGELOG.md` alone: release-please writes it from the commit messages.

Then generate the message from the diff: Conventional Commits — `feat:`, `fix:`, `docs:`, `chore:` —
with a lower-case subject under about 60 characters, and a body that says why rather than what. The
body also says, in a line of its own, whether the change never ran against real profiles — a thing
nothing else will record, since the gates run only on temp directories.

### 3. Rebase on origin/main

```bash
git fetch origin && git rebase origin/main
```

Resolve conflicts, preferring the branch's changes unless clearly wrong, then `git add` and
`git rebase --continue`, repeating until it completes.

**Prefer the branch's changes, not its copy of whole files.** A worktree cut before something landed
holds the old copy of every file that change touched. Before resolving a conflict in a file this
branch did not set out to change, list what landed in it:

```bash
git log --oneline $(git merge-base HEAD origin/main)..origin/main -- <file>
```

Anything listed there that your side does not contain is about to be undone.

**Read what the rebase brought into `AGENTS.md` and `docs/` against the change.** Another session can
have written a claim this branch makes untrue — the first ship of this skill landed beside a new line
saying the installed csw was the upstream release, which step 7 was about to falsify. A clean rebase
flags none of it:

```bash
git diff $(git merge-base ORIG_HEAD origin/main) origin/main -- AGENTS.md docs/ README.md
```

Correct it before the squash, so it lands in this ship.

Re-run step 1 after any rebase that brought code in: the gates passed on a different tree.

Already on `main`: skip the rebase and step 4, but not the fetch — `git pull --ff-only`, commit, and go
straight to step 5.

### 4. Squash all commits into one

```bash
git reset --soft origin/main && git commit -m "subject" -m "body"
```

Use a single message that describes the overall diff.

### 5. Push to origin/main

```bash
git push origin HEAD:main
```

This is the ship. `origin` is the fork (`raineorshine/claude-switch`); never push to `upstream`.

**If the push is rejected as non-fast-forward,** someone else landed first and nothing was lost: go
back to step 3, redo step 4 onto the new base, and push again.

### 6. Move the local main

```bash
git fetch origin main && MAIN=$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0=="branch refs/heads/main"{print w}') && if [ -z "$MAIN" ]; then git fetch origin main:main; elif [ -n "$(git -C "$MAIN" status --porcelain --untracked-files=no)" ]; then echo "local main left behind: $MAIN has local changes"; else git -C "$MAIN" merge --ff-only origin/main; fi
```

It fast-forwards `main` in place wherever it is checked out, and moves the ref alone when `main` is
checked out nowhere, since `git fetch origin main:main` refuses to move a checked-out branch. When it
reports local changes, or the fast-forward refuses, leave them — never `checkout --` someone's work away.

### 7. Rebuild the installed csw from main

The installed `~/.local/bin/csw` is a copy of a local build, not a release download, and the nightly
`csw schedule` job runs it. Build it from `origin/main` in a throwaway checkout — never from this
branch or the main checkout, whose trees can hold work that has not shipped:

```bash
BUILD=$(mktemp -d)/csw-main && git worktree add --detach "$BUILD" origin/main && (cd "$BUILD" && zig build -Doptimize=ReleaseSmall) && cp "$BUILD/zig-out/bin/csw" ~/.local/bin/csw.new && mv -f ~/.local/bin/csw.new ~/.local/bin/csw && git worktree remove --force "$BUILD" && csw --version
```

Copy then `mv`, never `cp` over the installed file: the rename leaves a running handoff on the old
inode, and overwriting a signed binary in place gets the next run killed by the kernel. Installing
runs nothing against the user's profiles.

**If the build fails,** the ship has still happened and the installed csw is unchanged: one line in the
report, and remove the throwaway worktree with `git worktree remove --force "$BUILD"`.

### 8. Put `🚀 ` on the title

The push in step 5 is what counts as shipped, whatever step 7 managed, so the prefix goes on here and
not at the start. Until then the title keeps what was already true — usually `📦 `. Say nothing about
it in the response.

### 9. Extract the learnings

Invoke the `learn` skill. Whatever the session learned about csw, Claude's internals or the workflow
is still in context now and in nobody's an hour later, so this is the last stage of shipping and needs
no ask. Skip it when the ship was itself the last step of `learn` or `learn-organize`.

`learn` puts `📚 ` on the title; put `🚀 ` back when it finishes. If it finds nothing worth recording,
say so in one line.

### 10. Print the completion message

Print `🚀 Shipped` as the last line of the response, after the learn report. Write it before step
11's call, in the same response: nothing after the archive reaches the user.

### 11. Archive the session

Last of all, after `learn` has landed its commit and `🚀 ` is back on the title, archive this
session: `mcp__ccd_session_mgmt__archive_session` with `"self"` and a reason naming the ship. It is
the final tool call of the ship. Asking to ship is the agreement to archive; do not ask again.

Skip it when the ship was the last step of `learn` or `learn-organize` invoked on their own: the
session goes on after that ship. A ship that fell over short of the push in step 5 is still work in
progress and keeps its session.

**The archive refuses while anything of this session is still pending** — a background task, an armed
waiter, a scheduled wakeup left as a fallback. Stop each one first (a pending wakeup is cancelled with
`ScheduleWakeup` and `stop: true`); if it still refuses, the user archives from the sidebar.

Archiving removes this worktree. The branch outlives it, and the session is reopened from the Archived
list if it is ever needed again.
