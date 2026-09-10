#!/usr/bin/env bash
# Apply ONLY a lane's allowed paths from its worktree back into the main tree.
#
# Additive by construction: it copies the named paths and touches nothing else.
# It never runs checkout, restore, reset, clean or stash on the main tree, so a
# co-resident lane's uncommitted work cannot be collateral damage. Anything the
# lane wrote outside its spec's Files is left behind in the worktree.
#
# usage: codex-lane-apply.sh --worktree <path> --repo <path> --files <f1,f2,...> [--dry-run] [--remove]
set -euo pipefail

WT="" REPO="" FILES="" DRY=0 RM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WT="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --files)    FILES="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --remove)   RM=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 5 ;;
  esac
done
[ -d "$WT" ]   || { echo "--worktree must exist" >&2; exit 5; }
[ -d "$REPO" ] || { echo "--repo must exist" >&2; exit 5; }
[ -n "$FILES" ] || { echo "--files is required" >&2; exit 5; }

applied=0 skipped=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in /*) rel="${f#"$REPO"/}" ;; *) rel="$f" ;; esac
  src="$WT/$rel"
  if [ ! -e "$src" ]; then
    echo "  skip (lane did not produce it): $rel"; skipped=$((skipped+1)); continue
  fi
  if [ "$DRY" = 1 ]; then
    if [ -e "$REPO/$rel" ] && cmp -s "$src" "$REPO/$rel"; then
      echo "  unchanged: $rel"
    else
      echo "  would apply: $rel"
      diff -u "$REPO/$rel" "$src" 2>/dev/null | head -40 || true
    fi
  else
    mkdir -p "$REPO/$(dirname -- "$rel")"
    cp -p "$src" "$REPO/$rel"
    echo "  applied: $rel"
  fi
  applied=$((applied+1))
done < <(printf '%s\n' "$FILES" | tr ',' '\n')   # '%s\n': without it, read drops the last path

echo
[ "$DRY" = 1 ] && echo "DRY RUN — nothing was written." || echo "applied=$applied skipped=$skipped"

if [ "$RM" = 1 ] && [ "$DRY" = 0 ]; then
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 \
    && echo "worktree removed: $WT" \
    || echo "worktree NOT removed (remove manually): $WT"
else
  echo "worktree kept: $WT"
  echo "  inspect leftovers:  git -C '$WT' status --short"
  echo "  discard when done:  git -C '$REPO' worktree remove --force '$WT'"
fi
