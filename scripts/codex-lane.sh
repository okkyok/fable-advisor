#!/usr/bin/env bash
# Run a codex lane inside a disposable git worktree.
#
# Why: `codex exec` runs outside Claude Code's PreToolUse hooks, so no hook can
# police what it writes. Scoping it with `--cd <repo toplevel>` makes the whole
# repository writable, which is how a lane ends up editing files its spec never
# listed. The cleanup for that — `git checkout -- <path>` on the main tree —
# is what destroys a co-resident lane's uncommitted work.
#
# This script removes that failure chain structurally: the lane gets its own
# worktree, so it cannot reach the main tree or another lane's tree, and undoing
# it is `git worktree remove`, never a checkout. Scope violations are contained
# and reported instead of silently landing.
#
# usage: codex-lane.sh --spec <file> --files <f1,f2,...> [--effort high] [--repo <path>] [--timeout 570]
#
# stdout: codex's last message, then a LANE REPORT block.
# exit:   0 ok · 3 codex unavailable · 4 timeout · 5 bad usage/blocked
set -euo pipefail

SPEC="" FILES="" EFFORT=high REPO="" TMO=570
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)    SPEC="$2"; shift 2 ;;
    --files)   FILES="$2"; shift 2 ;;
    --effort)  EFFORT="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --timeout) TMO="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 5 ;;
  esac
done
[ -f "$SPEC" ] || { echo "--spec must be a readable file" >&2; exit 5; }
[ -n "$FILES" ] || { echo "--files is required: the lane's allowed paths" >&2; exit 5; }

# --- locate the repo from the first spec'd file, unless told -------------------
if [ -z "$REPO" ]; then
  first="${FILES%%,*}"
  d=$(dirname -- "$first"); [ -d "$d" ] || d=$(pwd)
  REPO=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)
fi
[ -n "$REPO" ] && [ -d "$REPO/.git" ] || {
  echo "BLOCKED: --files do not resolve inside a git repository." >&2
  echo "A codex lane needs a repo to isolate into. Narrow the spec or pass --repo." >&2
  exit 5; }
[ "$REPO" != "$HOME" ] || { echo "BLOCKED: repo root is \$HOME. Narrow the spec's Files." >&2; exit 5; }

# --- build the worktree from the CURRENT state, without touching the main tree -
# `git stash create` writes a commit object and returns its sha. It does NOT
# modify the working tree and does NOT push onto the stash list — unlike bare
# `git stash`, which the destructive-git guard rejects for good reason.
BASE=$(git -C "$REPO" stash create 2>/dev/null || true)
[ -n "$BASE" ] || BASE=$(git -C "$REPO" rev-parse HEAD)

# Reap worktrees leaked by lanes that died before printing their discard command.
# 24h is far beyond any lane's life (the wall clock caps at ~570s), so this can
# never remove a running lane's tree.
# `|| true` on the pipeline is load-bearing: grep exits 1 when nothing matches,
# and under `set -o pipefail` that would abort every lane run on a clean repo.
git -C "$REPO" worktree prune >/dev/null 2>&1 || true
stale=$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' \
        | grep '/codex-lane-' || true)
[ -n "$stale" ] && printf '%s\n' "$stale" | while IFS= read -r old; do
  [ -d "$old" ] || continue
  if [ -z "$(find "$old" -maxdepth 0 -mtime -1 2>/dev/null)" ]; then
    git -C "$REPO" worktree remove --force "$old" >/dev/null 2>&1 || true
  fi
done
:

WT="${TMPDIR:-/tmp}/codex-lane-$$-$(date +%s)"
git -C "$REPO" worktree add --detach --quiet "$WT" "$BASE"
cleanup() { git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true; }
# Deliberately NOT trapped on EXIT: the caller needs the worktree to read the
# diff. cleanup() is called explicitly on the paths that should discard it.

# Untracked-but-not-ignored files are absent from a stash-create commit; copy
# them so the lane sees the same tree the architect does.
( cd "$REPO" && git ls-files --others --exclude-standard -z ) | while IFS= read -r -d '' f; do
  mkdir -p "$WT/$(dirname -- "$f")"; cp -p "$REPO/$f" "$WT/$f" 2>/dev/null || true
done

# Freeze that seeded state as the lane's baseline. HEAD here is detached and the
# worktree is disposable, so this commit is invisible to the main repo's branches
# — and it makes "what did the lane change" an exact `git diff HEAD`, rather than
# a guess that misreads pre-existing untracked files as lane output.
git -C "$WT" add -A >/dev/null 2>&1 || true
git -C "$WT" -c user.email=lane@local -c user.name=lane \
    commit -q --allow-empty -m "codex-lane baseline" >/dev/null 2>&1 || true

# --- run codex, scoped to the worktree ----------------------------------------
FINAL="$WT/.codex-final-message"
T=$(command -v gtimeout || command -v timeout || true)
[ -n "$T" ] || echo "WARN: no timeout binary; codex runs uncapped (brew install coreutils)" >&2

set +e
if [ -n "$T" ]; then
  "$T" -k 10 "$TMO" env -u OPENAI_API_KEY codex exec \
    --model gpt-5.6-luna \
    -c model_reasoning_effort="$EFFORT" \
    -c approval_policy="never" \
    -c sandbox_mode="workspace-write" \
    --ignore-user-config --sandbox workspace-write \
    --skip-git-repo-check --cd "$WT" \
    --output-last-message "$FINAL" - < "$SPEC"
else
  env -u OPENAI_API_KEY codex exec \
    --model gpt-5.6-luna -c model_reasoning_effort="$EFFORT" \
    -c approval_policy="never" -c sandbox_mode="workspace-write" \
    --ignore-user-config --sandbox workspace-write \
    --skip-git-repo-check --cd "$WT" \
    --output-last-message "$FINAL" - < "$SPEC"
fi
rc=$?
set -e

[ -f "$FINAL" ] && cat "$FINAL"

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  echo; echo "LANE REPORT"; echo "  status:   timeout after ${TMO}s"
  echo "  worktree: $WT   (kept — resume this lane against it)"
  exit 4
fi

# --- what actually changed, and what broke scope ------------------------------
# Diff against the baseline commit: exact lane output, new files included.
# `|| true` again: grep -v exits 1 when it selects no lines, which is exactly the
# empty-diff case — without it the script dies here and leaks the worktree
# instead of reporting the failure.
touched=$( cd "$WT" && { git diff --name-only HEAD; git ls-files --others --exclude-standard; } \
           | grep -v '^\.codex-final-message$' | sed '/^$/d' | sort -u || true )

# printf '%s\n', not '%s': without the trailing newline `read` drops the last
# element, which silently empties $allowed and marks every path a violation.
allowed=$(printf '%s\n' "$FILES" | tr ',' '\n' | while IFS= read -r f; do
  f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"   # trim
  [ -n "$f" ] || continue
  case "$f" in /*) printf '%s\n' "${f#"$REPO"/}" ;; ./*) printf '%s\n' "${f#./}" ;; *) printf '%s\n' "$f" ;; esac
done | sed '/^$/d' | sort -u)

if [ -n "$touched" ]; then
  violations=$(printf '%s\n' "$touched" | grep -Fxv -f <(printf '%s\n' "$allowed") || true)
else
  violations=""
fi

echo
echo "LANE REPORT"
echo "  repo:     $REPO"
echo "  worktree: $WT"
echo "  rc:       $rc"
echo "  touched:"; printf '%s\n' "$touched" | sed 's/^/    /'
if [ -n "$violations" ]; then
  echo "  SCOPE VIOLATIONS (edited but not in the spec's Files):"
  printf '%s\n' "$violations" | sed 's/^/    /'
  echo "  -> these stay in the worktree. Do not apply them."
fi
if [ -z "$touched" ]; then
  echo "  status:   empty diff — the lane produced nothing. Treat as failure."
  cleanup
  exit 1
fi
echo
echo "  Apply only the allowed paths back to the main tree with:"
echo "    scripts/codex-lane-apply.sh --worktree '$WT' --repo '$REPO' --files '$FILES'"
echo "  Discard the whole lane with:"
echo "    git -C '$REPO' worktree remove --force '$WT'"
exit "$rc"
