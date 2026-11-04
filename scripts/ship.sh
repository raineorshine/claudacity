#!/usr/bin/env bash
# ship.sh <message-file> [--release <version>] — land this branch on origin/main as
# one commit, then rebuild the installed claudacity from main. The message file holds
# the commit message (subject, blank line, body).
#
# The squash keeps the worktree's files as they are, so it runs only on a tree the
# rebase finished: a squash of a branch cut before other work landed would ship that
# work's removal as an ordinary commit, and nothing on the push would refuse it.
#
# Exit codes: 0 shipped and installed; 1 not shipped; 2 rebase stopped on conflicts
# (resolve, `git rebase --continue`, rerun); 3 shipped, but the install failed.
set -euo pipefail

MSG="${1:?usage: scripts/ship.sh <message-file> [--release <version>]}"
RELEASE=""
if [ "${2:-}" = "--release" ]; then RELEASE="${3:?--release needs a version}"; fi
BIN_DIR="${CLAUDACITY_BIN_DIR:-$HOME/.local/bin}"
TRIES=3

die() { echo "❌  $*" >&2; exit 1; }

[ -s "$MSG" ] || die "commit message file $MSG is empty or missing"
MSG=$(cd "$(dirname "$MSG")" && pwd)/$(basename "$MSG")
cd "$(git rev-parse --show-toplevel)"
if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
  die "a rebase is in progress: finish it with git rebase --continue, then rerun"
fi

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -q -m "ship: work in progress"
fi

gates() {
  echo "➜   Gates..."
  zig build
  zig build -Doptimize=ReleaseSmall
  zig build test >/dev/null 2>&1 || { zig build test --summary all || true; die "zig build test failed"; }
}

shipped=""
for try in $(seq 1 "$TRIES"); do
  git fetch -q origin main
  if ! git rebase -q origin/main; then
    echo "⚠️  Rebase stopped (conflicts above). Resolve them, git rebase --continue, and rerun scripts/ship.sh." >&2
    exit 2
  fi
  [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ] || die "nothing to ship: HEAD is origin/main"
  # The guard this script exists for: squash only onto the main the rebase finished on.
  git merge-base --is-ancestor origin/main HEAD || die "HEAD does not contain origin/main; the rebase did not finish"
  gates
  git reset -q --soft origin/main
  git commit -q -F "$MSG"
  echo "➜   Shipping: $(git log -1 --format=%s)"
  git diff --stat origin/main HEAD | tail -n 1
  if git push -q origin HEAD:main; then
    shipped=$(git rev-parse --short HEAD)
    break
  fi
  echo "⚠️  Push refused (try $try of $TRIES); rebasing onto the new main." >&2
done
[ -n "$shipped" ] || die "push refused $TRIES times; not shipped"
echo "✅  Shipped $shipped to origin/main"

if [ -n "$RELEASE" ]; then
  scripts/release.sh "$RELEASE" || echo "⚠️  Release $RELEASE failed; the ship itself landed." >&2
fi

# Move the local main wherever it is checked out; leave it if it has local changes.
git fetch -q origin main
MAIN=$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0=="branch refs/heads/main"{print w}')
if [ -z "$MAIN" ]; then
  git fetch -q origin main:main || echo "⚠️  Local main left behind." >&2
elif [ -n "$(git -C "$MAIN" status --porcelain --untracked-files=no)" ]; then
  echo "⚠️  Local main left behind: $MAIN has local changes." >&2
else
  git -C "$MAIN" merge -q --ff-only origin/main || echo "⚠️  Local main left behind: it does not fast-forward." >&2
fi

# Rebuild the installed claudacity from origin/main, never from this tree. Copy, then
# rename over it: a running handoff keeps the old inode, and overwriting a signed
# binary in place gets the next run killed.
BUILD=$(mktemp -d)/claudacity-main
git worktree add -q --detach "$BUILD" origin/main
if (cd "$BUILD" && zig build -Doptimize=ReleaseSmall); then
  mkdir -p "$BIN_DIR"
  cp "$BUILD/zig-out/bin/claudacity" "$BIN_DIR/claudacity.new"
  mv -f "$BIN_DIR/claudacity.new" "$BIN_DIR/claudacity"
  ln -sf claudacity "$BIN_DIR/cly"
  git worktree remove --force "$BUILD"
  echo "✅  Installed $("$BIN_DIR/claudacity" --version)"
else
  git worktree remove --force "$BUILD"
  echo "⚠️  Shipped, but the install build failed; the installed claudacity is unchanged." >&2
  exit 3
fi
